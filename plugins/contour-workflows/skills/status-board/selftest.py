#!/usr/bin/env python3
"""status_page.py self-test: render the fixtures and assert what SKILL.md depends on.

    python3 selftest.py

Every expected value below was worked out by hand from fixtures/*.md, not captured from a run.
A golden file captured from the code under test asserts only that it still does what it did.

The git cases build throwaway repositories in a temp directory under a config of their own, so
nothing in the user's git configuration (hooks, signing, templates) reaches them. They are
skipped, and say so, when git is not on PATH.
"""

from __future__ import annotations

import ast
import codecs
import contextlib
import datetime
import html
import io
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from html.parser import HTMLParser
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURES = HERE / "fixtures"
SCRIPT = HERE / "status_page.py"
TIME_SCRIPT = HERE / "time_log.py"
sys.dont_write_bytecode = True  # importing the renderer must not leave a __pycache__ in the plugin
sys.path.insert(0, str(HERE))
import status_page as sp  # noqa: E402  (rendering exits with the pip hint when markdown is missing)
import time_log as tl  # noqa: E402

NOW = datetime.datetime(2026, 3, 21, 18, 0, tzinfo=datetime.timezone(datetime.timedelta(hours=1)))
FONT_HOSTS = ("https://fonts.googleapis.com", "https://fonts.gstatic.com")
VOID = {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source",
        "track", "wbr"}

passed = failed = 0
skipped: list[str] = []


def ok(what: str, expected, actual) -> None:
    global passed, failed
    if expected == actual:
        passed += 1
    else:
        failed += 1
        print(f"FAIL  {what}\n        expected: {expected!r}\n        actual:   {actual!r}",
              file=sys.stderr)


def has(what: str, needle: str, haystack: str, present: bool = True) -> None:
    global passed, failed
    if (needle in haystack) == present:
        passed += 1
    else:
        failed += 1
        print(f"FAIL  {what}\n        {'missing' if present else 'unexpected'}: {needle!r}",
              file=sys.stderr)


class Page(HTMLParser):
    """Parses a rendered page strictly: every element closed, in order."""

    def __init__(self, text: str) -> None:
        super().__init__(convert_charrefs=True)
        self.stack: list[str] = []
        self.errors: list[str] = []
        self.classes: list[str] = []
        self.urls: list[str] = []
        self.feed(text)
        self.close()
        self.errors += [f"<{tag}> never closed" for tag in self.stack]

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if attrs.get("class"):
            self.classes.append(attrs["class"])
        self.urls += [attrs[a] for a in ("href", "src") if attrs.get(a)]
        if tag not in VOID:
            self.stack.append(tag)

    def handle_endtag(self, tag):
        if tag in VOID:
            return
        if self.stack and self.stack[-1] == tag:
            self.stack.pop()
            return
        self.errors.append(f"</{tag}> closes <{self.stack[-1] if self.stack else 'nothing'}>")
        if tag in self.stack:
            while self.stack.pop() != tag:
                pass

    def count(self, cls: str) -> int:
        return self.classes.count(cls)


def text_of(tag: str, page: str) -> str:
    m = re.search(rf"<{tag}>(.*?)</{tag}>", page, re.S)
    return html.unescape(re.sub(r"<[^>]+>", "", m.group(1))) if m else ""


def render(name: str, **kwargs) -> sp.Board:
    text = (FIXTURES / name).read_text(encoding="utf-8")
    return sp.render(text, now=NOW, source_name="STATUS.md", **kwargs)


def check_page(name: str, board: sp.Board) -> Page:
    page = Page(board.page)
    ok(f"{name}: the page parses with every element closed in order", [], page.errors)
    ok(f"{name}: nothing is fetched but the fonts",
       [], [u for u in page.urls if not u.startswith(FONT_HOSTS)])
    ok(f"{name}: no warnings", [], board.warnings)
    return page


# ============================================================================================
# The fixtures
# ============================================================================================

# example.md: 5/5 landed, 3/6 running, 2/4 running, 0/4 queued.
b = render("example.md")
p = check_page("example", b)
ok("example: headline", "10 of 19 tasks done · 1 of 4 lanes landed", b.headline)
ok("example: the h1 is the plan's goal, capitalised",
   "Streaming input for the parser, with the cache and CLI to match", text_of("h1", b.page))
has("example: the summary paragraph sits beside it",
    '<p class="lede">Done means one pull request to <code>main</code> with all four lanes landed on '
    'the integration branch <code>streaming</code>, CI green, and the migration guide written. '
    'No release in this plan.</p>', b.page)
ok("example: the summary leaves the body for the masthead", 1,
   b.page.count("<code>main</code> with all four lanes"))
has("example: the H1 is the eyebrow", '<p class="eyebrow">acme — status</p>', b.page)
has("example: the headline sits with the bars, its dot on the first line of a wrap",
    '<p class="headline">10 of 19 tasks done&nbsp;· 1 of 4 lanes landed</p>', b.page)
has("example: the plan's section keeps a heading for what is left of it", "<h2>Plan</h2>", b.page)
has("example: the summary is the page's description",
    '<meta name="description" content="Done means one pull request to main with', b.page)
has("example: a list right under a paragraph line is still a list",
    "<li>2026-03-10 11:42:07: the buffered reader", b.page)
ok("example: the page's title is the goal",
   "Streaming input for the parser, with the cache and CLI to match", text_of("title", b.page))
ok("example: rungs done", 10, p.count("rung done"))
ok("example: one current rung per running lane", 2, p.count("rung running"))
ok("example: rungs to do", 7, p.count("rung todo"))
ok("example: no blocked rung", 0, p.count("rung blocked"))
ok("example: chips", (1, 2, 1), (p.count("chip done"), p.count("chip running"), p.count("chip queued")))
has("example: the caption names running lanes by their short name",
    "In progress: <strong>Cache, CLI</strong>", b.page)
