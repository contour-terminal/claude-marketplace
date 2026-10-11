#!/usr/bin/env python3
"""Render a local STATUS.md into a phone-friendly status page.

The status-board skill runs this after every edit of STATUS.md and republishes the result to one
private artifact URL, so the owner keeps a single link that is always current.

    python3 status_page.py [--source FILE] [--output FILE] [--title TEXT] [--standalone]
                           [--time-log FILE]
    python3 status_page.py --url
    python3 status_page.py --remember-url URL

Every working tree of a repository — the main one and each linked worktree — has a board of its
own: its own STATUS.md, its own rendered page, its own remembered URL and its own time log, so
sessions in different worktrees run the skill in parallel without writing over each other.

--source      Defaults to STATUS.md at the root of the current working tree.
--output      Defaults to <the working tree's git dir>/status-board.html: inside .git, so it can
              never be committed, and private to the working tree (.git/worktrees/<name>/ for a
              linked one). Outside a git repository it falls back to the system temp directory.
--title       Defaults to the goal in STATUS.md's "## Current plan:" heading, else its H1.
--standalone  Wraps the page in a complete HTML document, for opening from disk. Without it the
              output is the fragment the Artifact tool wraps in its own document skeleton.
--time-log    Defaults to <the working tree's git dir>/status-board.times.jsonl, which
              time_log.py appends to at every dispatch, report, completion and step.
--url         Prints the working tree's remembered page URL, or a line saying there is none yet.
--remember-url
              Remembers URL as the working tree's page, in <git dir>/status-board.url.

A progress bar is drawn for every row of every Markdown table that has an N/M column and a state
column — one headed State or Status, or one made of recognised state words. The headline sums them.
Where a table has several N/M columns, the one headed like "Tasks done" is the count.

Every render first rebuilds the "## Time spent" section of the source from the time log, in place,
and writes the source back when that changed it: the section's own lines and nothing else. A board
without the section gains it after the plan's. Its tables are never read as progress.

Needs Python 3.9+ and the `markdown` package; nothing else outside the standard library.
"""

from __future__ import annotations

import argparse
import codecs
import datetime
import hashlib
import html
import json
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

try:
    import markdown
except ImportError:  # --url and --remember-url work without it; rendering says what is missing
    markdown = None

MARKDOWN_MISSING = "status_page.py needs the markdown package: pip install markdown"

MARKDOWN_EXTENSIONS = ["tables", "sane_lists", "fenced_code"]

# The words a state cell may start with, by the class that colours it and feeds the headline. The
# cell keeps its own wording; only the leading word becomes a chip. Tried longest first, so
# "in progress" is never read as something shorter.
STATE_WORDS = {
    "done": ("landed", "merged", "done", "complete", "completed", "finished", "shipped"),
    "running": ("running", "in progress", "in review", "review", "active", "wip"),
    "blocked": ("blocked", "on hold", "stuck"),
    "queued": ("queued", "not started", "to do", "todo", "pending", "planned", "next"),
}
PHRASES = sorted(((p, cls) for cls, ps in STATE_WORDS.items() for p in ps), key=lambda x: -len(x[0]))
CHECK_MARK = "✅"

# A board with more tasks per row than this draws a continuous bar instead of numbered rungs;
# above DENSE the rungs drop their numbers, which no longer fit at phone width.
MAX_RUNGS = 20
DENSE = 12

NM = re.compile(r"^(\d+)\s*/\s*(\d+)(?![\d/])")
COUNT_HEADER = re.compile(r"(.+?)\s+(done|complete|completed|finished)$", re.I)
SEPARATOR = re.compile(r"^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)*\|?\s*$")
FENCE = re.compile(r"^\s{0,3}(```|~~~)")
LIST_ITEM = re.compile(r"^ {0,3}([-*+]|\d+[.)])\s")
LIST_ANY = re.compile(r"^([ \t]*)([-*+]|\d+[.)])\s")
HEADING = re.compile(r"^(#{1,6})\s+(.*?)\s*#*\s*$")
UPDATED = re.compile(r"^\*\*Last updated:\*\*\s*(.*?)\s*$", re.I)
STAMP = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}(?![\d:])")
# A date and time that stops at the minute, anywhere in the body.
MINUTE_ONLY = re.compile(r"\b\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(?!\d|:\d)")
# A list item that opens with a bare date, as a dated decision does, and no time after it.
DATED_ITEM = re.compile(r"^\s*([-*+]|\d+[.)])\s+[*_]{0,2}\d{4}-\d{2}-\d{2}(?!\d|[ T]\d{2}:\d{2})")
PLAN = re.compile(r"^##\s+Current plan:\s*(.+?)\s*$", re.I | re.M)
LEADS = (("Now", "now"), ("Next", "next"), ("Blocked", "blocked"))

LIGHT = {
    "bg": "#F4F6F3", "surface": "#FFFFFF", "ink": "#17201D", "muted": "#58645F",
    "rule": "#D7DDD8", "accent": "#1C5C64", "code-bg": "#E7ECE9",
    "done": "#2D7A4D", "done-bg": "#DCEFE3", "running": "#9A5B12", "running-bg": "#F6E7CF",
    "blocked": "#A63D2F", "blocked-bg": "#F7DEDA", "todo": "#6A7571", "todo-bg": "#E8ECEA",
}
DARK = {
    "bg": "#111614", "surface": "#19201D", "ink": "#E2E8E5", "muted": "#98A39E",
    "rule": "#2B3431", "accent": "#72B4BB", "code-bg": "#222A27",
    "done": "#7FC89C", "done-bg": "#1D3327", "running": "#E3AE62", "running-bg": "#3A2C17",
    "blocked": "#F0907F", "blocked-bg": "#3D1F1A", "todo": "#97A29D", "todo-bg": "#252D2A",
}


def tokens(palette: dict[str, str], indent: str) -> str:
    return "\n".join(f"{indent}--{name}: {value};" for name, value in palette.items())


# One palette per theme, emitted three times: the two dark blocks cannot drift apart because
# neither is written by hand.
THEME = f"""\
:root {{
{tokens(LIGHT, '  ')}
  --font-body: "Public Sans", system-ui, -apple-system, "Segoe UI", Roboto, sans-serif;
  --font-mono: "JetBrains Mono", ui-monospace, "Cascadia Mono", Consolas, monospace;
}}
@media (prefers-color-scheme: dark) {{
  :root:not([data-theme="light"]) {{
    color-scheme: dark;
{tokens(DARK, '    ')}
  }}
}}
:root[data-theme="dark"] {{
  color-scheme: dark;
{tokens(DARK, '  ')}
}}
"""

