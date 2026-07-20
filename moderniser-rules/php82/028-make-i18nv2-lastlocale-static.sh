#!/usr/bin/env bash
set -Eeuo pipefail

# Chisimba PHP 8 moderniser rule
# Author: Derek Keats
#
# I18Nv2_CommonList calls I18Nv2::lastLocale() statically. PHP 8 rejects
# static calls to methods not declared static, so explicitly declare the
# legacy utility method static.

if [[ "$#" -ne 1 ]]; then
    echo "Usage: $0 <assembled-chisimba-root>" >&2
    exit 2
fi

TARGET="$1/lib/pear/I18Nv2.php"
[[ -f "$TARGET" ]] || exit 0

python3 - "$TARGET" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_bytes().decode("latin-1")

good = re.compile(
    r'(?:public\s+)?static\s+function\s+&?\s*lastLocale\s*\(',
    re.I,
)
bad = re.compile(
    r'(?P<prefix>\n\s*)(?P<visibility>public\s+|protected\s+|private\s+)?'
    r'function\s+(?P<ref>&\s*)?lastLocale\s*\(',
    re.I,
)

if good.search(text):
    print(f"ALREADY_OK {path}")
else:
    matches = list(bad.finditer(text))
    if len(matches) != 1:
        raise SystemExit(
            f"ERROR: unexpected I18Nv2::lastLocale declaration in {path}"
        )

    def repl(match):
        prefix = match.group("prefix")
        visibility = match.group("visibility") or ""
        ref = match.group("ref") or ""
        return f"{prefix}{visibility}static function {ref}lastLocale("

    text = bad.sub(repl, text, count=1)
    path.write_bytes(text.encode("latin-1"))
    print(f"PATCHED {path}")
PY

php -l "$TARGET"
