# Architecture and structure

Most architectural judgment cannot be made from a diff. Whether a design is right depends on where the codebase is heading, what was tried before, and which constraints are load-bearing — none of which is visible in a patch. Reviews that pronounce on architecture from a diff alone produce grand, unactionable comments that authors correctly ignore.

So the discipline is: raise structural problems that are **visible in the change itself**, and raise everything larger as a question rather than a redesign.

## What a diff does show

**Dependency direction.** A new `#include` or a new call that makes a lower layer depend on a higher one. Check where the new edge points: does a core type now know about UI, does a generic algorithm now include a target-specific header, does a data model now reach into the service that stores it? These are visible and concrete.

**A class acquiring a second responsibility.** A change that adds a member and three methods unrelated to the class's existing job. The clue is usually the constructor or the member list growing in a direction the class name doesn't cover.

**Abstractions leaking.** An interface that now exposes a type from its implementation — a container's iterator, a database handle, a platform type in a portable header. Once that's in the signature, callers depend on it and it can't be removed.

**Logic duplicated rather than shared.** The same validation, the same conversion, the same special case appearing in a second place. Two copies is the moment to ask, because it's cheap now and expensive after the third.

**Feature-envy call chains.** `a.GetB().GetC().DoThing()` reaching through layers. Each added link is a coupling the middle types can't change without breaking this caller.

**Header weight.** A heavy include added to a widely-included header, or a definition put in a header that forces recompilation of everything on change. Nobody notices this in review and everybody pays for it.

**Placement.** Is the new code where a maintainer would look for it? Validation in a generator versus in the option-parsing layer; a helper in the file that uses it versus the shared utility header. Placement decisions are hard to reverse once callers accumulate.

## What a diff does not show

Whether the abstraction is the right one, whether the module boundary is in the right place, whether this pattern will still hold at ten times the scale. Reviewers with deep project history make these calls and are often right — but they're drawing on knowledge of what rotted last time, which isn't recoverable from the patch.

When something looks structurally wrong at that level, say what you observe and ask, rather than proposing a redesign:

> This adds the third place that maps option names to generators. Is there a reason these stay separate, or should they share a table?

That's answerable in one sentence and costs the author nothing if the answer is "yes, deliberately." Compare with proposing an extraction of a registry class, which requires them to argue against a design rather than explain one.

## Don't endorse the structure either

The rule cuts both ways, and the endorsing direction is easier to miss because it feels generous rather than presumptuous. "Threading this through the existing interface keeps the layering intact", "good separation of concerns here", "this is in the right place" are architectural verdicts, and they rest on exactly the project history a diff doesn't carry.

The specific way this goes wrong: a change follows the layering that is *visible in the patch*, so it looks clean — while the maintainers know that layer is the one they are trying to collapse, or that the same data now has two representations for a reason nobody outside the project can see, or that the boundary the change respects is the boundary they've decided was a mistake. A review that praises the structure in that situation isn't neutral; it argues, with false confidence, against the people who have the context.

So when you want to compliment the shape of a change, either tie the praise to something locally checkable — "the new edge points downward, from UI to core, not the reverse" — or say nothing about structure at all. Noting what a change does well is worth doing (see `SKILL.md`), but pick something the diff actually demonstrates: a test that pins the tricky case, an error path that's handled, a name that clarifies. Those don't require knowing where the codebase is heading.

If two spellings of the same concept appear in one diff — the same data as a `vector` in one class and a `map` in another, the same setting read from two places — that is observable and worth **asking** about. It is not evidence of a mistake; it is frequently deliberate, and the reason is usually invisible (a shared component, an ABI constraint, a platform split). Ask which representation is canonical and why both exist. Don't assert that one is wrong, and don't assume it won't compile.

## Proportionality

Scale the structural comment to the change. A 20-line bug fix does not need a design discussion — if the fix reveals a structural problem, name it in one sentence and let the author decide whether to file it. A new subsystem or a new public interface deserves real scrutiny of its shape, because that's the moment when changing it is still cheap.

The test for whether a structural comment is worth making: could the author act on it inside this PR, or does it describe work they'd have to schedule? If it's the latter, it belongs as a question or a note, never as a blocker.