LAYOUT = """\
body {
  background: var(--bg);
  color: var(--ink);
  font-family: var(--font-body);
  font-size: 16px;
  line-height: 1.6;
  margin: 0;
  padding-inline: 16px;
  padding-block: 20px 48px;
}
.page { max-width: 44rem; margin-inline: auto; display: grid; gap: 28px; }

header.masthead { display: grid; gap: 14px; }
.eyebrow {
  font-size: 0.75rem; font-weight: 600; letter-spacing: 0.08em;
  text-transform: uppercase; color: var(--accent); margin: 0;
}
h1 { font-size: 1.75rem; line-height: 1.2; margin: 0; font-weight: 700; text-wrap: balance; }
.lede { margin: -4px 0 0; font-size: 1.02rem; line-height: 1.55; color: var(--muted); text-wrap: pretty; }
.headline { margin: 0; font-size: 1.1rem; font-weight: 700; font-variant-numeric: tabular-nums; text-wrap: balance; }
.updated {
  background: var(--surface); border: 1px solid var(--rule); border-radius: 8px;
  padding: 12px 14px; margin: 0; font-size: 0.95rem;
}
.updated b { display: block; font-size: 0.72rem; letter-spacing: 0.08em; text-transform: uppercase; color: var(--muted); font-weight: 600; margin-bottom: 2px; }
.missing { color: var(--blocked); font-weight: 600; }

.ladder-block { display: grid; gap: 8px; }
.ladder-caption { margin: 0; font-size: 0.9rem; color: var(--muted); font-variant-numeric: tabular-nums; }
.ladder-caption strong { color: var(--ink); }
.ladder-group { margin: 8px 0 0; font-size: 0.72rem; font-weight: 600; letter-spacing: 0.08em; text-transform: uppercase; color: var(--muted); }
ol.ladder { list-style: none; margin: 0; padding: 0; display: grid; gap: 3px; }
.lane { display: grid; gap: 4px; }
.lane-name { margin: 0; font-size: 0.85rem; font-weight: 600; display: flex; justify-content: space-between; gap: 8px; }
.lane-count { color: var(--muted); font-variant-numeric: tabular-nums; font-weight: 400; white-space: nowrap; }
.rung {
  height: 34px; border-radius: 4px; display: flex; align-items: flex-end; justify-content: center;
  padding-bottom: 3px; font-size: 0.68rem; font-weight: 600; font-variant-numeric: tabular-nums;
}
.dense .rung-n { display: none; }
.rung.done { background: var(--done); color: var(--bg); }
.rung.running { background: var(--running); color: var(--bg); }
.rung.blocked { background: var(--blocked); color: var(--bg); }
.rung.todo { background: var(--todo-bg); color: var(--todo); box-shadow: inset 0 0 0 1px var(--rule); }
.bar { height: 14px; border-radius: 4px; background: var(--todo-bg); box-shadow: inset 0 0 0 1px var(--rule); overflow: hidden; }
.bar.blocked { box-shadow: inset 0 0 0 2px var(--blocked); }
.bar-fill { display: block; height: 100%; background: var(--done); }
.ladder-legend { display: flex; flex-wrap: wrap; gap: 6px 14px; margin: 0; padding: 0; list-style: none; font-size: 0.8rem; color: var(--muted); }
.ladder-legend li { display: flex; align-items: center; gap: 6px; }
.swatch { width: 10px; height: 10px; border-radius: 2px; display: inline-block; }
.swatch.done { background: var(--done); }
.swatch.running { background: var(--running); }
.swatch.blocked { background: var(--blocked); }
.swatch.todo { background: var(--todo-bg); box-shadow: inset 0 0 0 1px var(--rule); }
.note { margin: 0; font-size: 0.9rem; color: var(--muted); }

main { display: grid; gap: 4px; min-width: 0; }
main h2 {
  font-size: 1.2rem; line-height: 1.3; margin: 28px 0 6px; font-weight: 700; text-wrap: balance;
  padding-top: 18px; border-top: 1px solid var(--rule);
}
main > h2:first-child { margin-top: 0; }
main h3 { font-size: 1rem; margin: 16px 0 4px; }
main p, main li { max-width: 65ch; }
main p { margin: 0 0 12px; }
main ul, main ol { margin: 0 0 12px; padding-left: 1.2em; display: grid; gap: 8px; }
main pre { overflow-x: auto; background: var(--code-bg); padding: 10px 12px; border-radius: 8px; }
main pre code { background: none; padding: 0; }
strong { font-weight: 700; }
a { color: var(--accent); }
code {
  font-family: var(--font-mono); font-size: 0.84em; background: var(--code-bg);
  padding: 0.1em 0.35em; border-radius: 4px; overflow-wrap: anywhere;
}
.lead {
  display: inline-block; font-size: 0.72rem; letter-spacing: 0.08em; text-transform: uppercase;
  padding: 1px 7px; border-radius: 4px; margin: 6px 6px 0 0;
}
.lead.now { background: var(--running-bg); color: var(--running); }
.lead.next { background: var(--todo-bg); color: var(--muted); }
.lead.blocked { background: var(--blocked-bg); color: var(--blocked); }

.table-wrap {
  overflow-x: auto; margin: 4px 0 16px; border: 1px solid var(--rule);
  border-radius: 8px; background: var(--surface);
}
table { border-collapse: collapse; width: 100%; font-size: 0.88rem; }
th, td { text-align: left; vertical-align: top; padding: 9px 12px; border-bottom: 1px solid var(--rule); }
tr:last-child td { border-bottom: 0; }
th { font-size: 0.72rem; letter-spacing: 0.08em; text-transform: uppercase; color: var(--muted); font-weight: 600; }
td { font-variant-numeric: tabular-nums; }
td:last-child { min-width: 12rem; }
.chip {
  display: inline-block; white-space: nowrap; font-size: 0.75rem; font-weight: 600;
  padding: 2px 8px; border-radius: 999px;
}
.chip.done { background: var(--done-bg); color: var(--done); }
.chip.running { background: var(--running-bg); color: var(--running); }
.chip.blocked { background: var(--blocked-bg); color: var(--blocked); }
.chip.queued { background: var(--todo-bg); color: var(--todo); }

footer { font-size: 0.8rem; color: var(--muted); border-top: 1px solid var(--rule); padding-top: 14px; }
"""

FONT_LINKS = """\
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;600&amp;family=Public+Sans:ital,wght@0,400;0,600;0,700;1,400&amp;display=swap">"""


@dataclass
class Row:
    name: str
    done: int
    total: int
    state: str  # done | running | blocked | queued | other
    finished_as: str  # the word a finished row used, to choose "landed" or "done" in the headline
    group: str  # the heading the row's table sits under