has("example: no Blocked caption without a blocked lane", "Blocked:", b.page, present=False)
has("example: the stamp is in the masthead", "<b>Last updated</b>2026-03-14 16:05:41", b.page)
has("example: generation time carries its offset", "Page generated 2026-03-21 18:00:00 (UTC+01:00)", b.page)
has("example: the preamble is dropped", "Local-only tracker", b.page, present=False)
has("example: the stamp line is not repeated in the body", "Last updated:", b.page, present=False)
has("example: Now lead-in", '<strong class="lead now">Now</strong>', b.page)
has("example: Next lead-in", '<strong class="lead next">Next</strong>', b.page)
ok("example: every table scrolls in its own box", 1, p.count("table-wrap"))
ok("example: one table, so no group labels", 0, p.count("ladder-group"))
has("example: the fragment is not a whole document", "<!doctype", b.page, present=False)

# no-progress-table.md: an N/M column beside PASS/FAIL is test results, not progress.
b = render("no-progress-table.md")
p = check_page("no-progress-table", b)
ok("no-progress-table: no rows", 0, len(b.rows))
ok("no-progress-table: headline falls back to the plan",
   "Triage the crash reports from the 2.3 release", b.headline)
ok("no-progress-table: no progress headline under the title", 0, p.count("headline"))
ok("no-progress-table: the absence is said", 1, p.count("note"))
ok("no-progress-table: no ladder", 0, p.count("ladder-block"))
ok("no-progress-table: no chips", 0, sum(c.startswith("chip") for c in p.classes))
has("no-progress-table: the table is still rendered", "<td>1204/1204</td>", b.page)

# several-tables.md: two progress tables of Workstream / Steps done / Status, one code fence.
b = render("several-tables.md")
p = check_page("several-tables", b)
ok("several-tables: rows from both tables, none from the fence", 5, len(b.rows))
ok("several-tables: headline takes both nouns from the headers",
   "7 of 15 steps done · 2 of 5 workstreams done", b.headline)
ok("several-tables: rungs", (7, 1, 7), (p.count("rung done"), p.count("rung running"), p.count("rung todo")))
ok("several-tables: chips (bold done, check mark, in progress, empty, not started)",
   (2, 1, 2), (p.count("chip done"), p.count("chip running"), p.count("chip queued")))
ok("several-tables: a group label per table",
   ["Phase 1: configure", "Phase 2: test and package"],
   re.findall(r'<p class="ladder-group">(.*?)</p>', b.page))
has("several-tables: the fenced table stays code", "| 9/9 | done | inside a code fence |", b.page)
has("several-tables: without a preamble the plan's section survives", "<h2>Plan</h2>", b.page)
ok("several-tables: the goal is the title", "Move the build to presets", text_of("h1", b.page))

# blocked.md: 4/4 merged, 2/5 blocked, 1/3 running, 0/1 on hold.
b = render("blocked.md")
p = check_page("blocked", b)
ok("blocked: headline (merged counts as landed)", "7 of 13 tasks done · 1 of 4 lanes landed", b.headline)
ok("blocked: rungs", (7, 1, 2, 3),
   (p.count("rung done"), p.count("rung running"), p.count("rung blocked"), p.count("rung todo")))
has("blocked: the caption names the blocked lanes",
    "Blocked: <strong>Converter, Release notes</strong>", b.page)
has("blocked: the legend gains a blocked swatch", '<span class="swatch blocked"></span>', b.page)
has("blocked: the chip keeps the rest of the cell",
    '<span class="chip blocked">blocked</span> — waiting on the schema decision', b.page)
has("blocked: on hold is blocked", '<span class="chip blocked">on hold</span>', b.page)
has("blocked: Blocked lead-in", '<strong class="lead blocked">Blocked</strong>', b.page)

# ============================================================================================
# Edges, inline
# ============================================================================================

TABLE = "| Lane | Tasks done | State |\n|---|---|---|\n"
# Appended to a board that tests something else, so a missing plan does not warn; at the end, so
# the line numbers in the warnings it does test stay those of the text above it.
PLANNED = "\n## Current plan: x\n\nWhat x is.\n"
STAMPED = "# x\n\n**Last updated:** 2026-03-21 17:00:42\n\n"

b = sp.render("# x\n\n" + TABLE + "| A | 1/2 | running |\n" + PLANNED, now=NOW)
ok("no stamp: warned", ["no **Last updated:** line; the page says so"], b.warnings)
has("no stamp: the page says so", '<span class="missing">not stated in STATUS.md</span>', b.page)

b = sp.render("# x\n\n**Last updated:** yesterday afternoon\n" + PLANNED, now=NOW)
ok("a guessed stamp is warned", ["Last updated 'yesterday afternoon' is not YYYY-MM-DD HH:MM:SS"],
   b.warnings)

b = sp.render("# x\n\n**Last updated:** 2026-03-21 17:00\n" + PLANNED, now=NOW)
ok("a stamp without seconds is warned", ["Last updated '2026-03-21 17:00' is not YYYY-MM-DD HH:MM:SS"],
   b.warnings)

b = sp.render("# x\n\n" + TABLE + "| A | 5/4 | running |\n" + PLANNED, now=NOW)
has("more done than total is warned", "A: 5/4 counts more tasks done than there are", " ".join(b.warnings))
ok("... and reported as written, not corrected", "5 of 4 tasks done · 0 of 1 lanes done", b.headline)

b = sp.render("# x\n\n" + TABLE + "| A | 1/2 | running |\n| B | 0/2 | in flight |\n" + PLANNED,
              now=NOW)
has("an unknown state is warned", "B: state 'in flight' is not one this page knows",
    " ".join(b.warnings))
ok("... and the row still counts", "1 of 4 tasks done · 0 of 2 lanes done", b.headline)

b = sp.render("# x\n\n" + TABLE + "| Soak tests | 30/50 | running |\n" + PLANNED, now=NOW)
has("a long row is a bar, not fifty rungs", '<span class="bar-fill" style="width: 60%;">', b.page)
ok("... with no rungs", 0, Page(b.page).count("rung todo"))

