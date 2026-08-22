# Plan approval and phase gates

Shared policy for skills that implement a change in stages rather than one pass — `/work-issue`
reads it today. It defines what a plan must contain and how a phase is closed, so the two cannot
drift apart: the gate only works because the plan defined the phases it gates.

This is a reference document, not a skill. It has no frontmatter and is never invoked directly.

Two mechanisms. The skill that reads this file cites the two sections below by heading rather than
restating them.

## The plan

Before touching a single file, enter plan mode, write the plan, and get it approved via
`ExitPlanMode`. Approval is what separates "this is what I intend to do" from "this is what I did";
asking afterwards is asking the user to review a fait accompli.

A plan says what will change, why that shape, and — the part the gates depend on — how the work
**decomposes into phases**. A phase is a slice that stands on its own: it builds, its tests pass,
and it leaves the tree in a state you would show someone. "Add the parser", "wire it into the
config loader", "handle the error path" are phases; "write the code" is not.

Plans are proportionate: a one-hunk chore is a one-sentence, one-phase plan. Do not manufacture
phases to have something to gate.

## The phase gate

**Record the branch tip before starting a phase** — `git rev-parse HEAD`, the *phase base*. One
command, and it is what lets the gate review this phase rather than everything accumulated so far.
Then close every phase the same way, before starting the next:

1. **Tests green.** The phase's own tests pass and the full suite still passes. This comes first
   because everything after it edits code, and edits on top of a red tree cannot be judged.
2. **`/simplify`.** It reviews changed code for reuse, duplication and altitude and *applies* its
   fixes rather than reporting them, so re-run the suite afterwards. It takes no range and scopes
   itself, which is fine — its fixes are improvements wherever it finds them. It does not hunt
   bugs; that is step 4's job.
3. **Commit the phase**, with `-s` and a message describing what it did; adjacent fixes go in their
   own commits, per the policy. This is what gives step 4 a range to name and an adjacent fix
   somewhere to land. If this is the phase that delivers the thing the work was
   commissioned for, put any issue-closing trailer on **now**, in the shape the calling skill
   specifies. Adding it later means rewording a commit that is
   no longer the tip — recoverable with an `amend!` fixup and an autosquash, but fiddly enough
   that the calling skill should document the recipe rather than leave it to be improvised.
4. **`/code-review <level> <phase-base>..HEAD`** — `medium` for a phase of a multi-phase plan,
   and the calling skill's final-pass level when the plan turned out to be a single phase, so that
   the shortcut below is actually reachable. Name both. Without the level it reuses whichever
   ran last, and a gate whose depth depends on unrelated history is not a gate; without the range
   it resolves its own target from the branch, re-reviewing phase one once per phase.
5. **Address every finding**, folding fixes into the phase's commits — `/absorb` puts each one on
   the commit that introduced the line it touches — then **re-run the suite**. `/absorb` rebases,
   which gives every commit on the branch a new SHA: if you review again inside this phase,
   re-record the phase base first, or the old one is orphaned and the range silently widens to
   almost the whole branch. This step edits
   code, and `/absorb` rebases; closing a phase on an unverified tree is what step 1 exists to
   prevent, and the next phase would be built on top of it. Findings about code this change did not touch
   are *adjacent*: route them through `lib/adjacent-problems.md` rather than absorbing them
   silently or ignoring them. A finding deliberately declined is recorded, not dropped.

**When the plan is a single phase**, the phase gate and the calling skill's final whole-branch
review cover the same code. Run the gate once, at the deeper level, and skip the duplicate — reviewing a two-line diff
twice is ceremony, not rigour.