@dataclass
class Board:
    title: str
    headline: str
    rows: list[Row]
    page: str
    warnings: list[str] = field(default_factory=list)
    goal: str = ""  # the current plan's goal, the page's title: what the work in this tree is about
    summary: str = ""  # the paragraph under it, shown beside the title


# --- Markdown helpers ------------------------------------------------------------------------


def plain(cell: str) -> str:
    """A cell's text without emphasis, code ticks or link targets."""
    text = re.sub(r"\[([^\]]*)\]\([^)]*\)", r"\1", cell)
    text = re.sub(r"\*\*|__|[*`]|~~", "", text)
    return text.replace("\\|", "|").strip()


def inline(md: str) -> str:
    """Render one line of Markdown without the paragraph around it."""
    return re.sub(r"^<p>(.*)</p>$", r"\1", markdown.markdown(md), flags=re.S)


def split_cells(line: str) -> list[str]:
    """Split a table row on the pipes Python-Markdown would split it on."""
    text = line.strip()
    if text.startswith("|"):
        text = text[1:]
    if text.endswith("|") and not text.endswith("\\|"):
        text = text[:-1]
    cells, current, in_code, i = [], [], False, 0
    while i < len(text):
        if text.startswith("\\|", i):
            current.append("\\|")
            i += 2
            continue
        char = text[i]
        if char == "`":
            in_code = not in_code
        if char == "|" and not in_code:
            cells.append("".join(current).strip())
            current = []
        else:
            current.append(char)
        i += 1
    cells.append("".join(current).strip())
    return cells


def state_of(cell: str) -> tuple[str, str] | None:
    """(class, the phrase that decided it) for a state cell, or None for words we do not know."""
    text = plain(cell).lower()
    if not text:
        return "queued", ""
    if text.startswith(CHECK_MARK):
        return "done", CHECK_MARK
    for phrase, cls in PHRASES:
        if text.startswith(phrase) and not text[len(phrase):len(phrase) + 1].isalnum():
            return cls, phrase
    return None


def chip(cell: str, cls: str, phrase: str) -> str:
    """The state cell with its leading state word turned into a coloured chip."""
    if not phrase:
        return f'<span class="chip {cls}">queued</span>'
    # A linked state word keeps its link, with the chip as the link text: [done](#pr-12).
    m = re.match(r"\s*(\[)?(\*\*|__|\*|_|`)?(" + re.escape(phrase) + r")(?:\2)?", cell, re.I)
    if m is None:
        return f'<span class="chip {cls}">{cls}</span> {cell}'
    label = "done" if phrase == CHECK_MARK else m.group(3)
    return f'{m.group(1) or ""}<span class="chip {cls}">{html.escape(label)}</span>{cell[m.end():]}'


def plural(noun: str) -> str:
    words = noun.lower().split()
    if not words:
        return "lanes"
    last = words[-1]
    if last.endswith("s"):
        pass
    elif re.search(r"(x|ch|sh)$", last):
        last += "es"
    elif re.search(r"[^aeiou]y$", last):
        last = last[:-1] + "ies"
    else:
        last += "s"
    return " ".join(words[:-1] + [last])


# --- Reading the progress tables -------------------------------------------------------------


@dataclass
class Table:
    start: int  # line index of the header row
    header: list[str]
    rows: list[list[str]]
    group: str


def fenced(lines: list[str]) -> list[bool]:
    """For each line, whether it opens, closes or sits inside a code fence."""
    flags, fence = [], None
    for line in lines:
        m = FENCE.match(line)
        if m and fence is None:
            fence = m.group(1)
            flags.append(True)
        elif m and m.group(1) == fence:
            fence = None
            flags.append(True)
        else:
            flags.append(fence is not None)
    return flags


def separate_blocks(lines: list[str]) -> list[str]:
    """Put a blank line before a list or a table that follows a paragraph line directly.

    GitHub and most editors let either interrupt a paragraph; Python-Markdown does not. It runs
    "**Decisions:**" and the items under it into one paragraph of dashes, and a table under a
    line of text into raw pipes, with no bars drawn from it.
    """
    out: list[str] = []
    inside = fenced(lines)
    for i, line in enumerate(lines):
        prev = out[-1] if out else ""
        paragraph = (prev.strip() and "|" not in prev and not prev.startswith((" ", "\t"))
                     and not HEADING.match(prev))
        opens_list = LIST_ITEM.match(line) and not LIST_ITEM.match(prev)
        opens_table = ("|" in line and i + 1 < len(lines) and "|" in lines[i + 1]
                       and SEPARATOR.match(lines[i + 1]))
        if not inside[i] and paragraph and (opens_list or opens_table):
            out.append("")
        out.append(line)
    return out


# A line that labels what follows it rather than saying something: **Decisions:**, **Now:**.
LABEL = re.compile(r"^\*\*[^*]+:\*\*")


def plan_section(lines: list[str]) -> tuple[int | None, list[int]]:
    """The line of the Current plan heading, and the lines of the paragraph that opens its section.

    That paragraph is the plan's summary only when it is prose: a list, a table, a fence, a
    heading or a labelled line such as **Decisions:** in its place means the summary is missing.
    """
    inside = fenced(lines)
    heading = next((i for i, line in enumerate(lines) if not inside[i] and PLAN.match(line)), None)
    if heading is None:
        return None, []
    i = heading + 1
    while i < len(lines) and not lines[i].strip():
        i += 1
    summary: list[int] = []
    while (i < len(lines) and lines[i].strip() and not inside[i]
           and not (HEADING.match(lines[i]) or LIST_ITEM.match(lines[i]) or "|" in lines[i]
                    or FENCE.match(lines[i]) or lines[i].startswith((">", " ", "\t"))
                    or (not summary and LABEL.match(lines[i])))):
        summary.append(i)
        i += 1
    return heading, summary


def nested_list_warnings(lines: list[str]) -> list[str]:
    """Where a list item is indented too little to nest under the item above it.

    Python-Markdown nests at four spaces. Two, which GitHub nests, make the item a sibling of
    its parent; three under a numbered item make it literal text. Neither is visible until the
    page is read, so it is warned rather than silently flattened.
    """
    warnings: list[str] = []
    parent = None
    for n, (line, inside) in enumerate(zip(lines, fenced(lines)), 1):
        if inside:
            parent = None
            continue
        m = LIST_ANY.match(line)
        if m:
            indent = len(m.group(1).expandtabs(4))
            if parent is not None and parent < indent < parent + 4:
                warnings.append(f"line {n}: a list item indented {indent - parent} spaces under the "
                                f"one above does not nest on the page; indent it four")
            parent = indent
        elif line.strip() and not line.startswith((" ", "\t")):
            parent = None
    return warnings


