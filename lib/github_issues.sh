#!/bin/bash

# lib/github_issues.sh — GitHub Issue Integration (Phase 10, RALPH-GHISSUE)
#
# GHISSUE-1: Plan import from GitHub issue
# GHISSUE-2: Issue completeness assessment
# GHISSUE-3: Issue filtering
# GHISSUE-4: Batch processing
# GHISSUE-5: Lifecycle management
#
# Uses `gh` CLI (preferred) or GitHub API with GITHUB_TOKEN fallback.

# Configuration
RALPH_AUTO_CLOSE_ISSUES="${RALPH_AUTO_CLOSE_ISSUES:-false}"
GITHUB_TASK_LABEL="${GITHUB_TASK_LABEL:-ralph-task}"

# =============================================================================
# GHISSUE-1: Import single GitHub issue into fix_plan.md
# =============================================================================

# ralph_import_issue — Import a GitHub issue into .ralph/fix_plan.md
#
# Usage: ralph_import_issue ISSUE_NUMBER
#
ralph_import_issue() {
    local issue_num="$1"
    local ralph_dir="${RALPH_DIR:-.ralph}"

    if [[ -z "$issue_num" ]]; then
        echo "Error: Issue number required"
        echo "Usage: ralph --issue NUM"
        return 1
    fi

    # Detect repo from git remote
    local repo
    repo=$(_gh_detect_repo)
    if [[ -z "$repo" ]]; then
        echo "Error: Could not detect GitHub repository from git remote"
        return 1
    fi

    # Fetch issue
    local issue_json
    issue_json=$(_gh_fetch_issue "$repo" "$issue_num")
    if [[ -z "$issue_json" || "$issue_json" == "null" ]]; then
        echo "Error: Could not fetch issue #$issue_num from $repo"
        return 1
    fi

    local title body state
    title=$(echo "$issue_json" | jq -r '.title // ""')
    body=$(echo "$issue_json" | jq -r '.body // ""')
    state=$(echo "$issue_json" | jq -r '.state // "open"')

    if [[ "$state" == "closed" ]]; then
        echo "Warning: Issue #$issue_num is closed"
    fi

    echo "Importing issue #$issue_num: $title"

    # Store issue metadata
    cat > "$ralph_dir/.github_issue.json" << ISSUEEOF
{
    "number": $issue_num,
    "title": $(echo "$title" | jq -Rs .),
    "state": "$state",
    "repo": "$repo",
    "imported_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
}
ISSUEEOF

    # Check if body has checkboxes (markdown task list)
    if echo "$body" | grep -qE '^\s*-\s*\[[ x]\]'; then
        # Use checkboxes directly as fix_plan
        echo "# Fix Plan — Issue #$issue_num: $title" > "$ralph_dir/fix_plan.md"
        echo "" >> "$ralph_dir/fix_plan.md"
        echo "$body" | grep -E '^\s*-\s*\[[ x]\]' >> "$ralph_dir/fix_plan.md"
        echo ""
        echo "Imported $(echo "$body" | grep -cE '^\s*-\s*\[[ x]\]') tasks from issue checkboxes"
    else
        # Generate fix_plan from issue description using Claude
        _gh_generate_fix_plan "$ralph_dir" "$issue_num" "$title" "$body"
    fi

    # Update PROMPT.md with issue context
    if [[ -f "$ralph_dir/PROMPT.md" ]]; then
        # Prepend issue context
        local existing_prompt
        existing_prompt=$(cat "$ralph_dir/PROMPT.md")
        cat > "$ralph_dir/PROMPT.md" << PROMPTEOF
# GitHub Issue #$issue_num: $title

You are working on the following GitHub issue:
- Repository: $repo
- Issue: #$issue_num — $title
- State: $state

## Issue Description

$body

---

$existing_prompt
PROMPTEOF
    fi

    echo "Issue #$issue_num imported successfully"

    # Assessment (if requested)
    if [[ "${RALPH_ASSESS_ONLY:-false}" == "true" ]]; then
        ralph_assess_issue "$issue_num" "$title" "$body"
    fi

    return 0
}

# =============================================================================
# GHISSUE-2: Issue completeness assessment
# =============================================================================

