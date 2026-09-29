# acme — status

Local-only tracker: excluded via `.git/info/exclude`, never committed.

**Last updated:** 2026-03-14 09:30

## Current plan: triage the crash reports from the 2.3 release

No lanes yet: the reports are being read and grouped before any work is split.

The table below counts tests, not tasks. It has an N/M column and a Status column, and must not be
drawn as progress.

| Preset | Tests | Status |
|---|---|---|
| debug | 1204/1204 | PASS |
| release | 1203/1204 | FAIL |

**Now:** grouping the reports by stack signature.
**Next:** one lane per group.