def find_tables(lines: list[str]) -> list[Table]:
    """Every pipe table outside a code fence, as Python-Markdown's tables extension would see it."""
    tables: list[Table] = []
    inside = fenced(lines)
    group, i = "", 0
    while i < len(lines):
        line = lines[i]
        if inside[i]:
            i += 1
            continue
        heading = HEADING.match(line)
        if heading and len(heading.group(1)) > 1:
            group = plain(heading.group(2))
        starts_block = i == 0 or not lines[i - 1].strip() or HEADING.match(lines[i - 1])
        if (starts_block and "|" in line and i + 1 < len(lines)
                and "|" in lines[i + 1] and SEPARATOR.match(lines[i + 1])):
            header = split_cells(line)
            rows, j = [], i + 2
            while j < len(lines) and lines[j].strip() and "|" in lines[j]:
                cells = split_cells(lines[j])
                rows.append((cells + [""] * len(header))[:len(header)])
                j += 1
            tables.append(Table(i, header, rows, group))
            i = j
            continue
        i += 1
    return tables


def progress_columns(table: Table) -> tuple[int | None, int, int, bool] | None:
    """(name, count, state, guessed) when the table tracks progress, else None.

    The count column is the one whose cells are all N/M and whose header reads like "Tasks done";
    failing that, the first all-N/M column, and `guessed` says the choice was not the header's
    when there were several: a "Tests" column of 212/212 ahead of "Progress" 1/3 would otherwise
    draw a lane a third done as finished, with nothing to say so.

    The state column is the one headed State or Status, or failing that the first made only of
    recognised state words. A table of test results — "1204/1204" beside "PASS" — has an N/M
    column and a Status column, and is still not progress: its state column must hold at least
    one recognised state word.
    """
    width = len(table.header)
    columns = [[plain(row[c]) for row in table.rows] for c in range(width)]
    counts = [c for c in range(width)
              if any(columns[c]) and all(NM.match(v) for v in columns[c] if v)]
    if not counts:
        return None
    headed = [c for c in counts if COUNT_HEADER.match(plain(table.header[c]))]
    count = (headed or counts)[0]
    guessed = len(counts) > 1 and not headed
    headers = [plain(h).lower() for h in table.header]

    def recognised(c: int, headed: bool) -> bool:
        filled = [v for v in columns[c] if v]
        known = sum(1 for v in filled if state_of(v))
        if headed:
            return known > 0 or not filled
        return bool(filled) and known == len(filled)

    candidates = [c for c in range(width) if c != count]
    state = next((c for c in candidates if headers[c] in ("state", "status") and recognised(c, True)), None)
    if state is None:
        state = next((c for c in candidates if recognised(c, False)), None)
    if state is None:
        return None
    name = next((c for c in range(width) if c not in (count, state)), None)
    return name, count, state, guessed


# --- The time log ----------------------------------------------------------------------------

# One JSON object per line, appended by time_log.py at the moment of each event and never
# rewritten. Every record carries `logged`, the local time it was written; any other time in it
# (`at`, `since`, `first`, `last`) was taken from a record named when it was logged — a commit's
# author date, a message's time — never from memory.
TIME_LOG = "status-board.times.jsonl"
STAMP_FORMAT = "%Y-%m-%d %H:%M:%S"
TIME_HEADING = re.compile(r"^##\s+Time spent\s*$", re.I)
TOP_HEADING = re.compile(r"^#{1,2}\s")  # what ends a section that opens with an H2
NO_TIMES = "No timed work yet: the log starts at the first dispatch."


@dataclass
class Step:
    id: str
    title: str
    start: datetime.datetime
    done: datetime.datetime | None = None
    first_commit: datetime.datetime | None = None
    last_commit: datetime.datetime | None = None
    commits: int = 0
    note: str = ""


@dataclass
class Task:
    id: str
    title: str
    group: str  # the lane or phase it belongs to; "" for none
    start: datetime.datetime  # dispatched
    report: datetime.datetime | None = None  # its first commit or report
    done: datetime.datetime | None = None
    fix_rounds: int | None = None
    steps: dict[str, Step] = field(default_factory=dict)


@dataclass
class Stall:
    where: str  # a task's id, or a group's
    since: datetime.datetime  # the last record of activity before it
    until: datetime.datetime  # when it was found and logged
    what: str


@dataclass
class Times:
    groups: dict[str, str] = field(default_factory=dict)  # id -> name, in order of first appearance
    tasks: dict[str, Task] = field(default_factory=dict)  # in order of dispatch
    stalls: list[Stall] = field(default_factory=list)
    problems: list[str] = field(default_factory=list)  # records that matched nothing logged before them
    began: datetime.datetime | None = None  # the first record's time


def stamp(text: object) -> datetime.datetime | None:
    """A YYYY-MM-DD HH:MM:SS time, or None for anything else."""
    if not isinstance(text, str):
        return None
    try:
        return datetime.datetime.strptime(text, STAMP_FORMAT)
    except ValueError:
        return None


def time_log_path(start: Path) -> Path | None:
    """The working tree's time log: in its own git dir, beside its page and its URL."""
    own = git_dir(start)
    return own / TIME_LOG if own is not None else None


def read_time_log(path: Path | None) -> tuple[list[dict], list[str]]:
    """The log's records in the order they were written, and a line for each one it skipped."""
    if path is None or not path.is_file():
        return [], []
    records, problems = [], []
    for n, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        if not line.strip():
            continue
        try:
            record = json.loads(line)
        except ValueError:
            record = None
        if isinstance(record, dict) and stamp(record.get("logged")) is not None:
            records.append(record)
        else:
            problems.append(f"time log line {n} is not a stamped record; skipped")
    return records, problems


