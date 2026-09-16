---
name: python
description: >
  There is no system `python`/`python3` on these machines. Run Python through
  `uv run` instead of falling back to another language.
alwaysApply: true
---

# Python

No `python` or `python3` exists on PATH here, by design. `python3 -c ...` fails with
"command not found"; that is not a reason to rewrite the work in JavaScript.

- Run scripts and one-liners with `uv run --no-project python ...`. `--no-project`
  keeps the ambient project's environment (and its lockfile) out of the way for
  throwaway work; drop it when the script belongs to the project you are in.
- Third-party packages need no venv setup: `uv run --no-project --with pillow python ...`
  resolves and caches them per invocation.
- Pin an interpreter with `--python 3.13` when a version actually matters.
- The Eval tool's `py` kernel is unavailable for the same reason, so reach for
  `bash` + `uv run` when the task genuinely wants Python (numerics, PIL, stdlib
  parsers). Choose JavaScript because it fits the task, never as a fallback.
