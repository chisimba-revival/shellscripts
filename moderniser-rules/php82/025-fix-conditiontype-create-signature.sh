#!/usr/bin/env bash
set -Eeuo pipefail

# Chisimba PHP 8 moderniser rule
# Author: Derek Keats
#
# conditionType::create($name, $className, $moduleName) overrides
# decisionTableBase::create($name).
#
# PHP 8 permits the child to accept additional parameters only when those
# parameters are optional. Preserve the three-argument legacy API while making
# the two child-specific arguments optional.

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
    r'function\s+create\s*\(\s*\$name\s*,\s*'
    r'\$className\s*=\s*(?:null|NULL)\s*,\s*'
    r'\$moduleName\s*=\s*(?:null|NULL)\s*\)',
    re.I,
)
bad = re.compile(
    r'function\s+create\s*\(\s*\$name\s*,\s*'
    r'\$className\s*,\s*\$moduleName\s*\)',
    re.I,
)

if good.search(text):
    print(f"ALREADY_OK {path}")
else:
    matches = list(bad.finditer(text))
    if len(matches) != 1:
        raise SystemExit(
            f"ERROR: unexpected conditionType::create signature in {path}"
        )

    text = bad.sub(
        "function create($name, $className = null, $moduleName = null)",
        text,
        count=1
    )
    path.write_bytes(text.encode("latin-1"))
    print(f"PATCHED {path}")
PY

php -l "$TARGET"