def fold_times(records: list[dict]) -> Times:
    """Replay the log's records, in order, into its groups, tasks, steps and stalls."""
    times = Times()
    for r in records:
        event, logged = r.get("event"), stamp(r["logged"])
        times.began = times.began or logged
        task = times.tasks.get(str(r.get("task")))
        step = task.steps.get(str(r.get("step"))) if task else None
        where = str(r.get("where"))
        if event == "group":
            times.groups[str(r.get("group", ""))] = str(r.get("name", ""))
        elif event == "start" and task is None:
            group = str(r.get("group", ""))
            times.groups.setdefault(group, "")
            times.tasks[str(r.get("task"))] = Task(str(r.get("task")), str(r.get("title", "")), group, logged)
        elif event == "report" and task is not None:
            task.report = task.report or stamp(r.get("at")) or logged  # the first one counts
        elif event == "done" and task is not None:
            task.done = logged
            if isinstance(r.get("fix_rounds"), int):
                task.fix_rounds = r["fix_rounds"]
        elif event == "step" and task is not None and step is None:
            task.steps[str(r.get("step"))] = Step(str(r.get("step")), str(r.get("title", "")), logged)
        elif event == "step-commits" and step is not None:
            step.first_commit, step.last_commit = stamp(r.get("first")), stamp(r.get("last"))
            step.commits = r.get("count") if isinstance(r.get("count"), int) else 0
        elif event == "step-done" and step is not None:
            step.done = logged
            step.note = str(r.get("note", step.note))
        elif (event == "idle" and (where in times.tasks or where in times.groups)
              and stamp(r.get("since")) is not None):
            times.stalls.append(Stall(where, stamp(r.get("since")), logged, str(r.get("what", ""))))
        else:
            times.problems.append(f"time log: a '{event}' record logged {r['logged']} matches nothing "
                                  f"logged before it; skipped")
    return times


def duration(seconds: float | None) -> str:
    """A span as the board shows it: hours and minutes from an hour up, minutes and seconds below."""
    if seconds is None:
        return "—"
    total = round(seconds)
    hours, rest = divmod(abs(total), 3600)
    minutes, secs = divmod(rest, 60)
    sign = "-" if total < 0 else ""
    return f"{sign}{hours}h {minutes:02d}m" if hours else f"{sign}{minutes}m {secs:02d}s"


def when(moment: datetime.datetime | None) -> str:
    return moment.strftime(STAMP_FORMAT) if moment else "—"


def table_cell(text: str) -> str:
    """Text for a table cell: one line, with its pipes escaped."""
    return " ".join(text.split()).replace("|", "\\|")


def task_spans(task: Task, now: datetime.datetime) -> tuple[float, float | None, float]:
    """(implement, review & fixes, total) in seconds. Running work counts to now; a task with no
    report is implementation throughout."""
    end = task.done or now
    implement = ((task.report or end) - task.start).total_seconds()
    review = (end - task.report).total_seconds() if task.report else None
    return implement, review, (end - task.start).total_seconds()


def covered(spans: list[tuple[datetime.datetime, datetime.datetime]]) -> float:
    """Seconds during which at least one of the spans was running."""
    total, reach = 0.0, None
    for begin, end in sorted(spans):
        if reach is None or begin > reach:
            total += (end - begin).total_seconds()
            reach = end
        elif end > reach:
            total += (end - reach).total_seconds()
            reach = end
    return total


def time_section(times: Times, now: datetime.datetime) -> str:
    """The board's "## Time spent" section, as Markdown, from the folded log.

    A row per lane or phase, a table of its tasks under each, a table of steps under every task
    that has them, and the idle stalls. Running work counts to now, which is stated only while
    something runs, so a finished run's section is the same at every render. None of its own
    columns is an N/M count, and render() never reads its tables as progress in any case: a log's
    ids and titles could still make one look like it.
    """
    now = now.replace(tzinfo=None)  # the log's times are local, with no offset
    out = ["## Time spent", ""]
    if not times.tasks:
        return "\n".join(out + [NO_TIMES]) + "\n"

    def label(group: str) -> str:
        name = times.groups.get(group, "")
        if not group:
            return name or "Ungrouped"
        return f"{group} · {name}" if name else group

    def idle(ids: set[str]) -> float | None:
        spans = [(s.until - s.since).total_seconds() for s in times.stalls if s.where in ids]
        return sum(spans) if spans else None

    def summary(name: str, tasks: list[Task], ids: set[str]) -> str:
        spans = [task_spans(t, now) for t in tasks]
        finished = [total for t, (_, _, total) in zip(tasks, spans) if t.done]
        reviews = [review for _, review, _ in spans if review is not None]
        wall = (max(t.done or now for t in tasks) - min(t.start for t in tasks)).total_seconds()
        running = " (running)" if len(finished) < len(tasks) else ""
        return (f"| {name}{running} | {len(finished)} | {duration(wall)} "
                f"| {duration(sum(implement for implement, _, _ in spans))} "
                f"| {duration(sum(reviews) if reviews else None)} "
                f"| {duration(sum(finished) / len(finished) if finished else None)} | {duration(idle(ids))} |")

    intro = ("From the time log, stamped as each event happened. *Implement* runs from a task's "
             "dispatch to its first commit or report, *review & fixes* from there to done, and *wall "
             "time* from the first dispatch to the last completion: less than their sum where work ran "
             "in parallel.")
    if any(t.done is None for t in times.tasks.values()):
        intro += f" Work still running counts to {when(now)}."
    out += [intro, ""]

    groups = {g: [t for t in times.tasks.values() if t.group == g] for g in times.groups}
    groups = {g: tasks for g, tasks in groups.items() if tasks}
    out += ["| Lane or phase | Finished | Wall time | Implement | Review & fixes | Mean per task | Idle |",
            "|---|---|---|---|---|---|---|"]
    for group, tasks in groups.items():
        out.append(summary(table_cell(label(group)), tasks, {group} | {t.id for t in tasks}))
    out.append(summary("**All**", list(times.tasks.values()), set(times.groups) | set(times.tasks)))

    for group, tasks in groups.items():
        out += ["", f"### {table_cell(label(group))}", "",
                "| Task | What | Started | Implement | Review & fixes | Total | Idle | Fix rounds |",
                "|---|---|---|---|---|---|---|---|"]
        for t in tasks:
            implement, review, total = task_spans(t, now)
            running = "" if t.done else " (running)"
            fix_rounds = "—" if t.fix_rounds is None else str(t.fix_rounds)
            out.append(f"| {table_cell(t.id)} | {table_cell(t.title)}{running} | {when(t.start)} "
                       f"| {duration(implement)} | {duration(review)} | {duration(total)} "
                       f"| {duration(idle({t.id}))} | {fix_rounds} |")
        for t in (t for t in tasks if t.steps):
            out += ["", f"**Task {table_cell(t.id)} by step**", "",
                    "| Step | What | Started | First commit | Last commit | Done | Took | Commits | Note |",
                    "|---|---|---|---|---|---|---|---|---|"]
            spans = []
            for s in t.steps.values():
                spans.append((s.start, s.done or now))
                running = "" if s.done else " (running)"
                out.append(f"| {table_cell(s.id)} | {table_cell(s.title)}{running} | {when(s.start)} "
                           f"| {when(s.first_commit)} | {when(s.last_commit)} | {when(s.done)} "
                           f"| {duration((spans[-1][1] - s.start).total_seconds())} | {s.commits} "
                           f"| {table_cell(s.note)} |")
            wall = (max(e for _, e in spans) - min(b for b, _ in spans)).total_seconds()
            busy = sum((e - b).total_seconds() for b, e in spans)
            union = covered(spans)
            commits = sum(s.commits for s in t.steps.values())
            parts = [f"{len(spans)} step{'s' if len(spans) != 1 else ''}, "
                     f"{commits} commit{'s' if commits != 1 else ''}",
                     f"wall time {duration(wall)}", f"step time {duration(busy)}"]
            if busy > union:
                parts.append(f"{duration(busy - union)} of it in parallel")
            if wall > union:
                parts.append(f"{duration(wall - union)} with no step running")
            out += ["", " · ".join(parts) + "."]

    if times.stalls:
        out += ["", "### Idle stalls", "", "| Where | From | To | Idle | What stalled |", "|---|---|---|---|---|"]
        for s in times.stalls:
            where = f"Task {s.where}" if s.where in times.tasks else label(s.where)
            out.append(f"| {table_cell(where)} | {when(s.since)} | {when(s.until)} "
                       f"| {duration((s.until - s.since).total_seconds())} | {table_cell(s.what)} |")
    return "\n".join(out) + "\n"


