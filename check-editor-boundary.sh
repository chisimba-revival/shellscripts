#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="/run/media/derek/main/chisimba-revival"
FRAMEWORK="${ROOT}/framework"
MODULES="${ROOT}/modules"
BASELINE="${FRAMEWORK}/app/core_modules/htmlelements/editor-direct-usage-baseline.txt"
[[ -f "${BASELINE}" ]] || { echo "Missing editor baseline: ${BASELINE}"; exit 1; }
CURRENT="$(mktemp)"
KNOWN="$(mktemp)"
trap 'rm -f "${CURRENT}" "${KNOWN}"' EXIT

grep -RIlE \
    --binary-files=without-match \
    --exclude-dir=.git \
    --exclude-dir=resources \
    --exclude-dir=documentation \
    --exclude-dir=docs \
    --exclude-dir=vendor \
    --exclude-dir=tinymce \
    --exclude-dir=ckeditor2 \
    --exclude='*.sql' \
    --include='*.php' \
    --include='*.inc' \
    '(FCKeditorAPI|tinyMCE[.]|CKEDITOR[.]|Ext[.]form[.]HtmlEditor|new[[:space:]]+FCKeditor)' \
    "${FRAMEWORK}/app/core_modules" "${MODULES}" 2>/dev/null \
    | sed "s#^${ROOT}/##" \
    | grep -v '^framework/app/core_modules/htmlelements/classes/htmlarea_class_inc.php$' \
    | sort -u >"${CURRENT}" || true
sort -u "${BASELINE}" >"${KNOWN}"
NEW="$(comm -13 "${KNOWN}" "${CURRENT}" || true)"
REMOVED="$(comm -23 "${KNOWN}" "${CURRENT}" || true)"
[[ -n "${REMOVED}" ]] && { echo "Direct editor bypasses removed since baseline:"; echo "${REMOVED}"; echo; }
if [[ -n "${NEW}" ]]; then
    echo "FAIL: new direct editor bypasses were introduced:"
    echo "${NEW}"
    echo
    echo "Use htmlelements/htmlarea instead."
    exit 1
fi
echo "PASS: no new direct editor bypasses were introduced."
