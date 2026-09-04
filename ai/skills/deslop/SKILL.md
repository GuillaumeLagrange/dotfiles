---
name: deslop
description: >-
  Remove AI-generated slop from the comments and docs a change introduces (task/PR
  narration, comments restating the code, references to things the reader cannot
  see), and flag low-value tests it adds. Operates on the current diff only. Use
  when the user asks to "deslop", "remove AI slop", or clean up comments before a
  PR.
---

Remove AI Slop from the comments/docs this PR adds.

AI Coding tools love to add comments everywhere that don't belong to production code.

- comments that mentions uncommited files or private dev-specific content that the team cannot access.
- narration of the current task/PR/ticket that has nothing to do in production code. During implementation of a ticket, a "V1" can be cristal clear to the developer, but the reviewer or future reader of that code will have no clue what it means.
- comments that restate the code
- Explains by comparison to something the reader can't see ("unlike the other X", "same mechanism as Y"). Say the thing directly.
- Write each comment for a reader who sees only the current code, with no memory of how it got there. If understanding it needs the diff, the ticket, or a past version, it's slop, describe what is in front of the reader now. Rare exception: when the history genuinely changes how you'd treat the code (a non-obvious constraint, a past incident, a reverted approach), keep it but anchor it to a durable reference (ticket ID, PR, or permalink) so the reader can go get that context. If you can't point to one, the history isn't worth a comment.

Remove them, or simplify them like crazy.

Keep only non-obvious why, invariants, gotchas, units/edge cases. When unsure, delete rather than reword. Make the edits and list what you cut, one line each.

It doesn't mean you need to delete documentation. Documentation is different than comments !

It doesn't mean you should blindly shorten/compact comments. Simplifying doesn't equals to compacting. Often, compacting comments creates absolutely unreadable and very hard to understand comments for other readers. Keep comments easy to understand !

**Tests:**

When this skill is invoked, also check the tests the change adds. Coding agents love adding tests to look thorough. The bad ones only pad coverage, break on a refactor that doesn't change behavior (a good test breaks when behavior changes, not when the implementation moves), lean on a pile of mocks, or assert implementation details instead of the observable result.

Mocking a real external boundary (network, a third-party SDK, the clock, secrets) is fine; mocking your own code to assert how it was called pins the test to the implementation. When code is hard to test, prefer going a level higher (an integration test over heavy unit mocks) rather than testing untestable code, and leave real refactors for a separate PR.

Only judge tests this change adds. When a weak test still covers behavior that matters, warn the developer instead of silently deleting it.
