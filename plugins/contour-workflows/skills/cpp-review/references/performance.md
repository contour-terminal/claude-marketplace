# Performance

The discipline here is proportionality. A needless `string` copy in a config parser that runs once at startup is not worth a review comment; the same copy in a render loop or a per-packet path is a real finding. So establish first whether the changed code is hot — called per frame, per request, per row, per character — and calibrate accordingly. When you're unsure, say which assumption you're reviewing under.

Avoid asserting speedups you haven't measured. "This copies the buffer on every call" is a fact; "this is 3x slower" is a guess unless you benchmarked it.

## Copies

- Parameters taken by value that should be `const&`: any container, string, or class with non-trivial copy. The exception is the sink parameter — taken by value then `std::move`d into a member — which is correct and shouldn't be flagged.
- `for (auto x : container)` where `x` is a non-trivial type. Should be `const auto&`.
- Structured bindings over a map: `for (auto [k, v] : m)` copies each pair. Needs `const auto&`.
- `auto` that silently decays into a copy: `auto v = obj.GetVector();` when a reference was available.
- Returning `const T` by value, or wrapping the return in `std::move` — both defeat copy elision. Just `return local;`.
- A range-for over a view that recomputes an expensive transform per element per pass.
- Lambdas capturing by value (`[=]`) when they capture a large object and are called in a loop.

## Allocations

- `std::string` built up in a loop with `+`, or `substr` used purely to compare or inspect (`string_view` avoids the allocation).
- Missing `reserve()` before a loop with a known-ahead element count. Worth flagging when the count is genuinely known and the loop is hot; not worth it for a handful of elements.
- `std::function` in a hot path — it type-erases and may allocate. A template parameter or `function_ref`-style type avoids it when the callable doesn't need to be stored.
- `shared_ptr` where `unique_ptr` or a plain object would do: control block allocation plus atomic refcounting on every copy. `make_shared` at least fuses the two allocations.
- Temporary containers built to be immediately consumed — often a `views::` pipeline or a direct loop avoids materializing.
- Formatting/logging that builds a string unconditionally and then discards it because the log level is off. The construction should be behind the level check.

## Algorithmic

These matter far more than micro-copies, and are easier to miss because the code looks innocent.

- A linear scan inside a loop over the same data — accidental O(n²). Common when a `find` on a `vector` moves inside a loop.
- Repeated `map::find` for the same key where one lookup would do (`find` once and reuse the iterator, or `try_emplace`).
- `map::operator[]` on a lookup path — it default-constructs and inserts on miss, which both allocates and silently changes semantics. Use `find` or `at`.
- Sorting inside a loop, or re-sorting an already-sorted container.
- `std::endl` in a loop — flushes every iteration. `'\n'` is right unless a flush is intended.

## Structural

- Large objects passed or returned by value in an interface used at scale.
- Virtual calls in an innermost loop where the type is statically known.
- Header changes that pull a heavy include into a widely-included header — a real cost to build times, and worth mentioning because nobody else will notice.
- `std::move` on a `const` object (silently copies) or on a value that's still used afterward.
- Data structure choice that fights the access pattern: `list` where indices are used, `map` where an unordered container or a sorted vector fits, node-based containers in a cache-sensitive path.

When you suggest a change, note the mechanism — "this allocates once per keystroke because `substr` materializes a new string" — so the author can judge whether it matters in their context rather than taking your word for it.