b = sp.render("# x\n\n" + TABLE + "| Build & test | 0/13 | queued |\n" + PLANNED, now=NOW)
has("lane names are escaped in the ladder", "Build &amp; test <span", b.page)
has("more than twelve rungs drop their numbers", 'class="ladder dense"', b.page)

b = sp.render("# x\n\n" + TABLE + "| A | 1/1 | done |\n" + PLANNED, title="Custom board", now=NOW)
ok("--title overrides the goal", "Custom board", text_of("title", b.page))
ok("... but not the h1", "X", text_of("h1", b.page))

# The title says what the work is about. Without a plan the page falls back to the progress
# headline, and says so; a plan with a list or a labelled line where its summary belongs has none.
b = sp.render(STAMPED + TABLE + "| A | 1/2 | running |\n",
              now=NOW)
ok("no plan: warned",
   ["no '## Current plan: <goal>' heading; the page has no title saying what the work is about"],
   b.warnings)
ok("... the h1 is the progress headline", "1 of 2 tasks done · 0 of 1 lanes done",
   text_of("h1", b.page).replace("\u00a0", " "))
ok("... shown once", 0, Page(b.page).count("headline"))
ok("... and the page's title is the H1", "x", text_of("title", b.page))
NO_SUMMARY = ["no summary paragraph right under '## Current plan:'; the title stands alone with "
              "nothing to say more about the work"]
for after in ("**Decisions:**\n- 2026-03-20 10:00:00: one", "- a list", TABLE + "| A | 1/2 | running |",
              "### Phase 1"):
    b = sp.render(STAMPED + "## Current plan: y\n\n" + after + "\n", now=NOW)
    ok(f"a plan opening with {after.splitlines()[0]!r} has no summary", NO_SUMMARY, b.warnings)
    has("... and no lede", 'class="lede"', b.page, present=False)
b = sp.render(STAMPED + "## Current plan: y\n\nWhat y is,\nover two lines.\n\n## Key rulings\n\n- one\n",
              now=NOW)
has("a summary over several lines is one lede", '<p class="lede">What y is, over two lines.</p>', b.page)
has("a plan section with nothing but its summary leaves no empty heading", "<h2>Plan</h2>", b.page,
    present=False)
has("... and the next section stays", "<h2>Key rulings</h2>", b.page)
b = sp.render(STAMPED + "## Current plan: `watch` mode\n\nWhat it is.\n", now=NOW)
has("a goal keeps its inline code", "<h1><code>watch</code> mode</h1>", b.page)
ok("... which the page's title drops", "watch mode", text_of("title", b.page))
b = sp.render(STAMPED + "```\n## Current plan: fenced\n```\n" + PLANNED, now=NOW)
ok("a plan heading in a code fence is not the plan", "X", text_of("h1", b.page))

# Every time on the board carries its seconds. A time that stops at the minute is warned wherever
# it is written, and so is a dated entry with no time. A full time, a date inside a sentence and a
# code fence are not.
b = sp.render(STAMPED + "- 2026-03-20: a decision\n- **2026-03-20** *(mine)*: another\n"
              "- 2026-03-20 14:05: a third\n- 2026-03-20 14:05:09: a fourth\n"
              "Landed on 2026-03-19, as planned.\n```\n2026-03-18 10:00\n```\n" + PLANNED, now=NOW)
ok("a time without seconds, or a dated entry without a time, is warned",
   ["line 5: a dated entry without its time; write YYYY-MM-DD HH:MM:SS",
    "line 6: a dated entry without its time; write YYYY-MM-DD HH:MM:SS",
    "line 7: '2026-03-20 14:05' has no seconds; write YYYY-MM-DD HH:MM:SS"], b.warnings)

# Two N/M columns. The header decides which one counts, not the position: a Tests column ahead
# of the task count would otherwise draw a lane a third done as finished.
TWO = "| Lane | Tests | {} | State |\n|---|---|---|---|\n| A | 212/212 | 1/3 | running |\n"
b = sp.render(STAMPED + TWO.format("Tasks done") + PLANNED, now=NOW)
ok("two N/M columns: the one headed 'Tasks done' is counted", "1 of 3 tasks done · 0 of 1 lanes done",
   b.headline)
ok("... with no warning", [], b.warnings)
b = sp.render(STAMPED + TWO.format("Progress") + PLANNED, now=NOW)
ok("two N/M columns, neither headed like it: the first is counted",
   "212 of 212 tasks done · 0 of 1 lanes done", b.headline)
ok("... and the guess is warned",
   ["a table has several N/M columns and none headed like 'Tasks done'; counting 'Tests'"], b.warnings)

# Lines 6 and 8 nest at two and three spaces; line 10 nests at four.
b = sp.render(STAMPED + "- parent\n  - child\n1. step\n   - detail\n- next\n    - nested right\n"
              + PLANNED, now=NOW)
ok("nesting at two or three spaces is warned, at four it is not",
   ["line 6: a list item indented 2 spaces under the one above does not nest on the page; indent it four",
    "line 8: a list item indented 3 spaces under the one above does not nest on the page; indent it four"],
   b.warnings)

b = sp.render(STAMPED + "Progress:\n" + TABLE + "| A | 1/2 | running |\n" + PLANNED, now=NOW)
ok("a table right under a paragraph line is still a table", 1, len(b.rows))
has("... and is rendered as one", "<td>1/2</td>", b.page)

b = sp.render(STAMPED + "| Lane | Due | State |\n|---|---|---|\n| A | 2026/10/01 | running |\n"
              + PLANNED, now=NOW)
ok("a slash date is not a count", (0, []), (len(b.rows), b.warnings))

b = sp.render(STAMPED + TABLE + "| A | 1/1 | [done](#pr-12) |\n" + PLANNED, now=NOW)
has("a linked state word keeps its link, and appears once",
    '<td><a href="#pr-12"><span class="chip done">done</span></a></td>', b.page)

