#!/usr/bin/env python3
"""Stamp a run's events into the status board's time log, at the moment each one happens.

The status-board skill runs this at every dispatch, report, completion and step of a long task, in
the same turn as the event, and status_page.py rebuilds the board's "## Time spent" section from
the log at every render. Each record is stamped by the clock as it is written; the only other times
it takes come from a record — a message's time, a commit's author date — never from memory.

    python3 time_log.py [--log FILE] group <group> <name>
    python3 time_log.py [--log FILE] start <task> <title> [--group GROUP]
    python3 time_log.py [--log FILE] report <task> [--at TIME | --commit REV]
    python3 time_log.py [--log FILE] done <task> [--fix-rounds N]
    python3 time_log.py [--log FILE] step <task> <step> <title>
    python3 time_log.py [--log FILE] step-commits <task> <step> <rev>...
    python3 time_log.py [--log FILE] step-done <task> <step> [--note TEXT]
    python3 time_log.py [--log FILE] idle <task-or-group> <since> <what>

group         Names a lane or phase. A task is in the group --group gives, else in the part of its
              id before the first dot: task 2.5 is in group 2.
start         A task dispatched. A task id is started once.
report        Its first commit or report: now, or --at the message's own time, or --commit for that
              commit's author date. The first one logged counts; implementation ends there.
done          The task complete, with the review rounds it took. A later done replaces an earlier.
step          A step of a long task begins: a gate's build, a review, a round of fixes. Steps may
              run in parallel; the board sets their wall time beside their summed time.
step-commits  The step's commits, as git show takes them — commits or ranges: their first and last
              author dates and their count. A later call replaces an earlier one.
step-done     The step complete, with an optional note.
idle          A stall, named: from <since>, the last record of activity, to now, when it was found.
              It cannot begin before the task it stalls, or the first task of the group.

--log FILE    Defaults to status-board.times.jsonl in the working tree's git dir, beside the page.

Times are local, YYYY-MM-DD HH:MM:SS. Each command prints the record's time and what it logged,
so the same time can go into STATUS.md. An event the log cannot take — a report for a task never
started, a second start — is refused with exit 1, and nothing is written.

Needs Python 3.9+ and git; not the markdown package.
"""

from __future__ import annotations

import argparse
import datetime
import json
import sys
from collections.abc import Callable
from pathlib import Path

sys.dont_write_bytecode = True  # importing the renderer must not leave a __pycache__ in the plugin
import status_page as sp  # noqa: E402  (the renderer reads the log; this writes it)

Clock = Callable[[], datetime.datetime]


class Refused(Exception):
    """An event the log cannot take as given. Nothing is written."""


def commit_dates(revs: list[str], cwd: Path) -> list[datetime.datetime]:
    """The author dates of the commits revs name, a commit or a range each, as git show reads them."""
    for rev in revs:
        if rev.startswith("-"):  # git would read it as an option
            raise Refused(f"'{rev}' is not a commit")
    out = sp.git("show", "-s", "--format=%ad", f"--date=format-local:{sp.STAMP_FORMAT}", *revs, "--", cwd=cwd)
    if out is None:
        raise Refused(f"git cannot read {' '.join(revs)}")
    dates = [sp.stamp(line) for line in out.splitlines() if line.strip()]
    if not dates:
        raise Refused(f"{' '.join(revs)} names no commits")
    return dates


