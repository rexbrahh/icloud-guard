#!/bin/bash

# shellcheck shell=bash

safe_remove_tree() {
    [[ $# -eq 2 ]] || { echo "ERROR: safe_remove_tree requires TARGET and PARENT." >&2; return 64; }
    local target="$1"
    local allowed_parent="$2"

    [[ "$target" == /* && "$allowed_parent" == /* ]] || {
        echo "ERROR: Cleanup paths must be absolute." >&2
        return 1
    }
    [[ -d "$allowed_parent" && ! -L "$allowed_parent" ]] || {
        echo "ERROR: Cleanup parent is not a real directory: $allowed_parent" >&2
        return 1
    }
    [[ ! -L "$target" ]] || {
        echo "ERROR: Refusing to clean a symlink: $target" >&2
        return 1
    }

    local canonical_parent target_parent target_name
    canonical_parent="$(cd "$allowed_parent" && pwd -P)"
    target_parent="$(cd "$(dirname "$target")" && pwd -P)"
    target_name="$(basename "$target")"
    [[ "$target_parent" == "$canonical_parent" && "$target_name" != "." && "$target_name" != ".." ]] || {
        echo "ERROR: Cleanup target is outside its exact parent: $target" >&2
        return 1
    }
    [[ -e "$target" ]] || return 0
    [[ -d "$target" ]] || {
        echo "ERROR: Cleanup target is not a directory: $target" >&2
        return 1
    }

    /usr/bin/find -P "$target" -depth -mindepth 1 -delete
    rmdir "$target"
}
