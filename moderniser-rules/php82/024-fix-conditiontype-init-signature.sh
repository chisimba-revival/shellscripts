#!/usr/bin/env bash
set -Eeuo pipefail

# Chisimba PHP 8 moderniser rule
# Author: Derek Keats
#
# conditionType::init() overrides decisionTableBase::init($tableName = null,
# $pearDb = null, $errorCallback = 'globalPearErrorCallback').
# PHP 8 requires a compatible child declaration. The method body remains
# unchanged.

if [[ "$#" -ne 1 ]]; then
    echo "Usage: $0 <assembled-chisimba-root>" >&2
    exit 2
fi

TARGET="$1/core_modules/decisiontable/classes/conditiontype_class_inc.php"
[[ -f "$TARGET" ]] || exit 0

python3 - "$TARGET" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_bytes().decode("latin-1")

good = re.compile(
    r'function\s+init\s*\(\s*\$tableName\s*=\s*(?:null|NULL)\s*,\s*'
    r'\$pearDb\s*=\s*(?:null|NULL)\s*,\s*'
    r'\$errorCallback\s*=\s*[\'"]globalPearErrorCallback[\'"]\s*\)',
    re.I,
)
bad = re.compile(r'(function\s+init\s*)\(\s*\)', re.I)

if good.search(text):
    print(f"ALREADY_OK {path}")
else:
    matches = list(bad.finditer(text))
    if len(matches) != 1:
        raise SystemExit(
            f"ERROR: expected exactly one zero-argument init declaration "
            f"in {path}; found {len(matches)}"
        )

    text = bad.sub(
        r"\1($tableName = null, $pearDb = null, "
        r"$errorCallback = 'globalPearErrorCallback')",
        text,
        count=1
    )
    path.write_bytes(text.encode("latin-1"))
    print(f"PATCHED {path}")
PY

php -l "$TARGET"
