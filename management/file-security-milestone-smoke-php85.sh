#!/usr/bin/env bash
set -uo pipefail

BASE="/run/media/derek/main/chisimba-revival"
FRAMEWORK="$BASE/framework"
MODULES="$BASE/modules"
PRIVATE="$BASE/private-storage/php85/filemanager"
FM_CONTROLLER="$FRAMEWORK/app/core_modules/filemanager/controller.php"
FM_FOLDER="$FRAMEWORK/app/core_modules/filemanager/classes/dbfolder_class_inc.php"
FM_REGISTER="$FRAMEWORK/app/core_modules/filemanager/register.conf"
ASSIGN_CTRL="$MODULES/assignment/controller.php"
ASSIGN_SUBMIT="$MODULES/assignment/classes/dbassignmentsubmit_class_inc.php"
LOG="/home/derek/Downloads/file-security-milestone-smoke-$(date +%Y%m%d-%H%M%S).log"

exec > >(tee "$LOG") 2>&1

PASS=0
FAIL=0
WARN=0

pass() { PASS=$((PASS+1)); printf 'PASS  %s\n' "$*"; }
fail() { FAIL=$((FAIL+1)); printf 'FAIL  %s\n' "$*"; }
warn() { WARN=$((WARN+1)); printf 'WARN  %s\n' "$*"; }

contains() {
    local file="$1" pattern="$2"
    grep -Fq -- "$pattern" "$file"
}

function_body_has() {
    local file="$1" function="$2" pattern="$3"
    python3 - "$file" "$function" "$pattern" <<'PY'
import re, sys
path, fn, pattern = sys.argv[1:4]
text = open(path, encoding='utf-8', errors='replace').read()
m = re.search(r'function\s+' + re.escape(fn) + r'\s*\([^)]*\)\s*\{', text)
if not m:
    sys.exit(2)
i = m.end()
depth = 1
while i < len(text) and depth:
    if text[i] == '{':
        depth += 1
    elif text[i] == '}':
        depth -= 1
    i += 1
body = text[m.end():i-1]
sys.exit(0 if pattern in body else 1)
PY
}

echo "== CHISIMBA FILE SECURITY MILESTONE SMOKE =="
date
echo

echo "== A. PRIVATE STORAGE INFRASTRUCTURE =="

if docker ps --format '{{.Names}}' | grep -qx chisimba-php85-web; then
    pass "PHP 8.5 web container is running"
else
    fail "PHP 8.5 web container is not running"
fi

if docker inspect chisimba-php85-web \
    --format '{{range .Mounts}}{{println .Destination}}{{end}}' 2>/dev/null \
    | grep -qx '/var/data/filemanager'; then
    pass "private store is mounted at /var/data/filemanager"
else
    fail "private store mount missing"
fi

if docker exec chisimba-php85-web sh -lc \
    'test -d /var/data/filemanager && test -w /var/data/filemanager' 2>/dev/null; then
    pass "private store is writable in PHP container"
else
    fail "private store is not writable"
fi

if contains "$FM_REGISTER" 'CONFIG: SECUREFODLER|/var/data/filemanager/'; then
    pass "File Manager SECUREFODLER points to private store"
else
    fail "File Manager SECUREFODLER does not point to private store"
fi

echo
echo "== B. PUBLIC VS PRIVATE URL BOUNDARY =="

TOKEN="fmsec-$(date +%s)-$$"
PUBLIC_REL="smoke-security/$TOKEN-public.txt"
PRIVATE_REL="smoke-security/$TOKEN-private.txt"

docker exec -u www-data chisimba-php85-web sh -lc \
    "mkdir -p /var/www/html/ch/usrfiles/smoke-security /var/data/filemanager/smoke-security &&
     printf 'public-%s\n' '$TOKEN' > '/var/www/html/ch/usrfiles/$PUBLIC_REL' &&
     printf 'private-%s\n' '$TOKEN' > '/var/data/filemanager/$PRIVATE_REL'" >/dev/null 2>&1

public_code="$(curl -k -sS -o /tmp/chisimba-public-smoke.$$ -w '%{http_code}' \
    "https://chisimba.test:8445/ch/usrfiles/$PUBLIC_REL" || true)"
if [ "$public_code" = "200" ] && grep -Fq "public-$TOKEN" /tmp/chisimba-public-smoke.$$; then
    pass "public usrfiles asset is directly web-addressable"
else
    fail "public usrfiles control asset was not served as expected (HTTP $public_code)"
