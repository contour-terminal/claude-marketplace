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
import datetime
import html
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
sys.dont_write_bytecode = True  # importing the renderer must not leave a __pycache__ in the plugin
sys.path.insert(0, str(HERE))
import status_page as sp  # noqa: E402  (exits with the pip hint when markdown is missing)

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
ok("example: the h1 is the headline", b.headline, text_of("h1", b.page).replace("\u00a0", " "))
has("example: a wrapped headline keeps the dot on the first line", "done&nbsp;· 1 of", b.page)
has("example: a list right under a paragraph line is still a list",
    "<li>2026-03-10: the buffered reader", b.page)
ok("example: title from the H1", "acme — status", text_of("title", b.page))
ok("example: rungs done", 10, p.count("rung done"))
ok("example: one current rung per running lane", 2, p.count("rung running"))
ok("example: rungs to do", 7, p.count("rung todo"))
ok("example: no blocked rung", 0, p.count("rung blocked"))
ok("example: chips", (1, 2, 1), (p.count("chip done"), p.count("chip running"), p.count("chip queued")))
has("example: the caption names running lanes by their short name",
    "In progress: <strong>Cache, CLI</strong>", b.page)
has("example: no Blocked caption without a blocked lane", "Blocked:", b.page, present=False)
has("example: the stamp is in the masthead", "<b>Last updated</b>2026-03-14 16:05", b.page)
has("example: generation time carries its offset", "Page generated 2026-03-21 18:00 (UTC+01:00)", b.page)
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
   "triage the crash reports from the 2.3 release", b.headline)
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
has("several-tables: without a preamble the plan heading survives",
    "<h2>Current plan: move the build to presets</h2>", b.page)

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

b = sp.render("# x\n\n" + TABLE + "| A | 1/2 | running |\n", now=NOW)
ok("no stamp: warned", ["no **Last updated:** line; the page says so"], b.warnings)
has("no stamp: the page says so", '<span class="missing">not stated in STATUS.md</span>', b.page)

b = sp.render("# x\n\n**Last updated:** yesterday afternoon\n", now=NOW)
ok("a guessed stamp is warned", ["Last updated 'yesterday afternoon' is not YYYY-MM-DD HH:MM"], b.warnings)

b = sp.render("# x\n\n" + TABLE + "| A | 5/4 | running |\n", now=NOW)
has("more done than total is warned", "A: 5/4 counts more tasks done than there are", " ".join(b.warnings))
ok("... and reported as written, not corrected", "5 of 4 tasks done · 0 of 1 lanes done", b.headline)

b = sp.render("# x\n\n" + TABLE + "| A | 1/2 | running |\n| B | 0/2 | in flight |\n", now=NOW)
has("an unknown state is warned", "B: state 'in flight' is not one this page knows",
    " ".join(b.warnings))
ok("... and the row still counts", "1 of 4 tasks done · 0 of 2 lanes done", b.headline)

b = sp.render("# x\n\n" + TABLE + "| Soak tests | 30/50 | running |\n", now=NOW)
has("a long row is a bar, not fifty rungs", '<span class="bar-fill" style="width: 60%;">', b.page)
ok("... with no rungs", 0, Page(b.page).count("rung todo"))

b = sp.render("# x\n\n" + TABLE + "| Build & test | 0/13 | queued |\n", now=NOW)
has("lane names are escaped in the ladder", "Build &amp; test <span", b.page)
has("more than twelve rungs drop their numbers", 'class="ladder dense"', b.page)

b = sp.render("# x\n\n" + TABLE + "| A | 1/1 | done |\n", title="Custom board", now=NOW)
ok("--title overrides the H1", "Custom board", text_of("title", b.page))

STAMPED = "# x\n\n**Last updated:** 2026-03-21 17:00\n\n"

# Two N/M columns. The header decides which one counts, not the position: a Tests column ahead
# of the task count would otherwise draw a lane a third done as finished.
TWO = "| Lane | Tests | {} | State |\n|---|---|---|---|\n| A | 212/212 | 1/3 | running |\n"
b = sp.render(STAMPED + TWO.format("Tasks done"), now=NOW)
ok("two N/M columns: the one headed 'Tasks done' is counted", "1 of 3 tasks done · 0 of 1 lanes done",
   b.headline)
ok("... with no warning", [], b.warnings)
b = sp.render(STAMPED + TWO.format("Progress"), now=NOW)
ok("two N/M columns, neither headed like it: the first is counted",
   "212 of 212 tasks done · 0 of 1 lanes done", b.headline)
ok("... and the guess is warned",
   ["a table has several N/M columns and none headed like 'Tasks done'; counting 'Tests'"], b.warnings)

# Lines 6 and 8 nest at two and three spaces; line 10 nests at four.
b = sp.render(STAMPED + "- parent\n  - child\n1. step\n   - detail\n- next\n    - nested right\n", now=NOW)
ok("nesting at two or three spaces is warned, at four it is not",
   ["line 6: a list item indented 2 spaces under the one above does not nest on the page; indent it four",
    "line 8: a list item indented 3 spaces under the one above does not nest on the page; indent it four"],
   b.warnings)

b = sp.render(STAMPED + "Progress:\n" + TABLE + "| A | 1/2 | running |\n", now=NOW)
ok("a table right under a paragraph line is still a table", 1, len(b.rows))
has("... and is rendered as one", "<td>1/2</td>", b.page)

b = sp.render(STAMPED + "| Lane | Due | State |\n|---|---|---|\n| A | 2026/10/01 | running |\n", now=NOW)
ok("a slash date is not a count", (0, []), (len(b.rows), b.warnings))

b = sp.render(STAMPED + TABLE + "| A | 1/1 | [done](#pr-12) |\n", now=NOW)
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

    loose = tmp / "loose"
    loose.mkdir()
    r = page_script(cwd=loose)
    ok("outside git without --source: refused", (1, True),
       (r.returncode, "not inside a git repository" in r.stderr))

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
        default = repo / ".git" / "info" / "status-board.html"
        ok("from a subdirectory: exit 0", 0, r.returncode)
        ok("the default output lands in .git/info", True, default.is_file())
        has("the summary line is ASCII and carries the headline",
            "10 of 19 tasks done, 1 of 4 lanes landed)", r.stdout)
        ok("git sees nothing the board wrote", "", run("git", "status", "--porcelain", cwd=repo).stdout)

        run("git", "commit", "-q", "--allow-empty", "-m", "fixture", cwd=repo)
        worktree = tmp / "wt"
        run("git", "worktree", "add", "-q", "-b", "selftest-wt", str(worktree), cwd=repo)
        default.unlink(missing_ok=True)
        r = page_script(cwd=worktree)
        ok("from a linked worktree: exit 0", 0, r.returncode)
        ok("... it renders the main tree's STATUS.md into the shared .git/info", True, default.is_file())
        ok("... and the worktree stays clean", "", run("git", "status", "--porcelain", cwd=worktree).stdout)

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
finally:
    remove(tmp)

# ============================================================================================
# Python 3.9 grammar
# ============================================================================================

for source in (SCRIPT, Path(__file__).resolve()):
    try:
        ast.parse(source.read_text(encoding="utf-8"), feature_version=(3, 9))
        ok(f"{source.name} parses as Python 3.9", True, True)
    except SyntaxError as exc:
        ok(f"{source.name} parses as Python 3.9", "no error", str(exc))

for note in skipped:
    print(f"skipped: {note}")
print(f"status_page self-test: {passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
