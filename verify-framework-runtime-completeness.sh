#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="/run/media/derek/main/chisimba-revival"
FRAMEWORK="$ROOT/framework"
RUNTIME="$ROOT/dev-environment/runtime/php82-ch"

REPORT="${VERIFY_REPORT:-$HOME/Downloads/killme.txt}"
APPEND="${VERIFY_APPEND:-1}"

if [[ "$APPEND" == "1" ]]; then
    exec > >(tee -a "$REPORT") 2>&1
else
    exec > >(tee "$REPORT") 2>&1
fi

section() {
    printf '\n================================================================================\n%s\n================================================================================\n' "$1"
}

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

[[ -d "$FRAMEWORK/.git" ]] || fail "Framework repository not found: $FRAMEWORK"
[[ -d "$RUNTIME" ]] || fail "Runtime not found: $RUNTIME"

section "FRAMEWORK RUNTIME COMPLETENESS VERIFICATION"
date --iso-8601=seconds

MISSING="$(mktemp)"
MISMATCH="$(mktemp)"
trap 'rm -f "$MISSING" "$MISMATCH"' EXIT

tracked=0
present=0
missing=0
mismatch=0

while IFS= read -r source_rel; do
    [[ -n "$source_rel" ]] || continue
    tracked=$((tracked + 1))

    runtime_rel="${source_rel#app/}"
    source_path="$FRAMEWORK/$source_rel"
    runtime_path="$RUNTIME/$runtime_rel"

    if [[ ! -e "$runtime_path" ]]; then
        printf '%s -> %s\n' "$source_rel" "$runtime_rel" >> "$MISSING"
        missing=$((missing + 1))
        continue
    fi

    present=$((present + 1))

    if [[ -f "$source_path" && -f "$runtime_path" ]]; then
        if ! cmp -s "$source_path" "$runtime_path"; then
            printf '%s -> %s\n' "$source_rel" "$runtime_rel" >> "$MISMATCH"
            mismatch=$((mismatch + 1))
        fi
    fi
done < <(git -C "$FRAMEWORK" ls-files 'app/**')

echo "Tracked framework app files: $tracked"
echo "Present in runtime:          $present"
echo "Missing from runtime:        $missing"
echo "Content mismatches:          $mismatch"

if [[ -s "$MISSING" ]]; then
    section "MISSING TRACKED FILES"
    cat "$MISSING"
fi

if [[ -s "$MISMATCH" ]]; then
    section "SOURCE/RUNTIME CONTENT DIFFERENCES"
    cat "$MISMATCH"
fi

section "VERIFICATION RESULT"

if [[ "$missing" -gt 0 ]]; then
    echo "FAIL: runtime is incomplete."
    echo "At least one tracked framework file is absent from the PHP 8.2 runtime."
    exit 2
fi

echo "PASS: every tracked framework app file exists in the PHP 8.2 runtime."

if [[ "$mismatch" -gt 0 ]]; then
    echo
    echo "NOTICE: $mismatch source/runtime files differ."
    echo "This may be expected when a selective deployment has not yet copied current working-tree changes."
fi
