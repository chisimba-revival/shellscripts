#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/run/media/derek/main/chisimba-revival"
FRAMEWORK="$ROOT/framework"
RUNTIME="$ROOT/dev-environment/runtime/php82-ch"
BASE_DEPLOY="$ROOT/shellscripts/deployment/deploy-framework.sh"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ -d "$FRAMEWORK/.git" ]] || fail "Framework repository not found: $FRAMEWORK"
[[ -x "$BASE_DEPLOY" ]] || fail "Base deployment script not executable: $BASE_DEPLOY"
[[ -d "$RUNTIME" ]] || fail "Runtime tree not found: $RUNTIME"

"$BASE_DEPLOY" "$@"

echo
echo "================================================================================"
echo "DELETION SYNCHRONIZATION"
echo "================================================================================"

tmp_deleted="$(mktemp)"
tmp_unique="$(mktemp)"
tmp_parents="$(mktemp)"
trap 'rm -f "$tmp_deleted" "$tmp_unique" "$tmp_parents"' EXIT

git -C "$FRAMEWORK" diff \
    --name-only --diff-filter=D -- app/ >> "$tmp_deleted"

git -C "$FRAMEWORK" diff --cached \
    --name-only --diff-filter=D -- app/ >> "$tmp_deleted"

sort -u "$tmp_deleted" > "$tmp_unique"

runtime_real="$(realpath -m "$RUNTIME")"
deleted_count=0
absent_count=0

while IFS= read -r source_rel; do
    [[ -n "$source_rel" ]] || continue

    case "$source_rel" in
        app/*) ;;
        *) fail "Refusing non-app deletion path: $source_rel" ;;
    esac

    runtime_rel="${source_rel#app/}"

    case "$runtime_rel" in
        ""|"/"|.*|*"/../"*|../*|*"/.."|*"//"*)
            fail "Unsafe mapped runtime path: $runtime_rel"
            ;;
    esac

    target="$RUNTIME/$runtime_rel"
    target_real="$(realpath -m "$target")"

    case "$target_real" in
        "$runtime_real"/*) ;;
        *) fail "Mapped target escapes runtime: $target_real" ;;
    esac

    dirname "$target_real" >> "$tmp_parents"

    if [[ -e "$target" || -L "$target" ]]; then
        if [[ -d "$target" && ! -L "$target" ]]; then
            fail "Git reported a file deletion but runtime target is a directory: $target"
        fi
        rm -f -- "$target"
        echo "DELETE: $source_rel -> $runtime_rel"
        deleted_count=$((deleted_count + 1))
    else
        echo "ABSENT: $runtime_rel"
        absent_count=$((absent_count + 1))
    fi
done < "$tmp_unique"

# Prune only directories directly related to deleted managed files.
# Walk deepest paths first and stop at the runtime root.
sort -u "$tmp_parents" | awk '{ print length, $0 }' | sort -rn | cut -d" " -f2- |
while IFS= read -r dir; do
    current="$dir"
    while [[ "$current" != "$runtime_real" ]]; do
        case "$current" in
            "$runtime_real"/*) ;;
            *) fail "Refusing to prune outside runtime: $current" ;;
        esac

        if rmdir -- "$current" 2>/dev/null; then
            echo "RMDIR: ${current#"$runtime_real"/}"
            current="$(dirname "$current")"
        else
            break
        fi
    done
done

echo
echo "Deletion synchronization complete."
echo "Runtime files deleted: $deleted_count"
echo "Already absent:         $absent_count"