def time_section_span(lines: list[str]) -> tuple[int, int] | None:
    """The lines of the "## Time spent" section: its heading up to the next H1 or H2, or the end."""
    inside = fenced(lines)
    start = next((i for i, line in enumerate(lines) if not inside[i] and TIME_HEADING.match(line)), None)
    if start is None:
        return None
    end = next((i for i in range(start + 1, len(lines)) if not inside[i] and TOP_HEADING.match(lines[i])),
               len(lines))
    return start, end


def with_time_section(text: str, section: str) -> str:
    """The board with its "## Time spent" section replaced by section, or added after the plan's
    section when it has none, or at the end without a plan. No other line changes."""
    lines = text.split("\n")
    new = section.rstrip("\n").split("\n") + [""]
    span = time_section_span(lines)
    if span is None:
        inside = fenced(lines)
        plan = next((i for i, line in enumerate(lines) if not inside[i] and PLAN.match(line)), None)
        at = len(lines) if plan is None else next(
            (i for i in range(plan + 1, len(lines)) if not inside[i] and TOP_HEADING.match(lines[i])),
            len(lines))
        if at and lines[at - 1].strip():
            new.insert(0, "")
        span = (at, at)
    start, end = span
    return "\n".join(lines[:start] + new + lines[end:])


def refresh_time_section(source: Path, section: str) -> str:
    """Rebuild the source's time section on disk, keeping its byte-order mark and line endings,
    and return its text as the renderer reads it."""
    raw = source.read_bytes()
    bom = codecs.BOM_UTF8 if raw.startswith(codecs.BOM_UTF8) else b""
    original = raw[len(bom):].decode("utf-8")
    crlf = "\r\n" in original
    text = original.replace("\r\n", "\n")
    updated = with_time_section(text, section)
    if updated != text:
        source.write_bytes(bom + (updated.replace("\n", "\r\n") if crlf else updated).encode("utf-8"))
    return updated


# --- Rendering -------------------------------------------------------------------------------


def ladder(rows: list[Row]) -> str:
    out, group = [], None
    grouped = len({r.group for r in rows}) > 1
    for r in rows:
        if grouped and r.group != group:
            group = r.group
            out.append(f'      <p class="ladder-group">{html.escape(group or "Progress")}</p>')
        head = (f'<p class="lane-name">{html.escape(r.name)} '
                f'<span class="lane-count">{r.done}/{r.total}</span></p>')
        if r.total > MAX_RUNGS:
            pct = 0 if r.total == 0 else min(100, round(100 * r.done / r.total))
            extra = " blocked" if r.state == "blocked" else ""
            body = (f'<div class="bar{extra}"><span class="bar-fill" style="width: {pct}%;">'
                    f'</span></div>')
        else:
            rungs = []
            for i in range(r.total):
                if i < r.done:
                    cls = "done"
                elif i == r.done and r.state in ("running", "blocked"):
                    cls = r.state
                else:
                    cls = "todo"
                rungs.append(f'<li class="rung {cls}"><span class="rung-n">{i + 1}</span></li>')
            dense = " dense" if r.total > DENSE else ""
            body = (f'<ol class="ladder{dense}" style="grid-template-columns: '
                    f'repeat({max(r.total, 1)}, minmax(0, 1fr));">' + "".join(rungs) + "</ol>")
        out.append(f'      <div class="lane">{head}{body}</div>')
    return "\n".join(out)


def short(name: str) -> str:
    """"Cache: content-hash keys" -> "Cache": the caption names lanes, not their descriptions."""
    return name.split(": ")[0]


def timestamp_warnings(lines: list[str]) -> list[str]:
    """Where a date and time is written without its seconds, or a dated entry without its time.

    Every time on the board is a full YYYY-MM-DD HH:MM:SS, so two entries made in the same
    minute keep their order and a reader can match an entry to a log line or a commit. The
    stamp line has its own warning and is skipped here; so are code fences.
    """
    warnings: list[str] = []
    for n, (line, inside) in enumerate(zip(lines, fenced(lines)), 1):
        if inside or UPDATED.match(line):
            continue
        for m in MINUTE_ONLY.finditer(line):
            warnings.append(f"line {n}: '{m.group(0)}' has no seconds; write YYYY-MM-DD HH:MM:SS")
        if DATED_ITEM.match(line):
            warnings.append(f"line {n}: a dated entry without its time; write YYYY-MM-DD HH:MM:SS")
    return warnings