b = render("example.md", standalone=True)
p = check_page("standalone", b)
ok("standalone: a whole document", True, b.page.startswith("<!doctype html>"))
has("standalone: charset", '<meta charset="utf-8">', b.page)
has("standalone: viewport", '<meta name="viewport" content="width=device-width, initial-scale=1">', b.page)

# ============================================================================================
# The theme contract
# ============================================================================================

css = render("example.md").page


def block(pattern: str) -> str:
    m = re.search(pattern + r"\s*\{(.*?)\}", css, re.S)
    return m.group(1) if m else ""


light = set(re.findall(r"--([\w-]+):", block(r"(?m)^:root")))
media = set(re.findall(r"--([\w-]+):", block(
    r'@media \(prefers-color-scheme: dark\) \{\s*:root:not\(\[data-theme="light"\]\)')))
forced = set(re.findall(r"--([\w-]+):", block(r':root\[data-theme="dark"\]')))
colours = light - {"font-body", "font-mono"}
ok("dark tokens under the media query, guarded by :not([data-theme=light])", colours, media)
ok("dark tokens again under [data-theme=dark]", colours, forced)
has("body has an explicit background", "background: var(--bg);", block(r"(?m)^body"))
has("a 16px side gutter", "padding-inline: 16px;", block(r"(?m)^body"))
has("tables scroll in their own box", "overflow-x: auto;", block(r"\.table-wrap"))
has("font stacks fall back to system fonts", "system-ui", block(r"(?m)^:root"))

# ============================================================================================
# The time log and the Time spent section
# ============================================================================================

# Durations: minutes and seconds below an hour, hours and minutes from an hour up.
ok("durations at the minute and hour boundaries",
   ["0m 00s", "0m 59s", "1m 00s", "59m 59s", "1h 00m", "1h 00m", "1h 01m", "25h 00m", "-1m 30s", "—"],
   [sp.duration(s) for s in (0, 59, 60, 3599, 3600, 3659, 3660, 90000, -90, None)])

EMPTY = "## Time spent\n\n" + sp.NO_TIMES + "\n"
ok("an empty log is a short line, not nothing", EMPTY, sp.time_section(sp.fold_times([]), NOW))
ok("... and so is a log that is not there", ([], []), sp.read_time_log(FIXTURES / "no-such-log.jsonl"))

# fixtures/time-log.jsonl at 13:00:00: phase 1 finished, 2.1 a gate whose steps overlap, a task
# with no group, 3.1 running and reported. Every value below is worked out from the fixture.
TIMES_NOW = datetime.datetime(2026, 3, 21, 13, 0, 0)
records, problems = sp.read_time_log(FIXTURES / "time-log.jsonl")
times = sp.fold_times(records)
ok("the fixture log reads and folds cleanly", ([], []), (problems, times.problems))
section = sp.time_section(times, TIMES_NOW)
section_lines = section.split("\n")


def row(start: str) -> str:
    return next((line for line in section_lines if line.startswith(start)), "")


has("running work counts to the render's time", "Work still running counts to 2026-03-21 13:00:00.",
    section)
ok("a finished phase: wall time from the first dispatch to the last done, implement and review "
   "summed, the mean per finished task",
   "| 1 · Foundation | 2 | 1h 10m | 1h 45m | 21m 00s | 1h 03m | — |", row("| 1 · "))
ok("a running phase counts to now, and carries its stall",
   "| 2 · Gate (running) | 0 | 2h 30m | 2h 30m | — | — | 30m 00s |", row("| 2 · "))
ok("a task with no group, done without a report: all of it implementation",
   "| Ungrouped | 1 | 10m 00s | 10m 00s | — | 10m 00s | — |", row("| Ungrouped "))
ok("an unnamed group is named by its id",
   "| 3 (running) | 0 | 20m 00s | 15m 00s | 5m 00s | — | — |", row("| 3 "))
ok("the totals: wall time across everything, the mean over the three finished tasks",
   "| **All** (running) | 3 | 3h 59m | 4h 40m | 26m 00s | 45m 30s | 30m 00s |", row("| **All**"))
ok("an hour to the second is 1h 00m, a minute to the second 1m 00s; a pipe in a title is escaped",
   "| 1.2 | Cache \\| content keys | 2026-03-21 09:10:00 | 1h 00m | 1m 00s | 1h 01m | — | 0 |",
   row("| 1.2 "))
ok("a running task without a report", "| 2.1 | Phase gate (running) | 2026-03-21 10:30:00 | 2h 30m | — "
   "| 2h 30m | 30m 00s | — |", row("| 2.1 "))
ok("a running task after its report: review counts to now",
   "| 3.1 | Docs (running) | 2026-03-21 12:40:00 | 15m 00s | 5m 00s | 20m 00s | — | — |", row("| 3.1 "))
ok("a step with its commits", "| build | Build and test | 2026-03-21 10:30:00 | 2026-03-21 10:40:00 "
   "| 2026-03-21 11:20:00 | 2026-03-21 11:30:00 | 1h 00m | 3 | green |", row("| build "))
ok("a running step counts to now", "| fixes | Review fixes (running) | 2026-03-21 12:15:00 "
   "| 2026-03-21 12:30:00 | 2026-03-21 12:50:00 | — | 45m 00s | 2 |  |", row("| fixes "))
# Build 10:30-11:30 and review 10:45-11:45 overlap by 45 minutes; nothing ran 11:45-12:15.
ok("overlapping steps: wall time beside step time, the overlap and the gap named",
   "3 steps, 5 commits · wall time 2h 30m · step time 2h 45m · 45m 00s of it in parallel · "
   "30m 00s with no step running.", row("3 steps"))
ok("the stall, named", "| Task 2.1 | 2026-03-21 11:45:00 | 2026-03-21 12:15:00 | 30m 00s "
   "| review done; nobody dispatched the fixes |", row("| Task 2.1 "))
ok("groups in the order the log met them",
   ["### 1 · Foundation", "### 2 · Gate", "### Ungrouped", "### 3", "### Idle stalls"],
   [line for line in section_lines if line.startswith("###")])
