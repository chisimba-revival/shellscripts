#!/usr/bin/env bash
set -Eeuo pipefail

# Chisimba PHP 8 moderniser rule
# Author: Derek Keats
#
# conditionType::update() ultimately overrides
# dbTable::update($pkfield, $pkvalue, $fields, $tablename = '').
#
# The legacy child method is invoked without arguments. Accept the complete
# parent parameter list as optional compatibility arguments while preserving
# the existing method implementation.

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
    r'function\s+update\s*\(\s*'
    r'\$pkfield\s*=\s*(?:null|NULL)\s*,\s*'
    r'\$pkvalue\s*=\s*(?:null|NULL)\s*,\s*'
    r'\$fields\s*=\s*(?:null|NULL)\s*,\s*'
    r'\$tablename\s*=\s*[\'"]{2}\s*\)',
    re.I,
)
bad = re.compile(r'(function\s+update\s*)\(\s*\)', re.I)

if good.search(text):
    print(f"ALREADY_OK {path}")
else:
    matches = list(bad.finditer(text))
    if len(matches) != 1:
        raise SystemExit(
            f"ERROR: unexpected conditionType::update signature in {path}"
        )

    text = bad.sub(
        r"\1($pkfield = null, $pkvalue = null, "
        r"$fields = null, $tablename = '')",
        text,
        count=1
    )
    path.write_bytes(text.encode("latin-1"))
    print(f"PATCHED {path}")
PY

php -l "$TARGET"