fi
rm -f /tmp/chisimba-public-smoke.$$

private_code="$(curl -k -sS -o /tmp/chisimba-private-smoke.$$ -w '%{http_code}' \
    "https://chisimba.test:8445/ch/usrfiles/$PRIVATE_REL" || true)"
if [ "$private_code" = "403" ] || [ "$private_code" = "404" ]; then
    pass "private-store object is not reachable through usrfiles URL"
else
    fail "private-store object leaked through URL boundary (HTTP $private_code)"
fi
rm -f /tmp/chisimba-private-smoke.$$

docker exec chisimba-php85-web rm -f \
    "/var/www/html/ch/usrfiles/$PUBLIC_REL" \
    "/var/data/filemanager/$PRIVATE_REL" >/dev/null 2>&1 || true
docker exec chisimba-php85-web sh -lc \
    'rmdir /var/www/html/ch/usrfiles/smoke-security /var/data/filemanager/smoke-security 2>/dev/null || true' \
    >/dev/null 2>&1 || true

echo
echo "== C. COURSE AUTHOR WRITE POLICY =="

if contains "$FM_FOLDER" "isContextLecturer"; then
    pass "course-folder write policy is tied to contextual author role"
else
    fail "course-folder write policy does not reference contextual author role"
fi

if contains "$FM_FOLDER" "checkPermissionUploadFolder"; then
    pass "central course/user folder write-policy method exists"
else
    fail "central folder write-policy method missing"
fi

# Critical mutation actions must enforce the central folder policy server-side.
# UI hiding is not an authorization boundary.
for fn in __upload __createfolder __renamefolder __setfolderaccess __setfileaccess __setfilevisibility __setfolderalerts; do
    if function_body_has "$FM_CONTROLLER" "$fn" "checkPermissionUploadFolder" >/dev/null 2>&1 \
       || function_body_has "$FM_CONTROLLER" "$fn" "canManageFolder" >/dev/null 2>&1; then
        pass "$fn enforces folder-management authorization server-side"
    else
        fail "$fn lacks an explicit server-side folder-management authorization guard"
    fi
done

echo
echo "== D. ASSIGNMENT PROTECTED SUBMISSION PATH =="

if contains "$ASSIGN_CTRL" "uploadAssignmentIntake"; then
    pass "Assignment direct upload uses File Manager protected intake"
else
    fail "Assignment direct upload bypasses protected intake"
fi

if contains "$ASSIGN_SUBMIT" "/assignment/course-submissions/"; then
    pass "Assignment canonical submission copy uses private course-submissions path"
else
    fail "Assignment canonical submission copy is not using private course-submissions path"
fi

if contains "$ASSIGN_CTRL" "function __downloadfile" \
   && contains "$ASSIGN_CTRL" "submission['userid']"; then
    pass "Assignment download path contains submission-owner authorization logic"
else
    fail "Assignment download path lacks submission-owner authorization evidence"
fi

echo
echo "== E. LEGACY WEB-ROOT ASSESSMENT PATHS =="

legacy_hits="$(
    grep -RniE \
      'usrfiles/assignment|contentBasePath[^;]*(assignment/submissions|assignment.?/.*submissions)' \
      "$MODULES/assignment" --include='*.php' 2>/dev/null || true
)"

if [ -z "$legacy_hits" ]; then
    pass "no Assignment submission/export code targets the web-root content store"
else
    fail "legacy Assignment web-root submission/export paths still exist"
    printf '%s\n' "$legacy_hits" | head -n 30
fi

echo
echo "== F. PROTECTED STORE MUST NOT BE INSIDE WEB ROOT =="

webroot="$(docker exec chisimba-php85-web sh -lc 'readlink -f /var/www/html/ch' 2>/dev/null || true)"
vault="$(docker exec chisimba-php85-web sh -lc 'readlink -f /var/data/filemanager' 2>/dev/null || true)"
case "$vault" in
    "$webroot"/*)
        fail "private store resolves inside the web root"
        ;;
    *)
        pass "private store resolves outside the web root"
        ;;
esac

echo
echo "== RESULT =="
echo "PASS: $PASS"
echo "FAIL: $FAIL"
echo "WARN: $WARN"
echo "Log: $LOG"

if [ "$FAIL" -ne 0 ]; then
    echo
    echo "MILESTONE NOT YET CLOSED"
    exit 1
fi

echo
echo "MILESTONE SMOKE PASSED"
exit 0
