#!/bin/bash
# lib/skills_install.sh — TAP-574: Global skill install/uninstall with sidecar manifest.
#
# Installs skills from templates/skills/global/<name>/ into ~/.claude/skills/<name>/.
# Each Ralph-managed skill carries a .ralph-managed sidecar (JSON manifest of
# sha256 hashes) so we can idempotently re-install Ralph-owned files while
# leaving user-modified content alone.
#
# Sidecar format (at the root of each Ralph-installed skill dir):
#   {
#     "ralph_version": "1.9.0",
#     "installed_at": "2026-04-18T...",
#     "files": { "SKILL.md": "sha256:abc...", "examples/foo.md": "sha256:def..." }
#   }
#
# Three install cases for a destination skill dir:
#   1. does not exist          -> copy everything + write sidecar
#   2. exists + has sidecar    -> replace files whose current hash matches the
#                                 sidecar manifest (Ralph still owns them),
#                                 warn on user-modified files, then refresh
#                                 the sidecar to the new Ralph baseline
#   3. exists, no sidecar      -> user-authored, skip entirely

# Guard against double-source.
[[ -n "${SKILLS_INSTALL_SOURCED:-}" ]] && return 0
SKILLS_INSTALL_SOURCED=1

# Cross-platform sha256. Emits just the hex digest to stdout.
_skills_sha256() {
    local file="$1"
    if command -v sha256sum &>/dev/null; then
        sha256sum "$file" 2>/dev/null | awk '{print $1}'
    elif command -v shasum &>/dev/null; then
        shasum -a 256 "$file" 2>/dev/null | awk '{print $1}'
    else
        return 1
    fi
}

# List all files under a skill dir, relative paths, sorted, excluding the sidecar.
_skills_list_files() {
    local dir="$1"
    ( cd "$dir" && find . -type f -not -name '.ralph-managed' 2>/dev/null \
        | sed 's|^\./||' | LC_ALL=C sort )
}

# Build JSON sidecar manifest for a source skill dir.
_skills_build_manifest() {
    local dir="$1"
    local version="$2"
    local installed_at
    installed_at="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

    local files_json="{}"
    local rel hash
    while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        hash=$(_skills_sha256 "$dir/$rel") || return 1
        files_json=$(jq --arg p "$rel" --arg h "sha256:$hash" \
            '. + {($p): $h}' <<<"$files_json") || return 1
    done < <(_skills_list_files "$dir")

    jq -n \
        --arg v "$version" \
        --arg t "$installed_at" \
        --argjson f "$files_json" \
        '{ralph_version:$v, installed_at:$t, files:$f}'
}

# Install one skill dir src -> dest. Idempotent via sidecar.
# Args: src_dir dest_dir ralph_version
skills_install_one() {
    local src="$1"
    local dest="$2"
    local version="$3"
    local name
    name=$(basename "$src")

    [[ -d "$src" ]] || return 0

    # Case 3: dest exists without sidecar -> user-authored, skip.
    if [[ -d "$dest" && ! -f "$dest/.ralph-managed" ]]; then
        echo "INFO: user-authored skill already present, skipping: $name" >&2
        return 0
    fi

    # Case 1: fresh install.
    if [[ ! -d "$dest" ]]; then
        mkdir -p "$dest"
        local rel
        while IFS= read -r rel; do
            [[ -z "$rel" ]] && continue
            mkdir -p "$dest/$(dirname "$rel")"
            cp "$src/$rel" "$dest/$rel"
        done < <(_skills_list_files "$src")
        _skills_build_manifest "$src" "$version" > "$dest/.ralph-managed"
        return 0
    fi

    # Case 2: dest exists with sidecar -> replace Ralph-owned files only.
    local old_manifest="$dest/.ralph-managed"
    local rel
    while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        local dest_file="$dest/$rel"
        local src_file="$src/$rel"

        if [[ -f "$dest_file" ]]; then
            local dest_hash expected_hash
            dest_hash=$(_skills_sha256 "$dest_file")
            expected_hash=$(jq -r --arg p "$rel" '.files[$p] // ""' "$old_manifest" \
                | sed 's|^sha256:||')
            if [[ -n "$expected_hash" && "$dest_hash" == "$expected_hash" ]]; then
                mkdir -p "$dest/$(dirname "$rel")"
                cp "$src_file" "$dest_file"
            else
                echo "WARN: user-modified skill file, skipping: $dest/$rel" >&2
            fi
        else
            # File absent (user deleted or new-in-Ralph) -> add.
            mkdir -p "$dest/$(dirname "$rel")"
            cp "$src_file" "$dest_file"
        fi
    done < <(_skills_list_files "$src")

    _skills_build_manifest "$src" "$version" > "$dest/.ralph-managed"
    return 0
}

# Install every skill under src_root into dest_root.
# Args: src_root dest_root ralph_version
skills_install_global() {
    local src_root="$1"
    local dest_root="$2"
    local version="$3"

    [[ -d "$src_root" ]] || return 0

    mkdir -p "$dest_root"

    local saved_nullglob
    saved_nullglob=$(shopt -p nullglob || true)
    shopt -s nullglob
    local src_skill
    for src_skill in "$src_root"/*/; do
        [[ -d "$src_skill" ]] || continue
        local name
        name=$(basename "$src_skill")
        skills_install_one "${src_skill%/}" "$dest_root/$name" "$version" || {
            eval "$saved_nullglob"
            return 1
        }
    done
    eval "$saved_nullglob"
}

# Uninstall a single Ralph-managed skill. Only removes files whose current hash
# matches the sidecar manifest. Leaves user-modified files alone.
skills_uninstall_one() {
    local dest="$1"
    [[ -d "$dest" ]] || return 0
    [[ -f "$dest/.ralph-managed" ]] || return 0

    local manifest="$dest/.ralph-managed"
    local rel
    while IFS= read -r rel; do
        [[ -z "$rel" ]] && continue
        local file="$dest/$rel"
        [[ -f "$file" ]] || continue
        local cur expected
        cur=$(_skills_sha256 "$file")
        expected=$(jq -r --arg p "$rel" '.files[$p] // ""' "$manifest" | sed 's|^sha256:||')
        if [[ -n "$expected" && "$cur" == "$expected" ]]; then
            rm -f "$file"
        fi
    done < <(jq -r '.files | keys_unsorted[]' "$manifest" | LC_ALL=C sort -r)

    rm -f "$manifest"

    # Best-effort: prune empty intermediate dirs; leave skill root alone if
    # the user has their own files in it.
    find "$dest" -mindepth 1 -type d -empty -delete 2>/dev/null || true
    rmdir "$dest" 2>/dev/null || true
}

# Uninstall every Ralph-managed skill under dest_root.
skills_uninstall_global() {
    local dest_root="$1"
    [[ -d "$dest_root" ]] || return 0
    local saved_nullglob
    saved_nullglob=$(shopt -p nullglob || true)
    shopt -s nullglob
    local d
    for d in "$dest_root"/*/; do
        [[ -d "$d" && -f "$d/.ralph-managed" ]] || continue
        skills_uninstall_one "${d%/}"
    done
    eval "$saved_nullglob"
}
