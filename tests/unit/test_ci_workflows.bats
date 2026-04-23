#!/usr/bin/env bats
# TAP-666 + TAP-667: CI workflow hygiene lint.
# * TAP-666 — every workflow must set a `permissions:` block and every job
#   must set `timeout-minutes:` to cap runner waste.
# * TAP-667 — every workflow must pin `shell: bash` at workflow or step level
#   so bash-only syntax ([[ ]], local, ${var:-default}) cannot silently fail
#   under a non-bash default shell.

load '../helpers/test_helper'

PROJECT_ROOT="${BATS_TEST_DIRNAME}/../.."
WORKFLOW_DIR="$PROJECT_ROOT/.github/workflows"

# Files we hand-author and are responsible for. Auto-generated lockfiles
# (e.g. gh-aw's *.lock.yml) are skipped: those have "DO NOT EDIT" markers
# and their source-of-truth is a sibling .md file, not the yaml.
hand_authored_workflows() {
    local f
    for f in "$WORKFLOW_DIR"/*.yml; do
        [[ -f "$f" ]] || continue
        # Skip generator-owned lockfiles
        case "$(basename "$f")" in
            *.lock.yml) continue ;;
        esac
        # Skip anything carrying a "DO NOT EDIT" marker
        if head -30 "$f" | grep -q "DO NOT EDIT"; then
            continue
        fi
        echo "$f"
    done
}

# =============================================================================
# TAP-666: workflow-level permissions block
# =============================================================================

@test "TAP-666: every hand-authored workflow declares a top-level permissions: block" {
    local f missing=()
    while IFS= read -r f; do
        # Match `^permissions:` at column 0 — workflow scope, not a nested job.
        if ! grep -qE '^permissions:' "$f"; then
            missing+=("$(basename "$f")")
        fi
    done < <(hand_authored_workflows)
    if (( ${#missing[@]} > 0 )); then
        echo "Missing permissions: block in: ${missing[*]}"
        false
    fi
}

@test "TAP-666: every job declares timeout-minutes (cap runaway runs)" {
    local f
    local -a offenders=()
    while IFS= read -r f; do
        # Count job blocks (two-space indent + name-colon under `jobs:`) and
        # `timeout-minutes:` occurrences; offenders are files where the count
        # of timeout-minutes is less than the number of jobs.
        local job_count timeout_count
        job_count=$(awk '
            /^jobs:/ { in_jobs = 1; next }
            in_jobs && /^[a-zA-Z]/ { in_jobs = 0 }
            in_jobs && /^  [a-zA-Z_-]+:$/ { n++ }
            END { print n + 0 }
        ' "$f")
        timeout_count=$(grep -cE '^\s+timeout-minutes:' "$f")
        if (( job_count > 0 && timeout_count < job_count )); then
            offenders+=("$(basename "$f") [$timeout_count timeout(s) for $job_count job(s)]")
        fi
    done < <(hand_authored_workflows)
    if (( ${#offenders[@]} > 0 )); then
        echo "Jobs without timeout-minutes: ${offenders[*]}"
        false
    fi
}

# =============================================================================
# TAP-667: shell pinning
# =============================================================================

@test "TAP-667: every hand-authored workflow pins bash (defaults.run.shell or per-step)" {
    local f missing=()
    while IFS= read -r f; do
        # Accept either workflow-level `defaults: run: shell: bash` OR at least
        # one `shell: bash` anywhere (covers per-step pinning).
        if ! grep -qE '^\s*shell:\s*bash\s*$' "$f"; then
            missing+=("$(basename "$f")")
        fi
    done < <(hand_authored_workflows)
    if (( ${#missing[@]} > 0 )); then
        echo "Workflows not pinning bash: ${missing[*]}"
        false
    fi
}

# =============================================================================
# Smoke: the specific files we edited retain the expected markers
# =============================================================================

@test "TAP-666/667: test.yml has permissions, defaults.bash, and timeout-minutes on both jobs" {
    local f="$WORKFLOW_DIR/test.yml"
    grep -qE '^permissions:' "$f"
    grep -qE '^defaults:' "$f"
    grep -qE 'shell:\s*bash' "$f"
    # Both jobs present: `test:` and `coverage:` — each must have a timeout-minutes.
    local timeouts
    timeouts=$(grep -cE '^\s+timeout-minutes:' "$f")
    [[ "$timeouts" -ge 2 ]]
}

@test "TAP-666/667: update-badges.yml has defaults.bash and a top-level permissions block" {
    local f="$WORKFLOW_DIR/update-badges.yml"
    grep -qE '^permissions:' "$f"
    grep -qE '^defaults:' "$f"
    grep -qE 'shell:\s*bash' "$f"
    grep -qE '^\s+timeout-minutes:' "$f"
}

@test "TAP-667: codeql-analysis.yml pins bash" {
    local f="$WORKFLOW_DIR/codeql-analysis.yml"
    grep -qE 'shell:\s*bash' "$f"
}