# ralph_assess_issue — Assess issue on 4 dimensions
#
# Dimensions: problem clarity, repro steps, expected behavior, scope
# Score 1-5 for each.
#
ralph_assess_issue() {
    local issue_num="$1"
    local title="$2"
    local body="$3"
    local ralph_dir="${RALPH_DIR:-.ralph}"

    echo ""
    echo "Issue Assessment — #$issue_num: $title"
    echo "============================================"

    # Simple heuristic assessment (no API call needed)
    local problem_score=3
    local repro_score=2
    local expected_score=2
    local scope_score=3

    # Problem clarity: check for clear description
    [[ ${#body} -gt 200 ]] && problem_score=4
    [[ ${#body} -gt 500 ]] && problem_score=5
    [[ ${#body} -lt 50 ]] && problem_score=1

    # Repro steps: check for numbered lists or "steps to reproduce"
    if echo "$body" | grep -qiE '(steps to reproduce|how to reproduce|reproduction|to reproduce)'; then
        repro_score=4
    fi
    if echo "$body" | grep -qE '^\s*[0-9]+\.'; then
        repro_score=$((repro_score + 1))
        [[ $repro_score -gt 5 ]] && repro_score=5
    fi

    # Expected behavior: check for "expected" keyword
    if echo "$body" | grep -qiE '(expected|should|want|need)'; then
        expected_score=3
    fi
    if echo "$body" | grep -qiE '(expected behavior|expected result|should work)'; then
        expected_score=4
    fi

    # Scope: check for checkboxes or bounded scope
    if echo "$body" | grep -qE '^\s*-\s*\['; then
        scope_score=4
    fi
    if echo "$body" | grep -qiE '(out of scope|scope|not included|limited to)'; then
        scope_score=5
    fi

    local total=$(( (problem_score + repro_score + expected_score + scope_score) ))
    local avg=$(( total / 4 ))

    echo "  Problem clarity:    $problem_score/5"
    echo "  Repro steps:        $repro_score/5"
    echo "  Expected behavior:  $expected_score/5"
    echo "  Scope definition:   $scope_score/5"
    echo "  ---"
    echo "  Overall:            $avg/5"
    echo ""

    if [[ $avg -ge 3 ]]; then
        echo "Assessment: SUFFICIENT — generating plan directly"
    else
        echo "Assessment: NEEDS CLARIFICATION — plan generated with assumptions"
    fi

    # Save assessment
    cat > "$ralph_dir/.github_issue_assessment.json" << ASSESSEOF
{
    "issue_number": $issue_num,
    "assessed_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "scores": {
        "problem_clarity": $problem_score,
        "repro_steps": $repro_score,
        "expected_behavior": $expected_score,
        "scope_definition": $scope_score
    },
    "overall": $avg,
    "sufficient": $([ $avg -ge 3 ] && echo "true" || echo "false")
}
ASSESSEOF

    return 0
}

# =============================================================================
# GHISSUE-3: Issue filtering and listing
# =============================================================================

# ralph_list_issues — List open GitHub issues
#
# Usage: ralph --issues [--issue-label LABEL] [--issue-assignee USER]
#
ralph_list_issues() {
    local repo
    repo=$(_gh_detect_repo)
    if [[ -z "$repo" ]]; then
        echo "Error: Could not detect GitHub repository"
        return 1
    fi

    local gh_args=("issue" "list" "--repo" "$repo" "--state" "open" "--limit" "20")

    # Apply filters
    [[ -n "${RALPH_ISSUE_LABEL:-}" ]] && gh_args+=("--label" "$RALPH_ISSUE_LABEL")
    [[ -n "${RALPH_ISSUE_ASSIGNEE:-}" ]] && gh_args+=("--assignee" "$RALPH_ISSUE_ASSIGNEE")

    if command -v gh &>/dev/null; then
        if [[ "${RALPH_ISSUES_JSON:-false}" == "true" ]]; then
            gh "${gh_args[@]}" --json number,title,labels,assignees,state
        else
            gh "${gh_args[@]}"
        fi
    elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
        _gh_api_list_issues "$repo"
    else
        echo "Error: gh CLI or GITHUB_TOKEN required for GitHub integration"
        echo "Install: https://cli.github.com/"
        return 1
    fi
}

# =============================================================================
# GHISSUE-4: Batch processing
# =============================================================================

# ralph_batch_process — Process multiple issues sequentially
#
# Usage: ralph --batch --issue-label bug
#        ralph --batch --batch-issues 42,43,44
#
ralph_batch_process() {
    local ralph_dir="${RALPH_DIR:-.ralph}"
    local issues=()
    local stop_on_failure="${RALPH_STOP_ON_FAILURE:-false}"

    if [[ -n "${RALPH_BATCH_ISSUES:-}" ]]; then
        # Explicit issue list
        IFS=',' read -ra issues <<< "$RALPH_BATCH_ISSUES"
    elif [[ -n "${RALPH_ISSUE_LABEL:-}" ]]; then
        # Fetch from label
        local repo
        repo=$(_gh_detect_repo)
        if [[ -z "$repo" ]]; then
            echo "Error: Could not detect repository"
            return 1
        fi
        if command -v gh &>/dev/null; then
            mapfile -t issues < <(gh issue list --repo "$repo" --label "$RALPH_ISSUE_LABEL" --state open --limit 20 --json number -q '.[].number')
        else
            echo "Error: gh CLI required for label-based batch processing"
            return 1
        fi
    else
        echo "Error: Specify --batch-issues or --issue-label for batch processing"
        return 1
    fi

    local total=${#issues[@]}
    if [[ $total -eq 0 ]]; then
        echo "No issues found for batch processing"
        return 0
    fi

    echo "Batch processing $total issues..."
    echo ""

    local results=()
    local success=0
    local failed=0

    for i in "${!issues[@]}"; do
        local issue_num="${issues[$i]}"
        local progress="($((i + 1))/$total)"
        echo "=== $progress Processing issue #$issue_num ==="

        # Import and run
        if ralph_import_issue "$issue_num"; then
            results+=("{\"issue\": $issue_num, \"status\": \"imported\"}")
            ((success++))
        else
            results+=("{\"issue\": $issue_num, \"status\": \"failed\"}")
            ((failed++))
            if [[ "$stop_on_failure" == "true" ]]; then
                echo "Stopping on failure (--stop-on-failure)"
                break
            fi
        fi

        echo ""
    done

    # Write batch results
    local results_json
    results_json=$(printf '%s\n' "${results[@]}" | jq -s '.')
    cat > "$ralph_dir/batch_results.json" << BATCHEOF
{
    "completed_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "total": $total,
    "success": $success,
    "failed": $failed,
    "results": $results_json
}
BATCHEOF

    echo "Batch complete: $success/$total succeeded, $failed failed"
    echo "Results: $ralph_dir/batch_results.json"

    [[ $failed -eq 0 ]]
}

# =============================================================================
# GHISSUE-5: Issue lifecycle management
# =============================================================================

# ralph_complete_issue — Post completion comment and manage labels
#
# Called when EXIT_SIGNAL detected and .github_issue.json exists.
#
ralph_complete_issue() {
    local ralph_dir="${RALPH_DIR:-.ralph}"
    local issue_file="$ralph_dir/.github_issue.json"

    if [[ ! -f "$issue_file" ]]; then
        return 0  # No issue context, nothing to do
    fi

    local issue_num repo
    issue_num=$(jq -r '.number // empty' "$issue_file" 2>/dev/null)
    repo=$(jq -r '.repo // empty' "$issue_file" 2>/dev/null)

    if [[ -z "$issue_num" || -z "$repo" ]]; then
        return 0
    fi

    local status_file="$ralph_dir/status.json"
    local exit_signal=false
    local progress_summary=""
    local error=""

    if [[ -f "$status_file" ]]; then
        exit_signal=$(jq -r '.EXIT_SIGNAL // false' "$status_file" 2>/dev/null)
        progress_summary=$(jq -r '.PROGRESS_SUMMARY // ""' "$status_file" 2>/dev/null)
        error=$(jq -r '.error // ""' "$status_file" 2>/dev/null)
    fi

    if ! command -v gh &>/dev/null; then
        return 0  # gh CLI required for lifecycle management
    fi

    local commit_sha
    commit_sha=$(git rev-parse HEAD 2>/dev/null || echo "unknown")

    if [[ "$exit_signal" == "true" ]]; then
        # Success: post completion comment
        local comment="## Ralph Completed\n\n"
        comment+="**Progress:** $progress_summary\n"
        comment+="**Commit:** \`$commit_sha\`\n"
        comment+="**Timestamp:** $(date -u '+%Y-%m-%d %H:%M UTC')\n"

        gh issue comment "$issue_num" --repo "$repo" --body "$(echo -e "$comment")" 2>/dev/null || true

        # Add success label
        gh issue edit "$issue_num" --repo "$repo" --add-label "agent:completed" 2>/dev/null || true

        # Close issue if configured
        if [[ "${RALPH_AUTO_CLOSE_ISSUES}" == "true" ]]; then
            gh issue close "$issue_num" --repo "$repo" 2>/dev/null || true
        fi
    else
        # Failure: add failure label
        local reason="${error:-Unknown error}"
        gh issue edit "$issue_num" --repo "$repo" --add-label "agent:failed" 2>/dev/null || true

        local comment="## Ralph Failed\n\n"
        comment+="**Reason:** $reason\n"
        comment+="**Last progress:** $progress_summary\n"
        comment+="**Timestamp:** $(date -u '+%Y-%m-%d %H:%M UTC')\n"

        gh issue comment "$issue_num" --repo "$repo" --body "$(echo -e "$comment")" 2>/dev/null || true
    fi
}

# =============================================================================
# Internal helpers
# =============================================================================

# Detect repo from git remote origin
_gh_detect_repo() {
    local remote_url
    remote_url=$(git remote get-url origin 2>/dev/null)
    if [[ -z "$remote_url" ]]; then
        return 1
    fi

    # Extract owner/repo from various URL formats
    local repo
    # SSH: git@github.com:owner/repo.git
    repo=$(echo "$remote_url" | sed -E 's|.*github\.com[:/]([^/]+/[^/.]+)(\.git)?$|\1|')

    if [[ -z "$repo" || "$repo" == "$remote_url" ]]; then
        return 1
    fi

    echo "$repo"
}

# Fetch issue via gh CLI or API
_gh_fetch_issue() {
    local repo="$1"
    local issue_num="$2"

    if command -v gh &>/dev/null; then
        gh issue view "$issue_num" --repo "$repo" --json number,title,body,state,labels 2>/dev/null
    elif [[ -n "${GITHUB_TOKEN:-}" ]]; then
        curl -s -H "Authorization: token $GITHUB_TOKEN" \
            "https://api.github.com/repos/$repo/issues/$issue_num" 2>/dev/null
    else
        return 1
    fi
}

# Generate fix_plan from issue body using Claude
_gh_generate_fix_plan() {
    local ralph_dir="$1"
    local issue_num="$2"
    local title="$3"
    local body="$4"

    # Try Claude-generated plan
    if command -v "${CLAUDE_CODE_CMD:-claude}" &>/dev/null; then
        local prompt="Convert this GitHub issue into a fix_plan.md checklist. Output ONLY markdown checkboxes (- [ ] task), one per line, ordered by implementation sequence.\n\nIssue #$issue_num: $title\n\n$body"

        local plan
        plan=$("${CLAUDE_CODE_CMD:-claude}" -p "$prompt" --output-format text --max-turns 1 2>/dev/null)

        if [[ -n "$plan" ]] && echo "$plan" | grep -qE '^\s*-\s*\['; then
            echo "# Fix Plan — Issue #$issue_num: $title" > "$ralph_dir/fix_plan.md"
            echo "" >> "$ralph_dir/fix_plan.md"
            echo "$plan" | grep -E '^\s*-\s*\[' >> "$ralph_dir/fix_plan.md"
            echo "Generated fix_plan from issue description"
            return 0
        fi
    fi

    # Fallback: create single-task plan
    echo "# Fix Plan — Issue #$issue_num: $title" > "$ralph_dir/fix_plan.md"
    echo "" >> "$ralph_dir/fix_plan.md"
    echo "- [ ] Implement: $title" >> "$ralph_dir/fix_plan.md"
    echo "Created single-task fix_plan (Claude unavailable for plan generation)"
}

# List issues via GitHub API (fallback when gh CLI not available)
_gh_api_list_issues() {
    local repo="$1"
    local url="https://api.github.com/repos/$repo/issues?state=open&per_page=20"

    [[ -n "${RALPH_ISSUE_LABEL:-}" ]] && url="$url&labels=$RALPH_ISSUE_LABEL"
    [[ -n "${RALPH_ISSUE_ASSIGNEE:-}" ]] && url="$url&assignee=$RALPH_ISSUE_ASSIGNEE"

    local response
    response=$(curl -s -H "Authorization: token $GITHUB_TOKEN" "$url" 2>/dev/null)

    if [[ -z "$response" ]]; then
        echo "Error: Failed to fetch issues from GitHub API"
        return 1
    fi

    echo "$response" | jq -r '.[] | "#\(.number)\t\(.title)\t\(.labels | map(.name) | join(","))"' 2>/dev/null | column -t -s $'\t'
}
