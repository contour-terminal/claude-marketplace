# Concurrency and data races

Races don't show up in the diff — they show up in the gap between what the diff assumes about threading and what's actually true. So the first question is always: **which threads reach this code?**

Answer it from evidence, not assumption. Look for thread creation, thread pools, `PostTask`/`Dispatcher`/`co_await` boundaries, callback registration, and comments claiming a threading model. UI frameworks (WinRT, Qt, Cocoa) have affinity rules where touching an object off the UI thread is a bug even without a data race.

## Reviewing state that crosses threads

For each piece of shared mutable state touched by the change:

- What lock protects it, and is that lock held on *every* path that touches it? A new early-return or a new helper function is the usual way a path escapes the lock.
- Is the lock held for the whole invariant, or just the individual accesses? Two correctly-locked reads with a gap between them is a TOCTOU race:

```cpp
if (!map_.contains(k)) {   // lock taken and released
    map_.emplace(k, v);    // lock taken again — another thread may have inserted
}
```

- Does the change widen the critical section to include something that can block, allocate, call user code, or acquire another lock? Calling a callback while holding a lock is how deadlocks and reentrancy bugs are born.
- Lock ordering: if the change introduces a second lock, is there a path that takes them in the opposite order elsewhere? Grep for the other lock.

## Specific things to check

- `const` member functions are *not* thread-safe by default, but callers assume they are. A `const` method with a `mutable` cache member needs synchronization.
- Reference counts are atomic; the pointed-to object is not. `shared_ptr` copies are thread-safe, but two threads writing `*ptr` is a race. Reassigning the *same* `shared_ptr` object from two threads is also a race unless you use the atomic overloads or `atomic<shared_ptr<T>>` (C++20).
- Double-checked locking done by hand is almost always wrong. Function-local `static` initialization is already thread-safe — prefer it.
- `std::atomic` with relaxed or acquire/release ordering: check the ordering actually establishes the happens-before the code depends on. If the change relaxes a `seq_cst` to something weaker, that needs a justification in a comment; if it's an "optimization" with no reasoning, ask.
- `volatile` used for synchronization — it doesn't do that. Flag it.
- Condition variables: waiting without a predicate (spurious wakeups), or notifying without holding the lock when the waiter checks state under it.
- Check-then-act on a `weak_ptr`: `if (!wp.expired()) wp.lock()->f();` races. Lock once, then test.

## Async, callbacks, and coroutines

This is where lifetime and threading intersect, and it's the most common source of real bugs in modern codebases.

- A callback capturing `this` and posted to another thread or a timer: what guarantees the object is still alive when it fires? The usual correct patterns are capturing a `shared_ptr`, capturing a `weak_ptr` and locking inside, or a cancellation/revoker mechanism that's guaranteed to run before destruction. If the change adds an async call and none of these are present, that's a finding.
- Destructors that need to wait for in-flight work: does the destructor actually block until outstanding callbacks complete, and can that deadlock if a callback is running on the thread doing the destroying?
- Coroutines: after `co_await`, you may be on a different thread. Anything cached in a local across the suspension point — a pointer, an iterator, a lock guard — needs re-examination. Holding a `std::lock_guard` across `co_await` is a bug (the unlock may happen on a different thread than the lock, and other coroutines can interleave).
- Fire-and-forget async that outlives its owner — check whether the result is discarded and whether anyone can cancel it.

## Reentrancy

Ask whether the code can be re-entered on the *same* thread: an event handler that triggers an event, a callback that mutates the container being iterated by its caller, a destructor that runs user code. Reentrancy produces bugs that look exactly like races but reproduce single-threaded.
