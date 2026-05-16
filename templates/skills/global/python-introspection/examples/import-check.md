# Example: confirm `opentelemetry.sdk` is importable in the project venv

## Loop snapshot

- Task is a tracing-instrumentation chore in `src/tapps_brain/aio.py`.
- I need to know whether `opentelemetry.sdk` is already installed
  (and what version), so the snippet I'm about to write either uses
  the existing dependency or asks for a new one.
- My instinct is `python3 -c "import opentelemetry.sdk;
  print(opentelemetry.sdk.__version__)"` — that's the friction shape
  the hook blocks. Burned tool call number 1 if I try.

## What I do instead

### Step 1 — Try Read first

```
Read pyproject.toml
```

If `opentelemetry-sdk` is pinned under `[tool.poetry.dependencies]` or
the `dependencies = [...]` list, the answer is already in front of me —
no Python execution needed. Stop here.

### Step 2 — If not pinned, file-based script

When the pin lives in a transitive lock or I really need the
**installed** version (which may differ from the pin):

```
Write tool call:
  file_path: /tmp/check_otel.py
  content:   |
    try:
        import opentelemetry.sdk
        print("ok", opentelemetry.sdk.__version__)
    except ImportError as e:
        print("missing", e)
```

```
Bash tool call:
  command: python3 /tmp/check_otel.py
```

## Output

```
ok 1.21.0
```

## Cost comparison

| Approach                                  | Tool calls | Hook outcome |
|-------------------------------------------|------------|--------------|
| `python3 -c "import opentelemetry.sdk…"`  | 1 + retry  | BLOCKED      |
| Read pyproject.toml (when sufficient)     | 1          | allow        |
| Write + Bash (`python3 /tmp/check.py`)    | 2          | allow        |

The file-based path is two tool calls instead of one, but it actually
finishes — and it's reusable next time the same question comes up.

## Why this matters at loop scale

In the 2026-05-15 → 2026-05-16 tapps-brain campaign, this exact pattern
fired on 28 of 50 loops. Each retry costs a turn against the per-loop
turn budget and an Anthropic input-token bill. Two file-based tool
calls cost less than four blocked `-c` invocations.
