#!/usr/bin/env bash
#
# Chisimba Revival — ExtJS debt audit
#
# Reports remaining authoritative ExtJS references and fails when a migrated
# module regresses. This is a removal gate, not a compatibility mechanism.
#
# Author/Developer: Derek Keats
#

set -Eeuo pipefail

ROOT="/run/media/derek/main/chisimba-revival"
FRAMEWORK="${ROOT}/framework"
MODULES="${ROOT}/modules"

echo "Remaining direct Ext.* references:"
grep -RInE \
    --include='*.php' --include='*.inc' --include='*.js' \
    --exclude='*.min.js' --exclude='*-debug.js' \
    --exclude-dir='.git' --exclude-dir='resources' \
    '\bExt\.[A-Za-z_][A-Za-z0-9_.]*' \
    "${FRAMEWORK}" "${MODULES}" 2>/dev/null || true

echo
echo "Remaining direct ExtJS asset references:"
grep -RInE \
    --include='*.php' --include='*.inc' --include='*.js' \
    --exclude-dir='.git' --exclude-dir='resources' \
    'ext-(3\.0-rc2|3\.0\.0|3\.0\.3|3\.4\.0).*(ext-all|ext-base|ext-core|ext-prototype-adapter)' \
    "${FRAMEWORK}" "${MODULES}" 2>/dev/null || true

echo
echo "Regression gate: tooltipdemo"

if grep -RInE \
    --include='*.php' --include='*.inc' --include='*.js' \
    --exclude-dir='.git' --exclude-dir='resources' \
    'Ext\.|ext-all|ext-base|ext-core|ext-3\.' \
    "${MODULES}/tooltipdemo" 2>/dev/null; then
    echo "FAIL: tooltipdemo contains an ExtJS reference."
    exit 1
fi

echo "PASS: tooltipdemo remains ExtJS-free."
