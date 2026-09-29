#!/usr/bin/env python3
"""Render a local STATUS.md into a phone-friendly status page.

The status-board skill runs this after every edit of STATUS.md and republishes the result to one
private artifact URL, so the owner keeps a single link that is always current.

    python3 status_page.py [--source FILE] [--output FILE] [--title TEXT] [--standalone]

--source      Defaults to STATUS.md at the root of the repository's main working tree, so a session
              in a linked worktree renders the same board as one at the root.
--output      Defaults to <git common dir>/info/status-board.html: inside .git, so it can never be
              committed, and shared by every worktree like the board itself. Outside a git
              repository it falls back to the system temp directory.
--title       Defaults to the text of STATUS.md's H1.
--standalone  Wraps the page in a complete HTML document, for opening from disk. Without it the
              output is the fragment the Artifact tool wraps in its own document skeleton.

A progress bar is drawn for every row of every Markdown table that has an N/M column and a state
column — one headed State or Status, or one made of recognised state words. The headline sums them.
Where a table has several N/M columns, the one headed like "Tasks done" is the count.

Needs Python 3.9+ and the `markdown` package; nothing else outside the standard library.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import html
import re
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

try:
    import markdown
except ImportError:
    sys.exit("status_page.py needs the markdown package: pip install markdown")

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
STAMP = re.compile(r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}(?!\d)")
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


def render(text: str, *, title: str | None = None, source_name: str = "STATUS.md",
           now: datetime.datetime | None = None, standalone: bool = False) -> Board:
    # Line numbers in warnings are the file's own, so the nesting check reads it before the
    # blank lines that let a list or a table follow a paragraph line are put in.
    original = text.split("\n")
    warnings = nested_list_warnings(original)
    lines = separate_blocks(original)

    # The progress tables: collect their rows, and turn each state cell into a chip.
    rows: list[Row] = []
    count_nouns, row_nouns = set(), set()
    for table in find_tables(lines):
        columns = progress_columns(table)
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
    if title is None:
        title = (plain(HEADING.match(lines[h1]).group(2)) if h1 is not None else "") or "Status"
    updated = UPDATED.match(lines[stamp_line]).group(1) if stamp_line is not None else ""
    if stamp_line is None:
        warnings.append("no **Last updated:** line; the page says so")
    elif not STAMP.match(updated):
        warnings.append(f"Last updated '{updated}' is not YYYY-MM-DD HH:MM")

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
        plan = PLAN.search(text)
        headline = plain(plan.group(1)) if plan else title

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
    body_md = "\n".join(line for i, line in enumerate(lines) if i not in drop)

    body = markdown.markdown(body_md, extensions=MARKDOWN_EXTENSIONS)
    body = body.replace("<table>", '<div class="table-wrap"><table>').replace("</table>", "</table></div>")
    for word, cls in LEADS:
        body = body.replace(f"<strong>{word}:</strong>", f'<br><strong class="lead {cls}">{word}</strong>')
    body = body.replace("<p><br>", "<p>")

    now = now or datetime.datetime.now().astimezone()
    offset = now.strftime("%z") or "+0000"
    generated = f"{now.strftime('%Y-%m-%d %H:%M')} (UTC{offset[:3]}:{offset[3:]})"
    updated_html = (inline(updated) if updated
                    else f'<span class="missing">not stated in {html.escape(source_name)}</span>')

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
        progress = f"""    <section class="ladder-block" aria-label="Progress">
      <p class="ladder-caption">{caption}</p>
{ladder(rows)}
      <ul class="ladder-legend">
        {legend_html}
      </ul>
    </section>"""
    else:
        progress = ('    <p class="note">No progress table: bars are drawn from a table with an '
                    'N/M column and a State column.</p>')

    # A line that wraps at the dot keeps it at the end of the first line, not the start of the next.
    headline_html = html.escape(headline).replace(" · ", "&nbsp;· ")
    head = f"""<title>{html.escape(title)}</title>
<meta name="description" content="{html.escape(title)}: progress, what is running now, and what is next.">
{FONT_LINKS}
<style>
{THEME}
{LAYOUT}</style>"""

    content = f"""<div class="page">
  <header class="masthead">
    <p class="eyebrow">{html.escape(title)}</p>
    <h1>{headline_html}</h1>
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
    return Board(title, headline, rows, page, warnings)


# --- Where things live -----------------------------------------------------------------------


def git(*args: str, cwd: Path) -> str | None:
    """Stdout of a git command, or None when it fails or git is missing."""
    try:
        result = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, check=True)
    except (OSError, subprocess.CalledProcessError):
        return None
    return result.stdout.strip()


def common_git_dir(start: Path) -> Path | None:
    out = git("rev-parse", "--git-common-dir", cwd=start)
    if not out:
        return None
    path = Path(out)
    return (path if path.is_absolute() else start / path).resolve()


def default_source(start: Path) -> Path | None:
    """STATUS.md at the root of the main working tree, from anywhere in the repository."""
    common = common_git_dir(start)
    if common is None:
        return None
    if common.name == ".git":
        return common.parent / "STATUS.md"
    top = git("rev-parse", "--show-toplevel", cwd=start)
    return Path(top) / "STATUS.md" if top else None


def default_output(source: Path) -> Path:
    common = common_git_dir(source.resolve().parent)
    if common is not None:
        return common / "info" / "status-board.html"
    digest = hashlib.sha1(str(source.resolve()).encode("utf-8")).hexdigest()[:8]
    return Path(tempfile.gettempdir()) / f"status-board-{digest}.html"


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
    parser.add_argument("--source", help="the status file (default: STATUS.md at the repository root)")
    parser.add_argument("--output", help="where to write the page (default: <git dir>/info/status-board.html)")
    parser.add_argument("--title", help="the page title (default: the text of the file's H1)")
    parser.add_argument("--standalone", action="store_true",
                        help="write a complete HTML document for opening from disk")
    args = parser.parse_args(argv)

    source = Path(args.source) if args.source else default_source(Path.cwd())
    if source is None:
        print("error: not inside a git repository; pass --source", file=sys.stderr)
        return 1
    if not source.is_file():
        print(f"error: {source}: no such file", file=sys.stderr)
        return 1

    board = render(source.read_text(encoding="utf-8-sig"), title=args.title,
                   source_name=source.name, standalone=args.standalone)

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
    headline = board.headline.replace(" · ", ", ")
    print(f"wrote {output} ({len(board.page.encode('utf-8'))} bytes; {progress}; {headline})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