finished = sp.fold_times([r for r in records if r.get("task") != "2.1" and r.get("where") != "2.1"
                          and r.get("task") != "3.1"])
has("with nothing running, no render time is stated, so the section does not change between renders",
    "counts to", sp.time_section(finished, TIMES_NOW), present=False)

# The section in the board: replaced in place, everything else kept to the byte.
board_text = (FIXTURES / "example.md").read_text(encoding="utf-8")
head, tail = board_text.split("## Key rulings", 1)
tail = "## Key rulings" + tail
ok("a board without the section gains it after the plan's section",
   head + section + "\n" + tail, sp.with_time_section(board_text, section))
stale = head + "## Time spent\n\nold timings\n\n| Lane | Tasks done | State |\n|---|---|---|\n| A | 1/2 | done |\n\n"
ok("re-rendering replaces the section in place and touches nothing else",
   head + section + "\n" + tail, sp.with_time_section(stale + tail, section))
once = sp.with_time_section(board_text, section)
ok("... and again changes nothing", once, sp.with_time_section(once, section))
ok("a section at the end of the file is replaced to the end",
   "# x\n\n## Current plan: y\n\nWhat y is.\n\n" + EMPTY,
   sp.with_time_section("# x\n\n## Current plan: y\n\nWhat y is.\n\n## Time spent\n\nold\n", EMPTY))
ok("a board with no trailing newline gains a blank line before it",
   "# x\n\n## Current plan: y\n\nWhat y is.\n\n" + EMPTY,
   sp.with_time_section("# x\n\n## Current plan: y\n\nWhat y is.", EMPTY))
FENCED = "# x\n\n## Current plan: y\n\nWhat y is.\n\n```\n## Time spent\nkept\n```\n\n## Key rulings\n"
ok("a heading in a code fence is not the section",
   FENCED.replace("## Key rulings", EMPTY + "\n## Key rulings"), sp.with_time_section(FENCED, EMPTY))
ok("without a plan the section goes at the end", "# x\n\n- one\n\n" + EMPTY,
   sp.with_time_section("# x\n\n- one\n", EMPTY))

# On disk: the byte-order mark and the line endings are the file's own, and stay so.
scratch = Path(tempfile.mkdtemp(prefix="status-board-selftest-"))
try:
    crlf = scratch / "STATUS.md"
    crlf.write_bytes(codecs.BOM_UTF8 + board_text.replace("\n", "\r\n").encode("utf-8"))
    ok("refreshing returns the board as the renderer reads it",
       head + section + "\n" + tail, sp.refresh_time_section(crlf, section))
    ok("... and writes it with the file's BOM and CRLF line endings",
       codecs.BOM_UTF8 + (head + section + "\n" + tail).replace("\n", "\r\n").encode("utf-8"),
       crlf.read_bytes())

    # The CLI, in-process with a pinned clock: each event is stamped when it is logged, and an
    # event the log cannot take is refused with nothing written.
    log = scratch / "times.jsonl"

    def event(hms: tuple, *argv: str) -> tuple:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = tl.main(["--log", str(log), *argv], clock=lambda: datetime.datetime(2026, 3, 21, *hms, 123456))
        return code, out.getvalue().strip(), err.getvalue().strip()

    def lines() -> list[str]:
        return log.read_text(encoding="utf-8").splitlines() if log.is_file() else []

    ok("group: logged with the clock's time, to the second", (0, "2026-03-21 09:00:00 group 1: Foundation", ""),
       event((9, 0, 0), "group", "1", "Foundation"))
    ok("start: in the group its id names", (0, "2026-03-21 09:00:05 start 1.1 in group 1", ""),
       event((9, 0, 5), "start", "1.1", "Parser"))
    ok("... as the record says", {"logged": "2026-03-21 09:00:05", "event": "start", "task": "1.1",
                                  "title": "Parser", "group": "1"}, json.loads(lines()[-1]))
    ok("start --group overrides the id", (0, "2026-03-21 09:01:00 start lane-a.3 in group cache", ""),
       event((9, 1, 0), "start", "lane-a.3", "Keys", "--group", "cache"))
    ok("an id without a dot is in no group", (0, "2026-03-21 09:02:00 start hotfix", ""),
       event((9, 2, 0), "start", "hotfix", "Release hotfix"))
    before = lines()
    refusals = [
        ("a second start", ((9, 3, 0), "start", "1.1", "Again"), "task 1.1 already started at 2026-03-21 09:00:05"),
        ("a report for a task never started", ((9, 3, 0), "report", "9.9"), "task 9.9 was never started"),
        ("a report time without its seconds", ((9, 3, 0), "report", "1.1", "--at", "2026-03-21 09:02"),
         "'2026-03-21 09:02' is not YYYY-MM-DD HH:MM:SS"),
        ("a report before its dispatch", ((9, 3, 0), "report", "1.1", "--at", "2026-03-21 08:59:59"),
         "2026-03-21 08:59:59 is not between task 1.1's start and now"),
        ("a report after now", ((9, 3, 0), "report", "1.1", "--at", "2026-03-21 09:03:01"),
         "2026-03-21 09:03:01 is not between task 1.1's start and now"),
        ("negative fix rounds", ((9, 3, 0), "done", "1.1", "--fix-rounds", "-1"),
         "--fix-rounds counts rounds; it cannot be negative"),
        ("a step of a task never started", ((9, 3, 0), "step", "9.9", "a", "x"), "task 9.9 was never started"),
        ("the end of a step never started", ((9, 3, 0), "step-done", "1.1", "a"), "task 1.1 has no step a"),
        ("a stall for nothing in the log", ((9, 3, 0), "idle", "7", "2026-03-21 09:00:00", "x"),
         "no task or group 7 in the log"),
        ("a stall that begins after now", ((9, 3, 0), "idle", "1", "2026-03-21 09:03:01", "x"),
         "2026-03-21 09:03:01 is not between 1's start and now"),
        ("a stall that begins before its task", ((9, 3, 0), "idle", "1.1", "2026-03-21 09:00:04", "x"),
         "2026-03-21 09:00:04 is not between 1.1's start and now"),
        ("a stall that begins before its group's first task", ((9, 3, 0), "idle", "1", "2020-01-01 00:00:00", "x"),
         "2020-01-01 00:00:00 is not between 1's start and now"),
    ]
    for what, (hms, *argv), message in refusals:
        ok(f"refused: {what}", (1, "", f"error: {message}"), event(hms, *argv))
    ok("... with nothing written", before, lines())
    ok("report --at takes the message's time", (0, "2026-03-21 09:45:35 report 1.1 at 2026-03-21 09:40:00", ""),
       event((9, 45, 35), "report", "1.1", "--at", "2026-03-21 09:40:00"))
    ok("a second report keeps the first, and writes nothing",
       (0, "task 1.1: its first report is logged at 2026-03-21 09:40:00; kept", "", len(before) + 1),
       event((9, 50, 0), "report", "1.1") + (len(lines()),))
    event((10, 0, 0), "step", "1.1", "build", "Build")
    ok("refused: a second start of a step",
       (1, "", "error: step build of task 1.1 already started at 2026-03-21 10:00:00"),
       event((10, 0, 1), "step", "1.1", "build", "Again"))
    event((10, 30, 0), "step-done", "1.1", "build", "--note", "green")
    event((10, 40, 0), "idle", "1", "2026-03-21 10:30:00", "waiting on the review")
    event((10, 45, 0), "done", "1.1", "--fix-rounds", "1")
    ok("the log only ever grows: every earlier line is still there, unchanged", before, lines()[:len(before)])
    task = sp.fold_times(sp.read_time_log(log)[0]).tasks["1.1"]
    ok("... and folds to what was logged",
       ("2026-03-21 09:00:05", "2026-03-21 09:40:00", "2026-03-21 10:45:00", 1, "green"),
       (sp.when(task.start), sp.when(task.report), sp.when(task.done), task.fix_rounds, task.steps["build"].note))

    # A log is read as leniently as it can be, and what it skips is said, as a render warning.
    log.write_text('{"logged": "2026-03-21 09:00:00", "event": "start", "task": "1", "title": "x"}\n'
                   'not json\n\n{"logged": "yesterday", "event": "done", "task": "1"}\n'
                   '{"logged": "2026-03-21 09:05:00", "event": "report", "task": "2"}\n', encoding="utf-8")
    records, problems = sp.read_time_log(log)
    ok("an unreadable line, or one without its stamp, is skipped and said",
       ["time log line 2 is not a stamped record; skipped", "time log line 4 is not a stamped record; skipped"],
       problems)
    ok("a record that matches nothing before it is skipped and said",
       ["time log: a 'report' record logged 2026-03-21 09:05:00 matches nothing logged before it; skipped"],
       sp.fold_times(records).problems)
    ok("the first report counts, however many a log holds", "2026-03-21 09:10:00", sp.when(sp.fold_times([
        {"logged": "2026-03-21 09:00:00", "event": "start", "task": "1", "title": "x"},
        {"logged": "2026-03-21 09:10:00", "event": "report", "task": "1"},
        {"logged": "2026-03-21 09:20:00", "event": "report", "task": "1", "at": "2026-03-21 09:15:00"},
    ]).tasks["1"].report))
