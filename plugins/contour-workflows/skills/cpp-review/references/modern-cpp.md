# Modern C++ idiom (C++20/23)

The bar for raising an idiom finding is **not** "this could be written more modernly." It's one of:

1. The hand-rolled version has a bug, or an edge case the standard facility handles.
2. The code fights the language — fifty lines of machinery for something the standard library does in one.
3. The code is new, and a reviewer would reasonably expect new code to use what the project already has available.

Rewriting working old code because a newer spelling exists is churn: it costs review time, risks regressions, and buries the findings that mattered. If the only argument is "C++20 has a nicer way," don't raise it. When the project has a modernization effort underway, that's the effort's job, not this review's.

With that said, here is what to actually recognize.

## Where hand-rolling tends to be wrong

**Comparison operators.** Hand-written `==`, `!=`, `<`, `>`, `<=`, `>=` are a common source of asymmetric or intransitive comparisons, especially when a member is added later and one operator isn't updated. `auto operator<=>(const T&) const = default;` is both correct and immune to that drift. A partially-updated comparison set in a diff is a real bug, not a style point.

**SFINAE and `enable_if` chains.** Where the project uses concepts, new `enable_if` machinery produces error messages nobody can read and often gets the constraint subtly wrong. `requires` clauses and named concepts express the same constraint checkably.

**Manual index loops over containers.** `for (int i = 0; i < v.size(); ++i)` mixes signed/unsigned (a real warning), and index arithmetic is where off-by-ones live. Range-for, or a named algorithm, removes the class of bug. Note `std::ssize` and `std::cmp_less` exist for when an index is genuinely needed.

**Reimplemented algorithms.** A loop that is `std::find_if`, `std::any_of`, `std::accumulate`, or `std::partition` spelled out longhand is worth naming — not for elegance, but because the named version states the intent and can't get the loop bounds wrong.

**`printf`-family formatting.** Format-string/argument mismatches are a runtime bug class that `std::format` and `std::print` (C++23) turn into compile errors.

**`reinterpret_cast` for type punning.** UB by strict aliasing. `std::bit_cast` is the correct tool and is `constexpr`.

**Manual `new`/`delete`, and manual resource pairs generally.** `unique_ptr`, `make_unique`, and scope guards; and for threads, `std::jthread`, which joins on destruction and carries a stop token instead of a hand-rolled `atomic<bool>` plus join-in-destructor.

## Facilities worth recognizing when reading C++20/23

Not things to demand — things to know so you understand the code and don't flag correct usage as suspicious:

- **Ranges and views** — lazy, composable, and non-owning. Their laziness is the thing to review (see `memory-and-lifetimes.md`); `ranges::to` (C++23) materializes.
- **Concepts** — constrain templates; the error messages are the point.
- **`std::span` / `std::string_view`** — non-owning parameter types; correct as parameters, suspect as members.
- **`std::expected` (C++23)** — error handling without exceptions. Only relevant if the project's error convention is already this shape.
- **`std::optional`** and monadic `and_then`/`transform`/`or_else` (C++23).
- **Designated initializers** — `Config{.timeout = 30}` removes positional-argument transposition.
- **`consteval`, `constinit`, expanded `constexpr`** — compile-time evaluation, and `constinit` specifically rules out the static initialization order fiasco.
- **Coroutines** — `co_await`/`co_return`; see `concurrency.md` for the lifetime traps.
- **Modules** — `import`, `export`; check exports and ODR.
- **`std::source_location`** — replaces `__FILE__`/`__LINE__` macros in logging.
- **`[[likely]]`/`[[unlikely]]`, `[[no_unique_address]]`** — the latter can change struct layout, which matters for ABI.

## Watch for half-migrations

The most useful idiom finding in practice isn't old code — it's *inconsistent* code. A file that uses concepts everywhere and `enable_if` in the function this diff adds. A class with `<=>` for three members and a hand-written `==` for the fourth. A codebase on `std::format` with a new `snprintf` call.

These are worth raising even when the old spelling works, because mixed conventions in one file are what make the next reader guess wrong.

## Availability

Before suggesting anything, confirm the project can actually use it: check the language standard in the build files, and whether the codebase targets compilers that implement the feature. Standard-library support lags the standard, particularly for `std::format`, ranges, and modules. A suggestion the project can't compile is worse than no suggestion.