def record_for(args: argparse.Namespace, times: sp.Times, now: datetime.datetime,
               cwd: Path) -> tuple[dict | None, str]:
    """The record args describe, checked against the log so far, and the line that reports it.

    No record when there is nothing to log: a report for a task whose first one is logged.
    """
    record = {"logged": now.strftime(sp.STAMP_FORMAT), "event": args.event}
    if args.event == "group":
        record.update(group=args.group, name=args.name)
        return record, f"group {args.group}: {args.name}"

    if args.event == "start":
        if args.task in times.tasks:
            raise Refused(f"task {args.task} already started at {sp.when(times.tasks[args.task].start)}")
        group = args.group
        if group is None:
            group = args.task.split(".", 1)[0] if "." in args.task else ""
        record.update(task=args.task, title=args.title, group=group)
        return record, f"start {args.task}" + (f" in group {group}" if group else "")

    if args.event == "idle":
        # A stall cannot begin before the work it stalls: a task's dispatch, or its group's first.
        if args.where in times.tasks:
            floor = times.tasks[args.where].start
        elif args.where in times.groups:
            floor = min((t.start for t in times.tasks.values() if t.group == args.where), default=times.began)
        else:
            raise Refused(f"no task or group {args.where} in the log")
        since = sp.stamp(args.since)
        if since is None:
            raise Refused(f"'{args.since}' is not YYYY-MM-DD HH:MM:SS")
        if not floor <= since <= now:
            raise Refused(f"{args.since} is not between {args.where}'s start and now")
        record.update(where=args.where, since=args.since, what=args.what)
        return record, f"idle {args.where} since {args.since}"

    task = times.tasks.get(args.task)
    if task is None:
        raise Refused(f"task {args.task} was never started")
    record["task"] = args.task

    if args.event == "report":
        if task.report is not None:
            return None, f"task {args.task}: its first report is logged at {sp.when(task.report)}; kept"
        at = sp.stamp(args.at) if args.at is not None else None
        if args.at is not None and at is None:
            raise Refused(f"'{args.at}' is not YYYY-MM-DD HH:MM:SS")
        if args.commit is not None:
            at = min(commit_dates([args.commit], cwd))
        if at is not None and not task.start <= at <= now:
            raise Refused(f"{sp.when(at)} is not between task {args.task}'s start and now")
        if at is not None:
            record["at"] = sp.when(at)
        return record, f"report {args.task}" + (f" at {record['at']}" if at is not None else "")

    if args.event == "done":
        if args.fix_rounds is not None and args.fix_rounds < 0:
            raise Refused("--fix-rounds counts rounds; it cannot be negative")
        if args.fix_rounds is not None:
            record["fix_rounds"] = args.fix_rounds
        return record, f"done {args.task}"

    step = task.steps.get(args.step)
    record["step"] = args.step
    if args.event == "step":
        if step is not None:
            raise Refused(f"step {args.step} of task {args.task} already started at {sp.when(step.start)}")
        record["title"] = args.title
        return record, f"step {args.task} {args.step}"
    if step is None:
        raise Refused(f"task {args.task} has no step {args.step}")
    if args.event == "step-commits":
        dates = commit_dates(args.revs, cwd)
        record.update(first=sp.when(min(dates)), last=sp.when(max(dates)), count=len(dates))
        return record, f"step-commits {args.task} {args.step}: {len(dates)}, {record['first']} to {record['last']}"
    if args.note is not None:
        record["note"] = args.note
    return record, f"step-done {args.task} {args.step}"


def parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description="Stamp a run's events into the status board's time log.")
    p.add_argument("--log", metavar="FILE", help=f"the time log (default: <git dir>/{sp.TIME_LOG})")
    events = p.add_subparsers(dest="event", required=True, metavar="event")

    e = events.add_parser("group", help="name a lane or phase")
    e.add_argument("group")
    e.add_argument("name")

    e = events.add_parser("start", help="a task dispatched")
    e.add_argument("task")
    e.add_argument("title")
    e.add_argument("--group", help="its lane or phase (default: its id up to the first dot)")

    e = events.add_parser("report", help="a task's first commit or report")
    e.add_argument("task")
    at = e.add_mutually_exclusive_group()
    at.add_argument("--at", metavar="TIME", help="the report's own time, YYYY-MM-DD HH:MM:SS")
    at.add_argument("--commit", metavar="REV", help="the time of this commit's author date")

    e = events.add_parser("done", help="a task complete")
    e.add_argument("task")
    e.add_argument("--fix-rounds", type=int, metavar="N", help="the review rounds it took")

    e = events.add_parser("step", help="a step of a long task begins")
    e.add_argument("task")
    e.add_argument("step")
    e.add_argument("title")

    e = events.add_parser("step-commits", help="a step's commits: first and last author date, count")
    e.add_argument("task")
    e.add_argument("step")
    e.add_argument("revs", nargs="+", metavar="rev", help="a commit or a range, as git show takes it")

    e = events.add_parser("step-done", help="a step complete")
    e.add_argument("task")
    e.add_argument("step")
    e.add_argument("--note")

    e = events.add_parser("idle", help="a stall, from SINCE to now")
    e.add_argument("where", metavar="task-or-group")
    e.add_argument("since", help="the last record of activity, YYYY-MM-DD HH:MM:SS")
    e.add_argument("what", help="what stalled, and on what")
    return p


def main(argv: list[str] | None = None, clock: Clock = datetime.datetime.now) -> int:
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(errors="replace")

    args = parser().parse_args(argv)
    cwd = Path.cwd()
    path = Path(args.log) if args.log else sp.time_log_path(cwd)
    if path is None:
        print("error: not inside a git working tree; pass --log", file=sys.stderr)
        return 1
    records, problems = sp.read_time_log(path)
    for problem in problems:
        print(f"warning: {problem}", file=sys.stderr)

    now = clock().replace(tzinfo=None, microsecond=0)  # local, to the second, as the log keeps it
    try:
        record, line = record_for(args, sp.fold_times(records), now, cwd)
    except Refused as refused:
        print(f"error: {refused}", file=sys.stderr)
        return 1
    if record is not None:
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "a", encoding="utf-8", newline="\n") as f:
            f.write(json.dumps(record, ensure_ascii=False) + "\n")
        line = f"{record['logged']} {line}"
    print(line)
    return 0


if __name__ == "__main__":
    sys.exit(main())
