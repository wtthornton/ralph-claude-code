# Story RALPH-STREAM-3: Unescape RALPH_STATUS Before Field Extraction

**Epic:** [Stream Parser v2](epic-stream-parser-v2.md)
**Priority:** Medium
**Status:** Done
**Effort:** Small
**Component:** `templates/hooks/on-stop.sh`

---

## Problem

The `on-stop.sh` hook extracts RALPH_STATUS fields using grep:

```bash
exit_signal=$(extract_field "EXIT_SIGNAL" "false")
work_type=$(extract_field "WORK_TYPE" "UNKNOWN")
```

Where `extract_field` greps for `FIELD_NAME:` in `$INPUT` (the raw response from stdin).

When the response arrives from JSONL stream extraction (Issue #2 / STREAM-1), the text
containing the `---RALPH_STATUS---` block is JSON-escaped. Newlines are literal `\n`
characters within a JSON string value, not actual line breaks. The grep pattern `WORK_TYPE:`
fails because the entire status block is on a single escaped line.

**Observed:** Loop #6 (2026-03-21) returned `Work Type: UNKNOWN` and empty summary despite
the Claude output containing `WORK_TYPE: IMPLEMENTATION` in a well-formed status block.

## Solution

Before applying field extraction, detect and unescape JSON-encoded text in the response:

### Change 1: `on-stop.sh` — Add unescaping step

After reading `$INPUT`, check if it looks like a JSON result object and extract the text
content:

```bash
INPUT=$(cat)

# If input is a JSON result object, extract the text content and unescape
if echo "$INPUT" | jq -e '.type == "result"' >/dev/null 2>&1; then
    # Extract result text and unescape JSON string encoding
    EXTRACTED=$(echo "$INPUT" | jq -r '.result // empty' 2>/dev/null)
    if [[ -n "$EXTRACTED" ]]; then
        INPUT="$EXTRACTED"
    fi
fi
```

This converts the JSON-escaped `\n` back to actual newlines, allowing the existing grep-based
`extract_field` to work unchanged.

### Change 2: Add fallback inference

If `WORK_TYPE` is still `UNKNOWN` after extraction but `FILES_MODIFIED > 0`, infer
`IMPLEMENTATION` as a sensible default:

```bash
if [[ "$work_type" == "UNKNOWN" && "$files_modified" -gt 0 ]]; then
    work_type="IMPLEMENTATION"
fi
```

### Change 3: Debug logging

Log the first 200 chars of extracted text at DEBUG level so parsing failures can be diagnosed:

```bash
if [[ "${RALPH_VERBOSE:-false}" == "true" ]]; then
    echo "[DEBUG] Extracted text (first 200 chars): ${INPUT:0:200}" >&2
fi
```

## Acceptance Criteria

- [ ] WORK_TYPE, STATUS, recommendation correctly extracted from JSON result objects
- [ ] Existing plain-text responses still parse correctly (no regression)
- [ ] Fallback inference: UNKNOWN + files_modified > 0 → IMPLEMENTATION
- [ ] Test with both raw text and JSON-wrapped RALPH_STATUS blocks