finally:
    shutil.rmtree(scratch, ignore_errors=True)

# Rendered, the section raises no warning and adds no progress: its tables are not progress tables
# by their columns, and the renderer would not read them as progress even if a log made them look
# like it — step ids of 1/2 and 2/2, titled with state words.
b = sp.render(sp.with_time_section(board_text, section), now=NOW)
p = check_page("example with timings", b)
ok("example with timings: the progress is still the board's own", (4, "10 of 19 tasks done · 1 of 4 lanes landed"),
   (len(b.rows), b.headline))
has("example with timings: the section is on the page", "<h2>Time spent</h2>", b.page)
ok("example with timings: one table for the board's progress, and seven for its timings", 8,
   p.count("table-wrap"))
span = sp.time_section_span(sp.with_time_section(board_text, section).split("\n"))
timing_tables = [t for t in sp.find_tables(sp.with_time_section(board_text, section).split("\n"))
                 if span[0] <= t.start < span[1]]
ok("no table of the section has the columns of a progress table", [None] * 7,
   [sp.progress_columns(t) for t in timing_tables])
LOOKALIKE = [
    {"logged": "2026-03-21 09:00:00", "event": "start", "task": "1.1", "title": "x", "group": "1"},
    {"logged": "2026-03-21 09:00:00", "event": "step", "task": "1.1", "step": "1/2", "title": "done"},
    {"logged": "2026-03-21 09:00:00", "event": "step", "task": "1.1", "step": "2/2", "title": "review"},
]
lookalike = sp.with_time_section(board_text, sp.time_section(sp.fold_times(LOOKALIKE), TIMES_NOW))
steps_table = [t for t in sp.find_tables(lookalike.split("\n")) if t.header[0] == "Step"]
ok("a step table can look like progress", True, sp.progress_columns(steps_table[0]) is not None)
b = sp.render(lookalike, now=NOW)
ok("... and still draws no bars and raises no warning", (4, []), (len(b.rows), b.warnings))

# ============================================================================================
# The command line, in throwaway repositories
# ============================================================================================


def remove(path: Path) -> None:
    def force(func, target, _):
        os.chmod(target, stat.S_IWRITE)
        func(target)

    if sys.version_info >= (3, 12):
        shutil.rmtree(path, onexc=force)
    else:
        shutil.rmtree(path, onerror=force)