def render(text: str, *, title: str | None = None, source_name: str = "STATUS.md",
           now: datetime.datetime | None = None, standalone: bool = False) -> Board:
    if markdown is None:
        sys.exit(MARKDOWN_MISSING)
    # Line numbers in warnings are the file's own, so the nesting check reads it before the
    # blank lines that let a list or a table follow a paragraph line are put in.
    original = text.split("\n")
    warnings = nested_list_warnings(original) + timestamp_warnings(original)
    lines = separate_blocks(original)

    # The progress tables: collect their rows, and turn each state cell into a chip. The time
    # section's tables are generated timings, never progress, whatever a log's ids and titles say.
    rows: list[Row] = []
    count_nouns, row_nouns = set(), set()
    timings = time_section_span(lines) or (0, 0)
    for table in find_tables(lines):
        columns = None if timings[0] <= table.start < timings[1] else progress_columns(table)
        if columns is None:
            continue
        name_col, count_col, state_col, guessed = columns
        count_header = plain(table.header[count_col])
        if guessed:
            where = f"the table under '{table.group}'" if table.group else "a table"
            warnings.append(f"{where} has several N/M columns and none headed like 'Tasks done'; "
                            f"counting '{count_header}'")
        m = COUNT_HEADER.match(count_header)
        count_nouns.add(m.group(1).lower() if m else "tasks")
        row_nouns.add(plain(table.header[name_col]) if name_col is not None else "")
        for k, cells in enumerate(table.rows):
            nm = NM.match(plain(cells[count_col]))
            if nm is None:
                continue
            done, total = int(nm.group(1)), int(nm.group(2))
            name = plain(cells[name_col]) if name_col is not None else f"Row {k + 1}"
            state = state_of(cells[state_col])
            if done > total:
                warnings.append(f"{name}: {done}/{total} counts more tasks done than there are")
            if state is None:
                warnings.append(f"{name}: state '{plain(cells[state_col])}' is not one this page "
                                f"knows; it is drawn as queued")
                cls, finished_as = "other", ""
            else:
                cls, phrase = state
                finished_as = phrase if cls == "done" else ""
                cells[state_col] = chip(cells[state_col], cls, phrase)
            rows.append(Row(name, done, total, cls, finished_as, table.group))
            lines[table.start + 2 + k] = "| " + " | ".join(cells) + " |"

    # The masthead: title, the Last-updated stamp, and the headline.
    h1 = next((i for i, line in enumerate(lines) if re.match(r"#\s", line)), None)
    stamp_line = next((i for i, line in enumerate(lines) if UPDATED.match(line)), None)
    eyebrow = (plain(HEADING.match(lines[h1]).group(2)) if h1 is not None else "") or "Status"
    updated = UPDATED.match(lines[stamp_line]).group(1) if stamp_line is not None else ""
    if stamp_line is None:
        warnings.append("no **Last updated:** line; the page says so")
    elif not STAMP.match(updated):
        warnings.append(f"Last updated '{updated}' is not YYYY-MM-DD HH:MM:SS")

    # The page's title is what the work in this tree is about: the current plan's goal, with the
    # paragraph under it beside it. The H1 names the project and the tree, above both.
    plan_line, summary_lines = plan_section(lines)
    goal = PLAN.match(lines[plan_line]).group(1) if plan_line is not None else ""
    goal = goal[:1].upper() + goal[1:] if goal[:1].islower() else goal
    summary = " ".join(lines[i].strip() for i in summary_lines)
    if plan_line is None:
        warnings.append("no '## Current plan: <goal>' heading; the page has no title saying what "
                        "the work is about")
    elif not summary:
        warnings.append("no summary paragraph right under '## Current plan:'; the title stands "
                        "alone with nothing to say more about the work")

    if rows:
        done = sum(r.done for r in rows)
        total = sum(r.total for r in rows)
        finished = [r for r in rows if r.state == "done"]
        landed = finished and all(r.finished_as in ("landed", "merged") for r in finished)
        count_noun = count_nouns.pop() if len(count_nouns) == 1 else "tasks"
        row_noun = plural(row_nouns.pop()) if len(row_nouns) == 1 else "lanes"
        headline = (f"{done} of {total} {count_noun} done · {len(finished)} of {len(rows)} "
                    f"{row_noun} {'landed' if landed else 'done'}")
    else:
        headline = plain(goal) or eyebrow

    # The body: everything but the H1, the preamble under it and the stamp, which the masthead
    # carries. The preamble is dropped only when no heading sits between it and the stamp.
    drop = set()
    if h1 is not None:
        drop.add(h1)
    if stamp_line is not None:
        drop.add(stamp_line)
        if h1 is not None and h1 < stamp_line and not any(
                HEADING.match(line) for line in lines[h1 + 1:stamp_line]):
            drop.update(range(h1 + 1, stamp_line))
    if plan_line is not None:
        drop.update(summary_lines)
        rest = next((line for i, line in enumerate(lines)
                     if i > plan_line and i not in drop and line.strip()), "")
        heading = HEADING.match(rest)
        if not rest or (heading and len(heading.group(1)) <= 2):
            drop.add(plan_line)  # nothing left in the section but what the masthead now shows
        else:
            lines[plan_line] = "## Plan"
    body_md = "\n".join(line for i, line in enumerate(lines) if i not in drop)

    body = markdown.markdown(body_md, extensions=MARKDOWN_EXTENSIONS)
    body = body.replace("<table>", '<div class="table-wrap"><table>').replace("</table>", "</table></div>")
    for word, cls in LEADS:
        body = body.replace(f"<strong>{word}:</strong>", f'<br><strong class="lead {cls}">{word}</strong>')
    body = body.replace("<p><br>", "<p>")

    now = now or datetime.datetime.now().astimezone()
    offset = now.strftime("%z") or "+0000"
    generated = f"{now.strftime('%Y-%m-%d %H:%M:%S')} (UTC{offset[:3]}:{offset[3:]})"
    updated_html = (inline(updated) if updated
                    else f'<span class="missing">not stated in {html.escape(source_name)}</span>')

    # A line that wraps at the dot keeps it at the end of the first line, not the start of the next.
    headline_html = html.escape(headline).replace(" · ", "&nbsp;· ")

    if rows:
        running = [short(r.name) for r in rows if r.state == "running"]
        blocked = [short(r.name) for r in rows if r.state == "blocked"]
        caption = f'In progress: <strong>{html.escape(", ".join(running) or "none")}</strong>'
        if blocked:
            caption += f' · Blocked: <strong>{html.escape(", ".join(blocked))}</strong>'
        legend = ['<li><span class="swatch done"></span>done</li>',
                  '<li><span class="swatch running"></span>current task</li>']
        if blocked:
            legend.append('<li><span class="swatch blocked"></span>blocked</li>')
        legend.append('<li><span class="swatch todo"></span>to do</li>')
        legend_html = "".join(legend)
        # The progress headline sits with the bars it sums, unless no goal took the title from it.
        headline_p = f'      <p class="headline">{headline_html}</p>\n' if goal else ""
        progress = f"""    <section class="ladder-block" aria-label="Progress">
{headline_p}      <p class="ladder-caption">{caption}</p>
{ladder(rows)}
      <ul class="ladder-legend">
        {legend_html}
      </ul>
    </section>"""
    else:
        progress = ('    <p class="note">No progress table: bars are drawn from a table with an '
                    'N/M column and a State column.</p>')

    if goal:
        title_html = f"    <h1>{inline(goal)}</h1>"
        if summary:
            title_html += f'\n    <p class="lede">{inline(summary)}</p>'
    else:
        title_html = f"    <h1>{headline_html}</h1>"
    page_title = title or plain(goal) or eyebrow
    description = (plain(summary) if summary
                   else f"{page_title}: progress, what is running now, and what is next.")
    head = f"""<title>{html.escape(page_title)}</title>
<meta name="description" content="{html.escape(description)}">
{FONT_LINKS}
<style>
{THEME}
{LAYOUT}</style>"""

    content = f"""<div class="page">
  <header class="masthead">
    <p class="eyebrow">{html.escape(eyebrow)}</p>
{title_html}
    <p class="updated"><b>Last updated</b>{updated_html}<br><small>Page generated {generated}</small></p>
{progress}
  </header>

  <main>
{body}
  </main>

  <footer>Generated from the local <code>{html.escape(source_name)}</code>, which is never committed; republished after every change.</footer>
</div>
"""

    if standalone:
        page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
{head}
</head>
<body>
{content}</body>
</html>
"""
    else:
        page = f"{head}\n\n{content}"
    return Board(page_title, headline, rows, page, warnings, goal=goal, summary=summary)


# --- Where things live -----------------------------------------------------------------------


def git(*args: str, cwd: Path) -> str | None:
    """Stdout of a git command, or None when it fails or git is missing."""
    try:
        result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        return None
    return result.stdout.strip()


def git_dir(start: Path, which: str = "--absolute-git-dir") -> Path | None:
    """The working tree's own git dir, or with "--git-common-dir" the one its worktrees share."""
    out = git("rev-parse", which, cwd=start)
    if not out:
        return None
    path = Path(out)
    return (path if path.is_absolute() else start / path).resolve()


