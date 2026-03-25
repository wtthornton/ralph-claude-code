#!/bin/bash

# INVARIANT: modifies ONLY fix_plan.md content (dynamic suffix). Never touches stable prompt prefix.

# lib/plan_optimizer.sh — Plan analysis and reordering engine (PLANOPT-2)
#
# Reorders unchecked tasks within each ## section of fix_plan.md for optimal execution.
# Three-layer dependency detection: import graph → explicit metadata → phase convention.
# Topological sort via Unix tsort, module grouping, phase ordering, size estimation.
# Semantic equivalence validation before atomic write with durable backup.
#
# Research basis: Unix tsort, SWE-Agent phase ordering, Bazel hermetic validation,
# Turborepo dependsOn, "Lost in the Middle" (Liu et al., Stanford 2023).
#
# Configuration:
#   RALPH_NO_EXPLORER_RESOLVE=false  — Disable ralph-explorer vague task resolution
#   RALPH_MAX_EXPLORER_RESOLVE=5     — Max vague tasks to resolve per run

RALPH_DIR="${RALPH_DIR:-.ralph}"
RALPH_NO_EXPLORER_RESOLVE="${RALPH_NO_EXPLORER_RESOLVE:-false}"
RALPH_MAX_EXPLORER_RESOLVE="${RALPH_MAX_EXPLORER_RESOLVE:-5}"

# =============================================================================
# Task parsing
# =============================================================================

