# acme — status

Local-only tracker: excluded via `.git/info/exclude`, never committed.

**Last updated:** 2026-03-21 17:45:12

## Current plan: drop the legacy config format

The reader accepts only the new format, a converter moves old files across, and the release
notes say how. Done means all four lanes merged and the converter tested on the sample configs.

| Lane | Tasks done | State | Where it is |
|---|---|---|---|
| Reader: new format only | 4/4 | merged | #212 |
| Converter: `acme migrate` | 2/5 | blocked — waiting on the schema decision | task 3 needs the final key names |
| Docs | 1/3 | running | |
| Release notes | 0/1 | on hold | |

**Now:** docs task 2.
**Blocked:** the converter, on the schema decision (owner).
**Next:** converter tasks 3–5 once the keys are settled.