tmp = Path(tempfile.mkdtemp(prefix="status-board-selftest-"))
try:
    (tmp / "gitconfig").write_text("", encoding="utf-8")
    env = dict(os.environ, GIT_CONFIG_GLOBAL=str(tmp / "gitconfig"), GIT_CONFIG_NOSYSTEM="1",
               GIT_AUTHOR_NAME="selftest", GIT_AUTHOR_EMAIL="selftest@example.invalid",
               GIT_COMMITTER_NAME="selftest", GIT_COMMITTER_EMAIL="selftest@example.invalid")

    def run(*args, cwd: Path) -> subprocess.CompletedProcess:
        return subprocess.run(list(args), cwd=cwd, env=env, capture_output=True, text=True,
                              encoding="utf-8", errors="replace")

    def page_script(*args, cwd: Path) -> subprocess.CompletedProcess:
        return run(sys.executable, str(SCRIPT), *args, cwd=cwd)

    def time_script(*args, cwd: Path) -> subprocess.CompletedProcess:
        return run(sys.executable, str(TIME_SCRIPT), *args, cwd=cwd)

    loose = tmp / "loose"
    loose.mkdir()
    r = page_script(cwd=loose)
    ok("outside git without --source: refused", (1, True),
       (r.returncode, "not inside a git repository" in r.stderr))

    shutil.copy(FIXTURES / "blocked.md", tmp / "timed.md")
    r = page_script("--source", str(tmp / "timed.md"), "--time-log", str(FIXTURES / "time-log.jsonl"),
                    "--output", str(tmp / "timed.html"), cwd=tmp)
    ok("--time-log: the section comes from the log named, with no warning", (0, True, ""),
       (r.returncode, "; 5 timed tasks;" in r.stdout, r.stderr))
    has("... and is written into the board", "| 1.2 | Cache \\| content keys | 2026-03-21 09:10:00 | 1h 00m "
        "| 1m 00s | 1h 01m | — | 0 |", (tmp / "timed.md").read_text(encoding="utf-8"))
    (tmp / "broken.jsonl").write_text("not json\n", encoding="utf-8")
    r = page_script("--source", str(tmp / "timed.md"), "--time-log", str(tmp / "broken.jsonl"),
                    "--output", str(tmp / "timed.html"), cwd=tmp)
    ok("a line the log cannot read is a render warning",
       "warning: time log line 1 is not a stamped record; skipped", r.stderr.strip())

    r = run(sys.executable, "-c",
            "import runpy, sys; sys.modules['markdown'] = None; sys.argv = ['status_page.py']; "
            f"runpy.run_path({str(SCRIPT)!r}, run_name='__main__')", cwd=loose)
    ok("without the markdown package: exit 1 and one line naming the fix",
       (1, "status_page.py needs the markdown package: pip install markdown"),
       (r.returncode, r.stderr.strip()))

    if shutil.which("git") is None:
        skipped.append("git cases (git not on PATH)")
    else:
        repo = tmp / "repo"
        run("git", "init", "-q", str(repo), cwd=tmp)
        shutil.copy(FIXTURES / "example.md", repo / "STATUS.md")
        exclude = repo / ".git" / "info" / "exclude"
        exclude.parent.mkdir(exist_ok=True)
        with open(exclude, "a", encoding="utf-8") as f:
            f.write("/STATUS.md\n")
        (repo / "sub").mkdir()

        r = page_script(cwd=repo / "sub")
        main_page = repo / ".git" / "status-board.html"
        ok("from a subdirectory: exit 0", 0, r.returncode)
        ok("the default output lands in the working tree's git dir", True, main_page.is_file())
        has("the summary line is ASCII and carries the headline",
            "10 of 19 tasks done, 1 of 4 lanes landed)", r.stdout)
        ok("git sees nothing the board wrote", "", run("git", "status", "--porcelain", cwd=repo).stdout)
        ok("with no time log yet, the board says so after its plan, and nothing else changes",
           (True, head + EMPTY + "\n" + tail),
           ("; no timed work;" in r.stdout, (repo / "STATUS.md").read_text(encoding="utf-8")))

        # Every worktree has a board of its own, so sessions in different worktrees run in
        # parallel: its own STATUS.md, its own page and its own URL, none shared with another.
        run("git", "commit", "-q", "--allow-empty", "-m", "fixture", cwd=repo)
        worktree = tmp / "wt"
        run("git", "worktree", "add", "-q", "-b", "selftest-wt", str(worktree), cwd=repo)
        r = page_script(cwd=worktree)
        ok("a linked worktree without a STATUS.md of its own does not render the main tree's",
           (1, True), (r.returncode, r.stderr.strip().replace("\\", "/").endswith("wt/STATUS.md: no such file")))
        shutil.copy(FIXTURES / "blocked.md", worktree / "STATUS.md")
        main_before = main_page.read_text(encoding="utf-8")
        r = page_script(cwd=worktree)
        worktree_page = repo / ".git" / "worktrees" / "wt" / "status-board.html"
        ok("from a linked worktree: exit 0", 0, r.returncode)
        has("... it renders its own STATUS.md", "7 of 13 tasks done, 1 of 4 lanes landed)", r.stdout)
        ok("... into its own git dir", True, worktree_page.is_file())
        ok("... and leaves the main tree's page alone", main_before, main_page.read_text(encoding="utf-8"))
        ok("the shared exclude covers the worktree's STATUS.md: it stays clean",
           "", run("git", "status", "--porcelain", cwd=worktree).stdout)

        # The time log is the worktree's own too, beside its page. The times come from the clock,
        # so these cases compare against the commits' own dates, not values fixed in advance.
        r = time_script("start", "1.1", "Reader", cwd=worktree)
        ok("time_log.py from a linked worktree: exit 0", 0, r.returncode)
        ok("... into the worktree's own git dir, not the main tree's", (True, False),
           ((repo / ".git" / "worktrees" / "wt" / sp.TIME_LOG).is_file(), (repo / ".git" / sp.TIME_LOG).is_file()))
        run("git", "commit", "-q", "--allow-empty", "-m", "one", cwd=worktree)
        run("git", "commit", "-q", "--allow-empty", "-m", "two", cwd=worktree)
        first, last = run("git", "show", "-s", "--format=%ad", f"--date=format-local:{sp.STAMP_FORMAT}",
                          "HEAD~1", "HEAD", cwd=worktree).stdout.split("\n")[:2]
        r = time_script("report", "1.1", "--commit", "HEAD~1", cwd=worktree)
        ok("report --commit takes the commit's author date", (0, True),
           (r.returncode, r.stdout.strip().endswith(f" report 1.1 at {first}")))
        time_script("step", "1.1", "build", "Build and test", cwd=worktree)
        r = time_script("step-commits", "1.1", "build", "HEAD~2..HEAD", cwd=worktree)
        ok("step-commits reads a range: its count, first and last author dates", (0, True),
           (r.returncode, r.stdout.strip().endswith(f" step-commits 1.1 build: 2, {first} to {last}")))
        for rev, message in (("HEAD..HEAD", "HEAD..HEAD names no commits"),
                             ("no-such-rev", "git cannot read no-such-rev")):
            r = time_script("step-commits", "1.1", "build", rev, cwd=worktree)
            ok(f"step-commits refuses {rev}", (1, f"error: {message}"), (r.returncode, r.stderr.strip()))
        try:
            tl.commit_dates(["-p"], worktree)
            refused = None
        except tl.Refused as refusal:
            refused = str(refusal)
        ok("a revision that git would read as an option is refused", "'-p' is not a commit", refused)
        time_script("step-done", "1.1", "build", "--note", "green", cwd=worktree)
        time_script("done", "1.1", "--fix-rounds", "0", cwd=worktree)
        r = page_script(cwd=worktree)
        status = (worktree / "STATUS.md").read_text(encoding="utf-8")
        ok("the render rebuilds the worktree's section from its own log", (0, True, True),
           (r.returncode, "; 1 timed task;" in r.stdout, "| 1.1 | Reader | " in status))
        has("... with the step's first and last commit", f"| {first} | {last} |", status)
        ok("... after the board's own text, which stays as it was",
           True, status.startswith((FIXTURES / "blocked.md").read_text(encoding="utf-8")))
        written = (worktree / "STATUS.md").read_bytes()
        page_script(cwd=worktree)
        ok("with nothing running, a second render leaves the file as it was",
           written, (worktree / "STATUS.md").read_bytes())
        ok("git sees nothing the time log wrote", "", run("git", "status", "--porcelain", cwd=worktree).stdout)

        none_yet = "(none yet; the first publish creates it)"
        ok("no URL remembered yet", none_yet, page_script("--url", cwd=worktree).stdout.strip())
        page_script("--remember-url", "https://claude.ai/artifact/wt", cwd=worktree)
        ok("a worktree remembers its URL", "https://claude.ai/artifact/wt",
           page_script("--url", cwd=worktree).stdout.strip())
        ok("... which the main tree does not see", none_yet, page_script("--url", cwd=repo).stdout.strip())
        ok("... nor git config, which every worktree shares", "",
           run("git", "config", "--get-regexp", "status-board", cwd=repo).stdout)

        run("git", "config", "--local", "status-board.url", "https://claude.ai/artifact/legacy", cwd=repo)
        ok("the URL from before per-worktree boards belongs to the main tree",
           ("https://claude.ai/artifact/legacy", "https://claude.ai/artifact/wt"),
           (page_script("--url", cwd=repo / "sub").stdout.strip(),
            page_script("--url", cwd=worktree).stdout.strip()))
        page_script("--remember-url", "https://claude.ai/artifact/main", cwd=repo)
        ok("remembering a URL in the main tree retires the old key",
           ("https://claude.ai/artifact/main", ""),
           (page_script("--url", cwd=repo).stdout.strip(),
            run("git", "config", "--get-regexp", "status-board", cwd=repo).stdout))
        r = run(sys.executable, "-c",
                "import runpy, sys; sys.modules['markdown'] = None; "
                "sys.argv = ['status_page.py', '--url']; "
                f"runpy.run_path({str(SCRIPT)!r}, run_name='__main__')", cwd=repo)
        ok("--url needs no markdown package", (0, "https://claude.ai/artifact/main"),
           (r.returncode, r.stdout.strip()))
        r = page_script("--remember-url", "not a url", cwd=repo)
        ok("a URL with whitespace is refused", (1, "https://claude.ai/artifact/main"),
           (r.returncode, page_script("--url", cwd=repo).stdout.strip()))

        r = page_script("--output", str(repo / "page.html"), cwd=repo)
        has("an --output in the working tree is warned", "could be committed", r.stderr)

        r = page_script("--source", str(repo / "STATUS.md"), "--standalone",
                        "--output", str(tmp / "standalone.html"), cwd=tmp)
        ok("--standalone from the command line", True,
           (tmp / "standalone.html").read_text(encoding="utf-8").startswith("<!doctype html>"))

        if run("git", "rev-parse", "--git-dir", cwd=loose).returncode == 0:
            skipped.append("temp-dir fallback (the temp directory is inside a git repository)")
        else:
            shutil.copy(FIXTURES / "blocked.md", loose / "STATUS.md")
            r = page_script("--source", str(loose / "STATUS.md"), cwd=loose)
            m = re.match(r"wrote (.+?) \(", r.stdout)
            written = Path(m.group(1)) if m else None
            ok("outside git with --source: the page goes to the temp directory",
               Path(tempfile.gettempdir()).resolve(), written.parent.resolve() if written else None)
            if written is not None and written.is_file():
                written.unlink()
            r = time_script("start", "1", "x", cwd=loose)
            ok("time_log.py outside git without --log: refused",
               (1, "error: not inside a git working tree; pass --log"), (r.returncode, r.stderr.strip()))
finally:
    remove(tmp)

# ============================================================================================
# Python 3.9 grammar
# ============================================================================================

for source in (SCRIPT, TIME_SCRIPT, Path(__file__).resolve()):
    try:
        ast.parse(source.read_text(encoding="utf-8"), feature_version=(3, 9))
        ok(f"{source.name} parses as Python 3.9", True, True)
    except SyntaxError as exc:
        ok(f"{source.name} parses as Python 3.9", "no error", str(exc))

for note in skipped:
    print(f"skipped: {note}")
print(f"status_page self-test: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