# plan_parse_tasks — Parse fix_plan.md into JSON array of task objects via awk
#
# Each task object: idx, line_num, section, text, checked, files[], task_id, depends, size
# Metadata: <!-- id: foo -->, <!-- depends: bar -->, <!-- resolved: path -->
# File paths extracted from backtick-wrapped and bare paths.
# Size estimated inline: 0=SMALL, 1=MEDIUM, 2=LARGE.
#
# Usage: tasks_json=$(plan_parse_tasks "/path/to/fix_plan.md")
#
plan_parse_tasks() {
    local fix_plan="$1"

    [[ ! -f "$fix_plan" ]] && { echo "[]"; return 1; }

    awk '
    BEGIN { section=""; task_idx=0; print "[" }
    /^## / { section=$0; gsub(/"/, "\\\"", section); next }
    /^- \[[ xX]\]/ {
        if (task_idx > 0) print ","
        checked = ($0 ~ /\[[xX]\]/) ? "true" : "false"

        # Extract text (strip checkbox prefix)
        text = $0
        sub(/^- \[[ xX]\] */, "", text)

        # Extract file paths from backtick-wrapped references
        files = ""
        n = split(text, words, /[`]/)
        for (i=2; i<=n; i+=2) {
            if (words[i] ~ /\.[a-zA-Z]+$/) {
                if (files != "") files = files ","
                files = files "\"" words[i] "\""
            }
        }

        # Also extract bare paths (path/to/file.ext patterns)
        tmp = text
        while (match(tmp, /[a-zA-Z0-9_\/./-]+\.(py|ts|tsx|js|jsx|sh|json|yaml|yml|toml|md|css|html|go|rs|rb|java)/, m)) {
            bare = substr(tmp, RSTART, RLENGTH)
            # Avoid duplicates from backtick extraction
            if (index(files, "\"" bare "\"") == 0) {
                if (files != "") files = files ","
                files = files "\"" bare "\""
            }
            tmp = substr(tmp, RSTART + RLENGTH)
        }

        # Extract explicit metadata: <!-- id: foo -->
        task_id = ""
        if (match(text, /<!-- *id: *([a-zA-Z0-9_-]+) *-->/, m)) task_id = m[1]

        # Extract explicit metadata: <!-- depends: bar -->
        depends = ""
        if (match(text, /<!-- *depends: *([a-zA-Z0-9_-]+) *-->/, m)) depends = m[1]

        # Extract resolved file: <!-- resolved: path/to/file.ext -->
        if (match(text, /<!-- *resolved: *([a-zA-Z0-9_./-]+) *-->/, m)) {
            resolved = m[1]
            if (index(files, "\"" resolved "\"") == 0) {
                if (files != "") files = files ","
                files = files "\"" resolved "\""
            }
        }

        # Clean text: remove ALL metadata comments for display/comparison
        clean_text = text
        gsub(/<!-- *[a-zA-Z]+: *[a-zA-Z0-9_./ -]+ *-->/, "", clean_text)
        gsub(/ +$/, "", clean_text)
        gsub(/  +/, " ", clean_text)

        # Escape special chars in text for JSON output
        gsub(/\\/, "\\\\", clean_text)
        gsub(/"/, "\\\"", clean_text)
        gsub(/\t/, " ", clean_text)

        # Count files for size estimation
        file_count = 0
        if (files != "") {
            file_count = split(files, _fc, ",")
        }

        # Inline size estimation (SMALL=0, MEDIUM=1, LARGE=2)
        size = 1  # default MEDIUM
        lower_text = tolower(text)
        if (file_count <= 1 && lower_text ~ /(rename|typo|config|comment|remove unused|fix.*import|bump.*version|update.*version)/) size = 0
        else if (file_count >= 3 || lower_text ~ /(redesign|architect|cross.?module|new feature|security|integrate|migrate)/) size = 2

        printf "{\"idx\":%d,\"line_num\":%d,\"section\":\"%s\",\"text\":\"%s\",\"checked\":%s,\"files\":[%s],\"task_id\":\"%s\",\"depends\":\"%s\",\"size\":%d}\n", \
            task_idx, NR, section, clean_text, checked, files, task_id, depends, size
        task_idx++
    }
    END { print "]" }
    ' "$fix_plan" | jq '.'  # Validate JSON
}

# =============================================================================
# File resolution (ralph-explorer for vague tasks)
# =============================================================================

# plan_resolve_vague_tasks — Spawn ralph-explorer (Haiku) for tasks with no file references
#
# Caps at RALPH_MAX_EXPLORER_RESOLVE tasks per run. Caches results as
# <!-- resolved: path --> annotations in fix_plan.md.
#
# Guards:
#   - RALPH_NO_EXPLORER_RESOLVE=true disables resolution
#   - claude CLI must be available (command -v claude)
#   - plan_opt_log must be declared for logging (non-fatal if missing)
#
# Usage: plan_resolve_vague_tasks "$tasks_json" "$fix_plan" "$project_root"
#
plan_resolve_vague_tasks() {
    local tasks_json="$1"
    local fix_plan="$2"
    local project_root="$3"
    local max_resolve="${RALPH_MAX_EXPLORER_RESOLVE:-5}"

    # Skip if explorer resolution is disabled
    [[ "${RALPH_NO_EXPLORER_RESOLVE:-false}" == "true" ]] && return 0

    # Skip if claude CLI is not available (e.g., running in CI without Claude)
    command -v claude &>/dev/null || return 0

    # Find unchecked tasks with zero file references and no resolved annotation
    local vague_tasks
    vague_tasks=$(echo "$tasks_json" | jq -r '
        .[] | select(.checked == false and (.files | length) == 0) |
        "\(.idx)\t\(.text)"
    ' | head -"$max_resolve")

    [[ -z "$vague_tasks" ]] && return 0

    local resolved_count=0
    while IFS=$'\t' read -r idx text; do
        [[ -z "$idx" ]] && continue

        # Skip if already has a resolved annotation
        echo "$text" | grep -q '<!-- resolved:' && continue

        # Spawn ralph-explorer (Haiku — fast, cheap, ~500 tokens)
        local explorer_result
        explorer_result=$(claude --agent ralph-explorer \
            --prompt "Which source files in $project_root implement this task: $text
Return ONLY file paths relative to project root, one per line. Max 3 files. No explanation." \
            --max-turns 5 \
            --output-format json 2>/dev/null | jq -r '.result // ""') || continue

        if [[ -n "$explorer_result" ]]; then
            # Take first valid file path from explorer output
            local resolved_file
            resolved_file=$(echo "$explorer_result" | head -1 | grep -oE '[a-zA-Z0-9_/./-]+\.[a-z]+' | head -1)

            if [[ -n "$resolved_file" && -f "$project_root/$resolved_file" ]]; then
                # Annotate the task in fix_plan.md with resolved file
                local escaped_text
                escaped_text=$(printf '%s\n' "$text" | sed 's/[&/\]/\\&/g')
                sed -i "s|${escaped_text}|${text} <!-- resolved: ${resolved_file} -->|" "$fix_plan"
                resolved_count=$((resolved_count + 1))
            fi
        fi
    done <<< "$vague_tasks"

    if [[ $resolved_count -gt 0 ]]; then
        # Guard: plan_opt_log may not be defined yet (PLANOPT-5)
        declare -f plan_opt_log &>/dev/null && \
            plan_opt_log "Explorer resolved $resolved_count vague tasks to file paths"
    fi
}

# =============================================================================
# Module / phase / size helpers
# =============================================================================

# plan_extract_module — Extract primary module from files JSON (first 2 path components)
#
# Usage: module=$(plan_extract_module '["src/api/users.py"]')
# Returns: "src/api" or "zzz_unknown" if no files
#
plan_extract_module() {
    local files_json="$1"
    echo "$files_json" | jq -r '
        if length == 0 then "zzz_unknown"
        else .[0] | split("/")[0:2] | join("/")
        end
    '
}

# plan_phase_rank — Keyword-based phase rank for task ordering
#
# Phase ordering mirrors SWE-bench agent convergence (SWE-Agent, Agentless, AutoCodeRover):
#   0 = create/setup/init/define/schema/scaffold/bootstrap
#   1 = implement/add/build/write/develop
#   2 = modify/refactor/update/fix/change/rename/move (default)
#   3 = test/spec/verify/validate/assert
#   4 = document/readme/comment/changelog/release
#
# Usage: rank=$(plan_phase_rank "Create user database schema")
#
plan_phase_rank() {
    local text="$1"
    text=$(echo "$text" | tr '[:upper:]' '[:lower:]')
    case "$text" in
        *create*|*setup*|*init*|*define*|*schema*|*scaffold*|*bootstrap*)  echo 0 ;;
        *implement*|*add*|*build*|*write*|*develop*)                       echo 1 ;;
        *modify*|*refactor*|*update*|*fix*|*change*|*rename*|*move*)       echo 2 ;;
        *test*|*spec*|*verify*|*validate*|*assert*)                        echo 3 ;;
        *doc*|*readme*|*comment*|*changelog*|*release*)                    echo 4 ;;
        *)                                                                  echo 2 ;; # default: middle
    esac
}

# plan_size_rank — Keyword + file count based size rank
#
# 0=SMALL: single-file, minor changes (rename, typo, config, etc.)
# 1=MEDIUM: everything else (default)
# 2=LARGE: cross-module, architectural, 3+ files
#
# NOTE: Size heuristics here MUST match the inline estimation in plan_parse_tasks().
# TODO: When lib/complexity.sh is stable, delegate to its 5-level classifier
# and map TRIVIAL/SMALL→0, MEDIUM→1, LARGE/ARCHITECTURAL→2.
# The inline version exists because plan_parse_tasks runs in awk where sourcing
# bash functions isn't possible.
#
# Usage: size=$(plan_size_rank "Fix typo in config" 1)
#
plan_size_rank() {
    local text="$1"
    local file_count="${2:-0}"
    text=$(echo "$text" | tr '[:upper:]' '[:lower:]')

    # SMALL: single-file, minor changes
    if [[ $file_count -le 1 ]] && echo "$text" | grep -qiE 'rename|typo|config|comment|remove unused|update.*version|fix.*import'; then
        echo 0; return
    fi

    # LARGE: cross-module, architectural
    if [[ $file_count -ge 3 ]] || echo "$text" | grep -qiE 'redesign|architect|cross.?module|new feature|security|integrate|migrate'; then
        echo 2; return
    fi

    # MEDIUM: everything else
    echo 1
}

# =============================================================================
# Dependency detection + tsort
# =============================================================================

# plan_build_dependency_pairs — Three-layer dependency detection
#
# Layer 1: Import graph lookup (highest confidence) — file A imports file B
# Layer 2: Explicit metadata (human override) — <!-- id: -->, <!-- depends: -->
# Layer 3: Phase convention (lowest priority) — create before implement before test
#
# Outputs "A B" pairs (A must come before B) to a temp file.
# Never creates cross-section dependencies. Skips checked tasks.
#
# Usage: plan_build_dependency_pairs "$tasks_json" "$import_graph" "$pairs_file"
#
plan_build_dependency_pairs() {
    local tasks_json="$1"
    local import_graph="$2"  # path to .ralph/.import_graph.json
    local pairs_file="$3"    # output: one "A B" pair per line

    : > "$pairs_file"

    local task_count
    task_count=$(echo "$tasks_json" | jq 'length')

    for ((i=0; i<task_count; i++)); do
        for ((j=i+1; j<task_count; j++)); do
            local section_i section_j

            section_i=$(echo "$tasks_json" | jq -r ".[$i].section")
            section_j=$(echo "$tasks_json" | jq -r ".[$j].section")

            # Never create cross-section dependencies
            [[ "$section_i" != "$section_j" ]] && continue

            # Skip checked tasks
            [[ $(echo "$tasks_json" | jq -r ".[$i].checked") == "true" ]] && continue
            [[ $(echo "$tasks_json" | jq -r ".[$j].checked") == "true" ]] && continue

            # Layer 2: Explicit metadata (highest priority — human override)
            local id_i id_j depends_i depends_j
            id_i=$(echo "$tasks_json" | jq -r ".[$i].task_id")
            id_j=$(echo "$tasks_json" | jq -r ".[$j].task_id")
            depends_i=$(echo "$tasks_json" | jq -r ".[$i].depends")
            depends_j=$(echo "$tasks_json" | jq -r ".[$j].depends")

            if [[ -n "$depends_j" && "$depends_j" != "" && "$depends_j" == "$id_i" ]]; then
                echo "$i $j" >> "$pairs_file"  # i before j
                continue
            fi
            if [[ -n "$depends_i" && "$depends_i" != "" && "$depends_i" == "$id_j" ]]; then
                echo "$j $i" >> "$pairs_file"  # j before i
                continue
            fi

            # Layer 1: Import graph (highest confidence when available)
            if [[ -f "$import_graph" ]]; then
                local files_i files_j
                files_i=$(echo "$tasks_json" | jq -r ".[$i].files[]" 2>/dev/null)
                files_j=$(echo "$tasks_json" | jq -r ".[$j].files[]" 2>/dev/null)

                local found_import=false
                for fi_path in $files_i; do
                    [[ "$found_import" == "true" ]] && break
                    for fj_path in $files_j; do
                        # If file_i imports file_j -> task j should come before task i
                        if jq -e --arg a "$fi_path" --arg b "$fj_path" \
                            '.[$a] // [] | index($b) != null' "$import_graph" &>/dev/null; then
                            echo "$j $i" >> "$pairs_file"
                            found_import=true
                            break
                        fi
                        # If file_j imports file_i -> task i should come before task j
                        if jq -e --arg a "$fj_path" --arg b "$fi_path" \
                            '.[$a] // [] | index($b) != null' "$import_graph" &>/dev/null; then
                            echo "$i $j" >> "$pairs_file"
                            found_import=true
                            break
                        fi
                    done
                done
            fi
        done
    done
}

# plan_topological_order — Feed dependency pairs to Unix tsort
#
# Adds self-edges so all task indices appear in the output.
# Cycle warnings go to stderr (non-fatal — tsort produces best-effort order).
#
# Usage: topo_order=$(plan_topological_order "$pairs_file" "$task_count")
#
plan_topological_order() {
    local pairs_file="$1"
    local task_count="$2"

    if [[ ! -s "$pairs_file" ]]; then
        # No dependencies — return original order
        seq 0 $((task_count - 1))
        return
    fi

    # tsort produces a topological order; cycle warnings go to stderr (non-fatal)
    # Add self-edges to ensure all tasks appear in output even if they have no dependencies
    {
        seq 0 $((task_count - 1)) | while read -r n; do echo "$n $n"; done
        cat "$pairs_file"
    } | tsort 2>&2
}

# =============================================================================
# Secondary sort
# =============================================================================

# plan_secondary_sort — Composite sort key for stable ordering within topo ranks
#
# Key formula: (topo_rank * 100000) + (module_hash * 1000) + (phase * 100) + (size * 10) + original_index
# Module hash uses md5sum with shasum fallback for cross-platform compatibility.
#
# Usage: sorted=$(plan_secondary_sort "$tasks_json" "$topo_order" | sort -n | awk '{print $2}')
#
plan_secondary_sort() {
    local tasks_json="$1"
    local topo_order="$2"  # newline-separated task indices from tsort

    local rank=0
    while IFS= read -r idx; do
        [[ -z "$idx" ]] && continue

        local section text files_json file_count
        section=$(echo "$tasks_json" | jq -r ".[$idx].section")
        text=$(echo "$tasks_json" | jq -r ".[$idx].text")
        files_json=$(echo "$tasks_json" | jq -c ".[$idx].files")
        file_count=$(echo "$files_json" | jq 'length')

        local module phase size
        module=$(plan_extract_module "$files_json")
        phase=$(plan_phase_rank "$text")
        size=$(plan_size_rank "$text" "$file_count")

        # Module hash: consistent grouping (first 4 hex chars of hash)
        # md5sum with shasum fallback for cross-platform support
        local mod_hash
        mod_hash=$(echo -n "$module" | md5sum 2>/dev/null | cut -c1-4) || \
            mod_hash=$(echo -n "$module" | shasum 2>/dev/null | cut -c1-4) || \
            mod_hash="0000"
        local mod_num
        mod_num=$((16#${mod_hash}))

        local key=$(( rank * 100000 + (mod_num % 1000) * 1000 + phase * 100 + size * 10 + idx ))
        echo "$key $idx $section"
        rank=$((rank + 1))
    done <<< "$topo_order"
}

# =============================================================================
# Validation
# =============================================================================

# plan_validate_equivalence — Verify task set unchanged after reordering
#
# Checks: (1) task count unchanged, (2) sorted content hash unchanged.
# Aborts if task set was modified (prevents data loss from bugs).
# Inspired by Bazel's hermetic validation.
#
# Usage: plan_validate_equivalence "$before_texts_json" "$after_texts_json"
#
plan_validate_equivalence() {
    local before_tasks="$1"  # JSON array of task texts (pre-reorder)
    local after_tasks="$2"   # JSON array of task texts (post-reorder)

    local before_count after_count
    before_count=$(echo "$before_tasks" | jq 'length')
    after_count=$(echo "$after_tasks" | jq 'length')

    if [[ "$before_count" != "$after_count" ]]; then
        echo "PLAN_OPTIMIZE: ABORT — task count changed ($before_count -> $after_count)" >&2
        return 1
    fi

    # Sort task texts and hash — order-independent content check
    local before_hash after_hash
    before_hash=$(echo "$before_tasks" | jq -r '.[]' | sort | sha256sum 2>/dev/null | cut -d' ' -f1) || \
        before_hash=$(echo "$before_tasks" | jq -r '.[]' | sort | shasum -a 256 2>/dev/null | cut -d' ' -f1)
    after_hash=$(echo "$after_tasks" | jq -r '.[]' | sort | sha256sum 2>/dev/null | cut -d' ' -f1) || \
        after_hash=$(echo "$after_tasks" | jq -r '.[]' | sort | shasum -a 256 2>/dev/null | cut -d' ' -f1)

    if [[ "$before_hash" != "$after_hash" ]]; then
        echo "PLAN_OPTIMIZE: ABORT — task content changed during reorder" >&2
        return 1
    fi

    return 0
}

# =============================================================================
# Atomic write
# =============================================================================

# plan_write_optimized — Write reordered tasks back to fix_plan.md
#
# Atomic write: cp to .pre-optimize.bak, awk rebuild preserving structure
# (headers, checked tasks, blank lines, comments), replace unchecked tasks
# with reordered list per section, mv .tmp to fix_plan.
# Backup kept for 1 loop (overwritten, never deleted).
#
# Usage: plan_write_optimized "$fix_plan" "$reordered_json"
#
plan_write_optimized() {
    local fix_plan="$1"
    local reordered_json="$2"  # JSON array of reordered task objects

    local backup="${fix_plan}.pre-optimize.bak"
    local tmp="${fix_plan}.optimized.tmp"

    # Keep backup from previous optimization (if any) for 1 more loop
    # Only overwrite the backup, never delete it preemptively
    cp "$fix_plan" "$backup"

    # Build a mapping of section -> ordered unchecked task lines
    # We serialize this as a simple text block that awk can consume
    local section_tasks_file
    section_tasks_file=$(mktemp)

    # Extract reordered unchecked tasks grouped by section
    echo "$reordered_json" | jq -r '
        group_by(.section) | .[] |
        .[0].section as $sec |
        [.[] | select(.checked == false)] |
        if length == 0 then empty
        else
            "SECTION:" + $sec,
            (.[] | "TASK:" + .text),
            "ENDSECTION"
        end
    ' > "$section_tasks_file"

    # Rebuild fix_plan.md: preserve structure, replace unchecked task order
    awk -v section_file="$section_tasks_file" '
    BEGIN {
        # Load section -> task mapping from temp file
        current_load_section = ""
        section_count = 0
        while ((getline line < section_file) > 0) {
            if (line ~ /^SECTION:/) {
                current_load_section = substr(line, 9)
                task_idx_for[current_load_section] = 0
            } else if (line ~ /^TASK:/) {
                task_text = substr(line, 6)
                idx = task_idx_for[current_load_section]
                section_tasks[current_load_section, idx] = task_text
                task_idx_for[current_load_section] = idx + 1
                section_task_count[current_load_section] = idx + 1
            }
        }
        close(section_file)

        current_section = ""
        section_emitted_flag = 0
    }

    /^## / {
        current_section = $0
        section_emitted_flag = 0
        emit_idx[current_section] = 0
        print
        next
    }

    /^- \[[xX]\]/ {
        # Checked tasks: keep in original position
        print
        next
    }

    /^- \[ \]/ {
        # Unchecked tasks: replace with reordered list on first encounter per section
        if (!section_emitted_flag && current_section in section_task_count) {
            count = section_task_count[current_section]
            for (i = 0; i < count; i++) {
                print "- [ ] " section_tasks[current_section, i]
            }
            section_emitted_flag = 1
        }
        # Skip original unchecked line (whether first or subsequent)
        next
    }

    {
        # Everything else: headers, blank lines, comments, non-task content — pass through
        print
    }
    ' "$fix_plan" > "$tmp"

    # Atomic replace
    mv "$tmp" "$fix_plan"

    # Cleanup
    rm -f "$section_tasks_file"

    # NOTE: $backup is intentionally kept for 1 full loop iteration.
    # It will be overwritten (not deleted) on the next optimization run.
}

# =============================================================================
# Orchestrator
# =============================================================================

# plan_optimize_section — Top-level plan optimization orchestrator
#
# Pipeline: parse → resolve vague → capture before_texts → build pairs →
#           tsort → secondary sort → validate equivalence → write
#
# Early exit if <=1 unchecked task (nothing to reorder).
#
# Usage: plan_optimize_section "$fix_plan" "$project_root" ["$import_graph"]
#
plan_optimize_section() {
    local fix_plan="$1"
    local project_root="$2"
    local import_graph="${3:-${RALPH_DIR:-.ralph}/.import_graph.json}"

    [[ ! -f "$fix_plan" ]] && return 1

    # Parse tasks
    local tasks_json
    tasks_json=$(plan_parse_tasks "$fix_plan")

    local unchecked_count
    unchecked_count=$(echo "$tasks_json" | jq '[.[] | select(.checked == false)] | length')

    # Early exit: nothing to reorder
    if [[ "$unchecked_count" -le 1 ]]; then
        return 0
    fi

    # Resolve vague tasks via ralph-explorer (Haiku, cached via <!-- resolved: -->)
    plan_resolve_vague_tasks "$tasks_json" "$fix_plan" "$project_root"

    # Re-parse after resolution (fix_plan may have been annotated with resolved paths)
    tasks_json=$(plan_parse_tasks "$fix_plan")

    # Capture pre-reorder task texts for equivalence check
    local before_texts
    before_texts=$(echo "$tasks_json" | jq '[.[] | select(.checked == false) | .text]')

    # Build dependency pairs (three layers: import graph, explicit metadata, phase)
    local pairs_file
    pairs_file=$(mktemp)
    plan_build_dependency_pairs "$tasks_json" "$import_graph" "$pairs_file"

    # Topological sort via Unix tsort
    local topo_order
    topo_order=$(plan_topological_order "$pairs_file" "$unchecked_count")
    rm -f "$pairs_file"

    # Secondary sort (module grouping + phase + size + original index)
    local sorted_keys
    sorted_keys=$(plan_secondary_sort "$tasks_json" "$topo_order" | sort -n | awk '{print $2}')

    # Build reordered task list from sorted indices
    local reordered_json
    reordered_json=$(echo "$sorted_keys" | while read -r idx; do
        [[ -z "$idx" ]] && continue
        echo "$tasks_json" | jq ".[$idx]"
    done | jq -s '.')

    # Validate semantic equivalence (Bazel-inspired hermetic check)
    local after_texts
    after_texts=$(echo "$reordered_json" | jq '[.[] | .text]')

    if ! plan_validate_equivalence "$before_texts" "$after_texts"; then
        echo "PLAN_OPTIMIZE: Equivalence check failed, aborting" >&2
        return 1
    fi

    # Write optimized plan (atomic with durable backup)
    plan_write_optimized "$fix_plan" "$reordered_json"
}

# =============================================================================
# Section-level hashing and change detection (PLANOPT-3)
# =============================================================================

# plan_section_hashes — Hash unchecked task lines per section
#
# Outputs tab-separated "section_header\thash" lines, one per section.
# Only unchecked tasks (- [ ]) contribute to the hash — checking off a task
# changes the hash, enabling change detection at the section level.
#
# Usage: plan_section_hashes "/path/to/fix_plan.md"
#
plan_section_hashes() {
    local fix_plan="$1"

    [[ ! -f "$fix_plan" ]] && return 1

    awk '
    /^## / {
        if (section_text != "") {
            cmd = "printf \"%s\" \"" section_text "\" | sha256sum 2>/dev/null || printf \"%s\" \"" section_text "\" | shasum -a 256 2>/dev/null"
            cmd | getline hash
            close(cmd)
            split(hash, h, " ")
            print section_name "\t" h[1]
        }
        section_name = $0
        section_text = ""
        next
    }
    /^- \[ \]/ {
        section_text = section_text $0 "\n"
    }
    END {
        if (section_text != "") {
            cmd = "printf \"%s\" \"" section_text "\" | sha256sum 2>/dev/null || printf \"%s\" \"" section_text "\" | shasum -a 256 2>/dev/null"
            cmd | getline hash
            close(cmd)
            split(hash, h, " ")
            print section_name "\t" h[1]
        }
    }
    ' "$fix_plan"
}

# plan_changed_sections — Detect which sections have changed since last optimization
#
# Compares current section hashes against stored hashes in hash_file.
# On first run (no hash file), all sections are considered "changed".
# Outputs changed section headers (one per line).
#
# Usage: changed=$(plan_changed_sections "$fix_plan" "$hash_file")
#
plan_changed_sections() {
    local fix_plan="$1"
    local hash_file="$2"  # .ralph/.plan_section_hashes

    local current_hashes
    current_hashes=$(plan_section_hashes "$fix_plan")

    if [[ ! -f "$hash_file" ]]; then
        # First run: all sections are "changed"
        echo "$current_hashes" | cut -f1
        echo "$current_hashes" > "$hash_file"
        return
    fi

    local previous_hashes
    previous_hashes=$(cat "$hash_file")

    # Diff to find changed sections
    while IFS=$'\t' read -r section hash; do
        local prev_hash
        prev_hash=$(echo "$previous_hashes" | grep "^${section}	" | cut -f2)
        if [[ "$hash" != "$prev_hash" ]]; then
            echo "$section"
        fi
    done <<< "$current_hashes"

    # Update stored hashes (will be overwritten with post-optimization hashes)
    echo "$current_hashes" > "$hash_file"
}

# =============================================================================
# Batch annotation (PLANOPT-3)
# =============================================================================

# plan_annotate_batches — Generate batch hints for context injection
#
# Analyzes upcoming unchecked tasks and groups consecutive same-size tasks
# into batch annotations like [BATCH-3: SMALL] [SINGLE: LARGE].
# Uses .size field from plan_parse_tasks (0=SMALL, 1=MEDIUM, 2=LARGE).
# Looks at up to 8 upcoming tasks.
#
# Usage: hint=$(plan_annotate_batches "$tasks_json")
#
plan_annotate_batches() {
    local tasks_json="$1"

    # Map numeric size to label
    local -A size_labels=([0]="SMALL" [1]="MEDIUM" [2]="LARGE")

    echo "$tasks_json" | jq -r '
        [.[] | select(.checked == false)] | .[0:8] |
        .[] | "\(.size // 1)"
    ' | {
        local result=""
        local batch_size=0
        local prev_size=""

        while IFS= read -r size; do
            if [[ "$size" == "$prev_size" || -z "$prev_size" ]]; then
                batch_size=$((batch_size + 1))
            else
                if [[ $batch_size -gt 1 ]]; then
                    result="${result}[BATCH-${batch_size}: ${size_labels[$prev_size]:-MEDIUM}] "
                elif [[ -n "$prev_size" ]]; then
                    result="${result}[SINGLE: ${size_labels[$prev_size]:-MEDIUM}] "
                fi
                batch_size=1
            fi
            prev_size="$size"
        done

        # Emit final batch
        if [[ $batch_size -gt 1 ]]; then
            result="${result}[BATCH-${batch_size}: ${size_labels[$prev_size]:-MEDIUM}]"
        elif [[ -n "$prev_size" ]]; then
            result="${result}[SINGLE: ${size_labels[$prev_size]:-MEDIUM}]"
        fi

        echo "$result"
    }
}

# =============================================================================
# Export functions for use in other scripts
# =============================================================================
export -f plan_parse_tasks
export -f plan_resolve_vague_tasks
export -f plan_extract_module
export -f plan_phase_rank
export -f plan_size_rank
export -f plan_build_dependency_pairs
export -f plan_topological_order
export -f plan_secondary_sort
export -f plan_validate_equivalence
export -f plan_write_optimized
export -f plan_optimize_section
export -f plan_section_hashes
export -f plan_changed_sections
export -f plan_annotate_batches
