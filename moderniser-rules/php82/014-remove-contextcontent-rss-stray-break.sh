#!/usr/bin/env bash
set -Eeuo pipefail

# Chisimba PHP 8 moderniser rule
# Author: Derek Keats
#
# The contextcontent RSS action ends by echoing the generated feed and then
# executing a legacy break statement outside any loop or switch. PHP 8 rejects
# that statement during parsing. Replace it with an explicit method return,
# preserving the intended terminal control flow.

if [[ "$#" -ne 1 ]]; then
    echo "Usage: $0 <assembled-chisimba-root>" >&2
    exit 2
fi

TARGET="$1/packages/contextcontent/controller.php"
[[ -f "$TARGET" ]] || exit 0

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_bytes().decode("latin-1")

old = """        echo htmlentities($feed);
        break;
    }"""

new = """        echo htmlentities($feed);
        return;
    }"""

if new in text:
    print(f"Already modernised: {path}")
elif old in text:
    count = text.count(old)
    if count != 1:
        raise SystemExit(
            f"ERROR: expected exactly one matching RSS block in {path}; found {count}"
        )
    path.write_bytes(text.replace(old, new, 1).encode("latin-1"))
    print(f"Modernised: {path}")
else:
    raise SystemExit(
        f"ERROR: expected contextcontent RSS block not found in {path}"
    )
PY
