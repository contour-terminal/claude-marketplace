# Memory safety, lifetimes, and UB

The unifying question: for every reference-like thing here, does the referent outlive it?

## Dangling: the common shapes

**Returning a reference to a temporary or local.** Includes the subtle version: returning `string_view` or `span` built from a local, or from a by-value parameter.

```cpp
std::string_view name() const { return std::string(name_) ; }  // dangles immediately
std::string_view trim(std::string s);                          // returns view into a dead argument
```

**Reference-to-temporary in a range-for.** Fixed for the common case in C++23 via P2718R0, but only when the compiler implements it and the codebase is actually building as C++23. Worth flagging otherwise:

```cpp
for (auto& x : make_vector().subrange()) { ... }  // pre-C++23: temporary dies before the loop
```

**Captured references in lambdas that outlive the frame.** `[&]` on a lambda that is stored, posted to a thread pool, or attached to a coroutine is the single most reliable source of use-after-free in modern C++. `[&]` is fine for `std::sort` predicates and immediately-invoked lambdas; it is suspect the moment the lambda is stored anywhere.

**Iterator and reference invalidation.** `push_back` / `insert` / `erase` on a `vector` invalidates; `unordered_map` rehash invalidates iterators but not references; `erase` in a loop without using the returned iterator is a classic. Check any loop that mutates the container it's iterating.

**`std::string_view` from a `std::string` temporary.** `sv = returns_string()` — extremely common, silently broken.

## Ownership

- Raw owning pointers with manual `delete`: flag unless the codebase has a documented reason. `unique_ptr` costs nothing.
- `shared_ptr` cycles — parent holds child, child holds parent. The child's back-pointer should be `weak_ptr` or a raw non-owning pointer.
- `shared_ptr` passed by value everywhere in a call chain: each copy is an atomic refcount bump. Pass `const T&` or a raw pointer when the callee doesn't extend lifetime.
- `enable_shared_from_this` called from a constructor, or on an object not owned by a `shared_ptr` — UB.
- Missing virtual destructor when deleting through a base pointer.
- Special member functions: if the class manages a resource and declares any of destructor / copy ctor / copy assign, check that the rest are declared or deleted (rule of five). An implicitly generated copy of a resource-owning class is a double-free waiting to happen.

## Error and exception paths

The happy path usually gets tested; the error path usually doesn't get read.

- Early `return` between an acquire and a release. Anything acquired manually should be in a scope guard or RAII wrapper.
- An exception thrown mid-way through a function that has already mutated shared state — does the object stay in a valid state? Check whether the class claims a strong exception guarantee it doesn't provide.
- `noexcept` on a function that can actually throw: this is a `std::terminate`, not a compile error.
- Move constructors that aren't `noexcept`: `vector` reallocation falls back to copying, silently.
- Moved-from objects used afterward. Valid-but-unspecified is not "unchanged" — check for reads after a move, especially in loops where a variable is moved on iteration 1 and read on iteration 2.

## UB worth checking explicitly

- Signed integer overflow, including in index arithmetic. `int` loop counters over container sizes.
- Mixed signed/unsigned comparison — `i < v.size()` with `int i`. C++20 gives `std::ssize` and `std::cmp_less`; prefer them where the codebase allows.
- Out-of-bounds: `operator[]` where the index is derived from input. `.at()` or an explicit check.
- Uninitialized members. Check every constructor initializes every member, including the ones added by this change to an existing class — adding a member and forgetting one of three constructors is a common diff-shaped bug.

  Before reporting one, establish *how the object's storage is obtained*. Plain `new T`, a stack object, and `malloc` leave members indeterminate; a custom allocator, arena, or pool very often zeroes on allocation, and `new T()` (with parentheses) value-initializes. A codebase that allocates through its own arena may deliberately rely on the zeroing and omit the initializer everywhere — in which case "this member is uninitialized" is not a finding, it is the house convention, and asserting otherwise burns credibility on a file the maintainers know better than you do. Find the allocation site, or ask rather than assert.
- Strict aliasing violations via `reinterpret_cast` between unrelated types. C++20 `std::bit_cast` is the right tool.
- **A null check added to a parameter the compiler has been told is never null.** `__attribute__((nonnull))` — and its wrappers, `JSON_HEDLEY_NON_NULL`, `GSL_SUPPRESS`, `absl_nonnull`, MSVC's `_In_` SAL annotations — are promises, not checks. GCC and Clang use them to *delete* comparisons of the parameter against null as provably-false dead code, and to warn (`-Wtautological-pointer-compare`, `-Wnonnull-compare`) at the site. So a diff that adds `if (p == nullptr)` to a function whose parameter carries such an annotation has added a check that may not survive optimization, in exactly the builds where it matters.

  Whenever a change adds a null guard, look at the parameter's declaration *and* its annotations before judging the guard. The fix is to decide which contract is true — if null is now a supported, diagnosed input, the annotation must go; if it remains a precondition, an assert is the honest tool and the guard is misleading. Sanitizers make the contradiction visible (UBSan's `nonnull-attribute` fires on the call, not the check), so "does UBSan pass on a test that passes null?" is the question that settles it.
- Dereferencing the result of `std::optional::operator*` or `value_or` misuse without checking.
- `const_cast` followed by mutation of an originally-const object.

## C++20/23-specific hazards

- **Ranges views are lazy and non-owning.** A view stored in a member, or returned from a function, that refers to a container which has since been modified or destroyed. `views::filter` over a temporary container is the frequent case. C++23's `ranges::to` and owning-view rules help; check whether the code relies on them.
- **`std::span` parameters** don't own — same lifetime questions as `string_view`.
- **Coroutines**: parameters are copied into the frame, but *references* are not extended. A coroutine taking `const std::string&` and suspending is a dangling reference after the caller returns. Similarly, a lambda coroutine's captures die when the lambda does.
- **`std::jthread`** joins on destruction, which is usually what you want — but check the stop token is actually honored, otherwise the destructor blocks forever.
- **Modules**: check that anything intended to be part of the interface is actually exported, and that ODR isn't being violated by mixed module/header inclusion of the same entity.