def default_source(start: Path) -> Path | None:
    """STATUS.md at the root of the working tree that start is in: each worktree has its own."""
    top = git("rev-parse", "--show-toplevel", cwd=start)
    return Path(top) / "STATUS.md" if top else None


def default_output(source: Path) -> Path:
    own = git_dir(source.resolve().parent)
    if own is not None:
        return own / "status-board.html"
    digest = hashlib.sha1(str(source.resolve()).encode("utf-8")).hexdigest()[:8]
    return Path(tempfile.gettempdir()) / f"status-board-{digest}.html"


# The URL lives in the working tree's own git dir, beside its page: `git config --local` is shared
# by every worktree, so a URL kept there sends every worktree's board to one page. Before boards
# were per worktree the URL was `git config --local status-board.url`; that one belonged to the
# board at the main working tree's root, so the main tree still reads it until it remembers a URL.
LEGACY_URL_KEY = "status-board.url"


def is_main_worktree(start: Path) -> bool:
    return git_dir(start) == git_dir(start, "--git-common-dir")


def remembered_url(start: Path) -> str | None:
    own = git_dir(start)
    if own is None:
        return None
    path = own / "status-board.url"
    if path.is_file():
        return path.read_text(encoding="utf-8").strip() or None
    if is_main_worktree(start):
        return git("config", "--local", "--get", LEGACY_URL_KEY, cwd=start) or None
    return None


def remember_url(start: Path, url: str) -> Path | None:
    own = git_dir(start)
    if own is None:
        return None
    path = own / "status-board.url"
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        f.write(url + "\n")
    if is_main_worktree(start):
        git("config", "--local", "--unset", LEGACY_URL_KEY, cwd=start)  # one place for the URL
    return path


def committable(path: Path) -> bool:
    """True when the path sits in a working tree and nothing ignores it."""
    parent = path.parent
    if not parent.is_dir() or git("rev-parse", "--show-toplevel", cwd=parent) is None:
        return False
    return git("check-ignore", "-q", str(path), cwd=parent) is None


def main(argv: list[str] | None = None) -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="replace")

    parser = argparse.ArgumentParser(description="Render STATUS.md into a phone-friendly status page.")
    parser.add_argument("--source", help="the status file (default: STATUS.md at the working tree's root)")
    parser.add_argument("--output", help="where to write the page (default: <git dir>/status-board.html)")
    parser.add_argument("--title", help="the page title (default: the current plan's goal, else the H1)")
    parser.add_argument("--standalone", action="store_true",
                        help="write a complete HTML document for opening from disk")
    parser.add_argument("--time-log", help=f"the time log (default: <git dir>/{TIME_LOG})")
    parser.add_argument("--url", action="store_true", help="print the working tree's remembered page URL")
    parser.add_argument("--remember-url", metavar="URL", help="remember URL as the working tree's page")
    args = parser.parse_args(argv)

    if args.url or args.remember_url is not None:
        if git("rev-parse", "--show-toplevel", cwd=Path.cwd()) is None:
            print("error: not inside a git working tree", file=sys.stderr)
            return 1
        if args.url:
            print(remembered_url(Path.cwd()) or "(none yet; the first publish creates it)")
            return 0
        url = args.remember_url.strip()
        if not url or any(c.isspace() for c in url):
            print(f"error: {args.remember_url!r} is not a URL", file=sys.stderr)
            return 1
        print(f"remembered {url} in {remember_url(Path.cwd(), url)}")
        return 0

    if markdown is None:
        print(MARKDOWN_MISSING, file=sys.stderr)
        return 1

    source = Path(args.source) if args.source else default_source(Path.cwd())
    if source is None:
        print("error: not inside a git repository; pass --source", file=sys.stderr)
        return 1
    if not source.is_file():
        print(f"error: {source}: no such file", file=sys.stderr)
        return 1

    # The time section is rebuilt from the log at every render, so the board's timings are never
    # older than the page; running work counts to the same second as "Page generated".
    now = datetime.datetime.now().astimezone()
    log = Path(args.time_log) if args.time_log else time_log_path(source.resolve().parent)
    records, problems = read_time_log(log)
    times = fold_times(records)
    text = refresh_time_section(source, time_section(times, now))
    board = render(text, title=args.title, source_name=source.name, now=now, standalone=args.standalone)
    board.warnings += problems + times.problems

    output = Path(args.output) if args.output else default_output(source)
    output.parent.mkdir(parents=True, exist_ok=True)
    with open(output, "w", encoding="utf-8", newline="\n") as f:
        f.write(board.page)

    if committable(output):
        board.warnings.append(f"{output} is inside a working tree and not ignored; it could be committed")
    for warning in board.warnings:
        print(f"warning: {warning}", file=sys.stderr)
    # ASCII separators: this line is read through whatever code page the calling shell pipes in.
    progress = f"{len(board.rows)} progress rows" if board.rows else "no progress table"
    timed = (f"{len(times.tasks)} timed task{'s' if len(times.tasks) != 1 else ''}" if times.tasks
             else "no timed work")
    headline = board.headline.replace(" · ", ", ")
    print(f"wrote {output} ({len(board.page.encode('utf-8'))} bytes; {progress}; {timed}; {headline})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
