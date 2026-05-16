---
name: python-introspection
description: >
  Read-only Python (and sibling-interpreter) introspection without
  hitting the validate-command.sh `-c | -e` block. Use whenever you
  want to check an import, parse an AST, print a module version, or
  evaluate a tiny snippet — write the snippet to /tmp/snippet.py and
  run `python3 /tmp/snippet.py`. Or, for plain "does symbol X live in
  module Y" questions, prefer Read or Grep over a script entirely.
version: 1.0.0
ralph: true
ralph_version_min: "2.15.0"
user-invocable: false
disable-model-invocation: false
allowed-tools:
  - Read
  - Write
  - Grep
  - Glob
  - Bash
---

# python-introspection — file-based scripts, not `-c`

The validate-command.sh hook blocks `python -c`, `python3 -c`, `node -e`,
`perl -e`, `ruby -e`, `bash -c`, and `sh -c` because `-c` / `-e` is the
standard escape hatch for arbitrary script-execution-as-a-bash-argument.
File-based execution stays allowed: write the snippet to `/tmp/` and run
the file. The denial message itself names the workaround, but every loop
that retries the blocked shape burns a tool call — this skill is the
prevention.

## When to reach for this skill

You reach for `python -c` instinctively when you want to:

- Confirm an import path is real (`import opentelemetry.sdk; print("ok")`).
- Check a module's version (`import requests; print(requests.__version__)`).
- Parse a file's AST to spot a syntax error (`ast.parse(open(p).read())`).
- Evaluate a one-line expression against a small fixture.

All of those work fine as file-based scripts — and the most common ones
(import / version / "does symbol X exist") often don't need a script
at all.

## Decision ladder

Walk these in order. Stop at the first one that answers your question.

### 1. Can a Read or Grep answer it directly?

If the question is "is `foo.bar.baz` defined" or "what version does
`pyproject.toml` pin," skip the interpreter entirely:

- **Existence**: `Grep -nE '^(def|class) baz\b' foo/bar.py`
- **Pinned version**: `Read pyproject.toml` and look at the
  `[tool.poetry.dependencies]` / `dependencies = [...]` block.
- **Installed version**: `Read .venv/lib/python*/site-packages/<pkg>/_version.py`
  or look at the dist-info METADATA file.

You don't need a Python interpreter to grep Python source.

### 2. Need to actually execute Python? Write a file.

Use the Write tool to put the snippet under `/tmp/`:

```
Write tool call:
  file_path: /tmp/check_otel.py
  content:   |
    import opentelemetry.sdk
    print("opentelemetry.sdk version:", opentelemetry.sdk.__version__)
```

Then run it:

```
Bash tool call:
  command: python3 /tmp/check_otel.py
```

Two tool calls, total. Replays cleanly. Survives a permission re-prompt
because `python3 <path>` is allow-listed; `python3 -c …` is not.

### 3. Need this repeatedly? Stash it in the project tree, gitignored.

For repeated introspection scripts (a one-off audit that you'll run
across multiple modules), prefer a project-local path like
`scripts/dev/check_imports.py` so it survives `/tmp` cleanup. Add the
path to `.gitignore` if it's truly ad-hoc.

## Anti-patterns

- **Re-trying `python3 -c "…"` after the first denial.** The hook is not
  going to relent; you're burning a tool call per loop.
- **Inlining a 30-line script via heredoc into `bash -c`.** Same block,
  same waste. Write the file once and run it.
- **Wrapping `python3 -c` in `env`, `sudo`, or `bash -lc`.** The hook
  normalizes leading wrappers — the `-c` flag is what matters.
- **Reaching for Python when grep + Read would do.** Don't open a
  shell-out where a file read answers the question.

## What this skill is NOT

This skill does not change the security posture. `-c` / `-e` stays
blocked — that's intentional. The hook's denial message already names
the file-based remediation; this skill exists for the moment-of-action
where you'd otherwise default to the blocked shape out of habit.
