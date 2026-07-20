#!/usr/bin/env bash
set -Eeuo pipefail

# Chisimba PHP 8 moderniser rule
# Author: Derek Keats
#
# contextcontent::isValid($action) overrides access::isValid($action,
# $default = true). PHP 8 enforces compatible child method signatures, so add
# the parent's optional parameter while preserving the existing implementation.

if [[ "$#" -ne 1 ]]; then
    echo "Usage: $0 <assembled-chisimba-root>" >&2
    exit 2
fi

TARGET="$1/packages/contextcontent/controller.php"
[[ -f "$TARGET" ]] || exit 0

python3 - "$TARGET" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_bytes().decode("latin-1")

new_pattern = re.compile(
    r'(?m)^(\s*(?:public\s+|protected\s+|private\s+)?function\s+isValid\s*)'
    r'\(\s*\$action\s*,\s*\$default\s*=\s*(?:true|TRUE)\s*\)'
)

old_pattern = re.compile(
    r'(?m)^(\s*(?:public\s+|protected\s+|private\s+)?function\s+isValid\s*)'
    r'\(\s*\$action\s*\)'
)

if new_pattern.search(text):
    print(f"Already modernised: {path}")
else:
    matches = list(old_pattern.finditer(text))
    if len(matches) != 1:
        raise SystemExit(
            f"ERROR: expected exactly one isValid($action) declaration in {path}; "
            f"found {len(matches)}"
        )
    text = old_pattern.sub(r'\1($action, $default = true)', text, count=1)
    path.write_bytes(text.encode("latin-1"))
    print(f"Modernised: {path}")
PY
