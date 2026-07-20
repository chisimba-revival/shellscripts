#!/usr/bin/env bash
set -euo pipefail

# Chisimba PHP 8 moderniser rule
# Author: Derek Keats
#
# Rename the contextcontent activity-stream database helper so that it no
# longer overrides ChisimbaObject::getSession() with an incompatible and
# semantically unrelated method signature.

if [[ "$#" -ne 1 ]]; then
    echo "Usage: $0 <assembled-chisimba-root>" >&2
    exit 2
fi

TARGET="$1/packages/contextcontent/classes/db_contextcontent_activitystreamer_class_inc.php"

[[ -f "$TARGET" ]] || exit 0

python3 - "$TARGET" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

old_doc = """    /**
     * Method to get all the records for a particular session
     *
     * @access public
     * @param string $sessionId Session Id
     * @return TRUE
     */
    public function getSession($sessionId) {"""

new_doc = """    /**
     * Determine whether activity-stream records exist for a session.
     *
     * This method was formerly named getSession(), which collided with the
     * ChisimbaObject session API on PHP 8. The distinct name preserves the
     * database-specific meaning and avoids overriding the framework method.
     *
     * @access public
     * @param string $sessionId Session identifier
     * @return bool TRUE when at least one matching record exists
     */
    public function hasSessionRecords($sessionId) {"""

if new_doc in text:
    print(f"Already modernised: {path}")
elif old_doc in text:
    path.write_text(text.replace(old_doc, new_doc, 1))
    print(f"Modernised: {path}")
else:
    raise SystemExit(f"Unexpected source shape; refusing to alter {path}")
PY
