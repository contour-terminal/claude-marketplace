# acme — status

Local-only tracker: excluded via `.git/info/exclude`, never committed. Times are local, from `date`, to the second.

**Last updated:** 2026-03-14 16:05:41

## Current plan: streaming input for the parser, with the cache and CLI to match

Done means one pull request to `main` with all four lanes landed on the integration branch
`streaming`, CI green, and the migration guide written. No release in this plan.

**Decisions:**
- 2026-03-10 11:42:07: the buffered reader stays for one release, deprecated, then goes.
- 2026-03-12 09:15:30: the cache keys on content hashes, not paths.

| Lane | Tasks done | State | Where it is |
|---|---|---|---|
| Parser: streaming input | 5/5 | landed | on `streaming` at `4f2a91c`; 212/212 tests |
| Cache: content-hash keys | 3/6 | running | task 4 (eviction under memory pressure) in review |
| CLI: `watch` subcommand | 2/4 | running | task 3 (debounce) running |
| Docs: migration guide | 0/4 | queued | starts when the CLI lane lands |

**Now:** cache task 4 in review; CLI task 3 running.
**Next:** cache tasks 5–6 → CLI task 4 → land both on `streaming` → docs lane → one PR, CI green → merge.

## Key rulings

- A file that changes while it is streamed is read to the length it had when streaming began.
- `watch` reports each change once, however many writes it took.

## Follow-ups

- The benchmark suite still measures the buffered reader only.
