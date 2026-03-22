#!/bin/bash

# lib/backup.sh — State backup and rollback (Phase 8, OBSERVE-3)
#
# Automatic snapshots of .ralph/ state at epic boundaries (section completions).
# Mid-epic loops skip backup for performance. Manual rollback via ralph --rollback.

RALPH_MAX_BACKUPS="${RALPH_MAX_BACKUPS:-10}"
BACKUP_DIR="${RALPH_DIR:-.ralph}/backups"

# ralph_backup_state — Create a snapshot of .ralph/ state
#
# Called before each loop iteration.
# Saves: fix_plan.md, PROMPT.md, status.json, circuit breaker state,
#        session ID, call count.
#
ralph_backup_state() {
    local ralph_dir="${RALPH_DIR:-.ralph}"
    local backup_dir="$ralph_dir/backups"
    local timestamp
    timestamp=$(date '+%Y%m%d-%H%M%S')
    local snapshot_dir="$backup_dir/$timestamp"

    mkdir -p "$snapshot_dir"

    # Copy state files (ignore missing)
    local files_to_backup=(
        "fix_plan.md"
        "PROMPT.md"
        "AGENT.md"
        "status.json"
        ".circuit_breaker_state"
        ".claude_session_id"
        ".call_count"
        ".last_reset"
        ".exit_signals"
    )

    local files_saved=0
    for file in "${files_to_backup[@]}"; do
        if [[ -f "$ralph_dir/$file" ]]; then
            cp "$ralph_dir/$file" "$snapshot_dir/" 2>/dev/null && ((files_saved++))
        fi
    done

    # Write metadata
    cat > "$snapshot_dir/.backup_meta.json" << METAEOF
{
    "timestamp": "$timestamp",
    "created_at": "$(date -u '+%Y-%m-%dT%H:%M:%SZ')",
    "files_saved": $files_saved,
    "ralph_version": "${RALPH_VERSION:-unknown}",
    "loop_count": ${LOOP_COUNT:-0}
}
METAEOF

    # Prune old backups (keep max)
    _ralph_prune_backups "$backup_dir"

    return 0
}

# ralph_rollback — Restore state from a backup
#
# Usage: ralph_rollback [--list] [--backup TIMESTAMP]
#
ralph_rollback() {
    local ralph_dir="${RALPH_DIR:-.ralph}"
    local backup_dir="$ralph_dir/backups"
    local list_mode=false
    local target_backup=""

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --list) list_mode=true; shift ;;
            --backup) target_backup="$2"; shift 2 ;;
            *) shift ;;
        esac
    done

    if [[ ! -d "$backup_dir" ]]; then
        echo "No backups found."
        return 1
    fi

    # List available backups
    local backups
    backups=$(ls -1d "$backup_dir"/[0-9]* 2>/dev/null | sort -r)

    if [[ -z "$backups" ]]; then
        echo "No backups found."
        return 1
    fi

    if [[ "$list_mode" == "true" ]]; then
        echo "Available backups:"
        echo ""
        while IFS= read -r backup_path; do
            local name
            name=$(basename "$backup_path")
            local meta_file="$backup_path/.backup_meta.json"
            local files_count=0
            local loop_info=""

            if [[ -f "$meta_file" ]] && command -v jq &>/dev/null; then
                files_count=$(jq -r '.files_saved // 0' "$meta_file" 2>/dev/null)
                loop_info=$(jq -r '.loop_count // ""' "$meta_file" 2>/dev/null)
            else
                files_count=$(find "$backup_path" -maxdepth 1 -type f ! -name '.backup_meta.json' | wc -l | tr -d ' ')
            fi

            local display_time
            # Parse YYYYMMDD-HHMMSS into human-readable
            display_time="${name:0:4}-${name:4:2}-${name:6:2} ${name:9:2}:${name:11:2}:${name:13:2}"

            printf "  %s  (%d files" "$display_time" "$files_count"
            [[ -n "$loop_info" && "$loop_info" != "0" ]] && printf ", loop %s" "$loop_info"
            printf ")\n"
        done <<< "$backups"
        return 0
    fi

    # Select backup to restore
    if [[ -z "$target_backup" ]]; then
        # Use most recent
        target_backup=$(echo "$backups" | head -1)
    else
        # Find by timestamp prefix
        target_backup=$(echo "$backups" | grep "$target_backup" | head -1)
    fi

    if [[ -z "$target_backup" || ! -d "$target_backup" ]]; then
        echo "Error: Backup not found"
        return 1
    fi

    local backup_name
    backup_name=$(basename "$target_backup")

    # Confirmation prompt
    echo "Restore backup from $backup_name?"
    echo "This will overwrite current .ralph/ state files."
    read -r -p "Continue? [y/N] " confirm
    if [[ "$confirm" != "y" && "$confirm" != "Y" ]]; then
        echo "Cancelled."
        return 0
    fi

    # Restore files
    local restored=0
    for file in "$target_backup"/*; do
        local filename
        filename=$(basename "$file")
        [[ "$filename" == ".backup_meta.json" ]] && continue
        cp "$file" "$ralph_dir/$filename" 2>/dev/null && ((restored++))
    done

    echo "Restored $restored files from backup $backup_name"
    return 0
}

# _ralph_prune_backups — Remove old backups beyond max limit
_ralph_prune_backups() {
    local backup_dir="$1"
    local max="${RALPH_MAX_BACKUPS:-10}"

    local backups
    backups=$(ls -1d "$backup_dir"/[0-9]* 2>/dev/null | sort -r)
    local count
    count=$(echo "$backups" | grep -c . 2>/dev/null) || count=0

    if [[ "$count" -gt "$max" ]]; then
        echo "$backups" | tail -n +"$((max + 1))" | while IFS= read -r old_backup; do
            rm -rf "$old_backup"
        done
    fi
}
