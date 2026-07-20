#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "$#" -ne 1 ]]; then
    echo "Usage: $0 <assembled-chisimba-root>" >&2
    exit 2
fi

ROOT="$1"
COMMON="$ROOT/lib/pear/I18Nv2/CommonList.php"
DECORATED="$ROOT/lib/pear/I18Nv2/DecoratedList.php"

[[ -f "$COMMON" ]] || exit 0
[[ -f "$DECORATED" ]] || exit 0

python3 - "$COMMON" "$DECORATED" <<'PY'
from pathlib import Path
import re
import sys

common = Path(sys.argv[1])
decorated = Path(sys.argv[2])

def add_common(path):
    text = path.read_bytes().decode("latin-1")
    if re.search(r'function\s+__construct\s*\(', text, re.I):
        print(f"ALREADY_OK {path}")
        return

    pattern = re.compile(
        r'(\n\s*function\s+I18Nv2_CommonList\s*\((.*?)\)\s*\{)',
        re.I | re.S,
    )
    match = pattern.search(text)
    if not match:
        raise SystemExit(f"ERROR: legacy CommonList constructor not found in {path}")

    params = match.group(2).strip()
    names = re.findall(r'&?\$[A-Za-z_][A-Za-z0-9_]*', params)
    args = ", ".join(name.replace("&", "") for name in names)

    bridge = (
        "\n    /** PHP 8 constructor bridge. */\n"
        f"    function __construct({params})\n"
        "    {\n"
        f"        $this->I18Nv2_CommonList({args});\n"
        "    }\n\n"
    )
    text = pattern.sub(bridge + r'\1', text, count=1)
    path.write_bytes(text.encode("latin-1"))
    print(f"PATCHED {path}")

def add_decorated(path):
    text = path.read_bytes().decode("latin-1")
    if re.search(r'function\s+__construct\s*\(', text, re.I):
        print(f"ALREADY_OK {path}")
        return

    pattern = re.compile(
        r'(\n\s*function\s+I18Nv2_DecoratedList\s*\(\s*&\$list\s*\)\s*\{)',
        re.I,
    )
    if not pattern.search(text):
        raise SystemExit(f"ERROR: legacy DecoratedList constructor not found in {path}")

    bridge = (
        "\n    /** PHP 8 constructor bridge. */\n"
        "    function __construct(&$list)\n"
        "    {\n"
        "        $this->I18Nv2_DecoratedList($list);\n"
        "    }\n\n"
    )
    text = pattern.sub(bridge + r'\1', text, count=1)
    path.write_bytes(text.encode("latin-1"))
    print(f"PATCHED {path}")

add_common(common)
add_decorated(decorated)
PY

php -l "$COMMON"
php -l "$DECORATED"
