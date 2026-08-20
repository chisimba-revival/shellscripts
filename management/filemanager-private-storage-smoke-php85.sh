#!/usr/bin/env bash
set -euo pipefail

BASE="/run/media/derek/main/chisimba-revival"
DEVENV="$BASE/dev-environment"
COMPOSE="$DEVENV/compose/php85.yml"
PRIVATE_STORE="$BASE/private-storage/php85/filemanager"
LOG="/home/derek/Downloads/filemanager-private-storage-smoke-$(date +%Y%m%d-%H%M%S).log"
TOKEN="chisimba-private-smoke-$(date +%s)-$$"
REL="smoke/$TOKEN.txt"

exec > >(tee "$LOG") 2>&1

fail() {
    echo "FAIL: $*"
    exit 1
}

echo "== FILEMANAGER PRIVATE STORAGE SMOKE =="
echo

docker ps --format '{{.Names}}' | grep -qx 'chisimba-php85-web' \
    || fail "chisimba-php85-web is not running"

grep -Fq '../../private-storage/php85/filemanager:/var/data/filemanager' "$COMPOSE" \
    || fail "private storage bind mount is absent from php85.yml"

docker inspect chisimba-php85-web \
  --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}' \
  | grep -F -- '-> /var/data/filemanager' \
  || fail "/var/data/filemanager is not mounted in the web container"

docker exec chisimba-php85-web sh -lc \
  'test -d /var/data/filemanager && test -w /var/data/filemanager' \
  || fail "private storage is not writable in the web container"

docker exec -u www-data chisimba-php85-web sh -lc \
  "mkdir -p /var/data/filemanager/smoke && printf '%s\n' '$TOKEN' > '/var/data/filemanager/$REL'" \
  || fail "www-data cannot write a private file"

docker exec chisimba-php85-web test -f "/var/data/filemanager/$REL" \
  || fail "private marker was not created"

docker exec chisimba-php85-web test ! -e "/var/www/html/ch/usrfiles/$REL" \
  || fail "private marker unexpectedly exists under usrfiles"

# A private-store object must not be directly retrievable by the obvious
# usrfiles URL path.
code="$(curl -k -sS -o /dev/null -w '%{http_code}' \
  "https://chisimba.test:8445/ch/usrfiles/$REL" || true)"
case "$code" in
  404|403) ;;
  *) fail "private marker URL returned HTTP $code instead of 403/404" ;;
esac

# Prove the host-backed private store survives a web-container recreation.
cd "$DEVENV"
docker compose -f compose/php85.yml up -d --force-recreate web >/dev/null
docker compose -f compose/php85.yml up -d nginx >/dev/null

for _ in $(seq 1 20); do
    if docker exec chisimba-php85-web test -f "/var/data/filemanager/$REL" 2>/dev/null; then
        break
    fi
    sleep 1
done

docker exec chisimba-php85-web test -f "/var/data/filemanager/$REL" \
  || fail "private marker did not survive container recreation"

docker exec chisimba-php85-web rm -f "/var/data/filemanager/$REL"
docker exec chisimba-php85-web rmdir /var/data/filemanager/smoke 2>/dev/null || true

grep -Fq 'CONFIG: SECUREFODLER|/var/data/filemanager/' \
  "$BASE/framework/app/core_modules/filemanager/register.conf" \
  || fail "File Manager SECUREFODLER is not configured for /var/data/filemanager/"

echo
echo "PASS: private storage is outside the web root, writable by www-data,"
echo "      not directly URL-addressable, and persistent across container recreation."
echo
echo "NOTE: this smoke test proves storage infrastructure only."
echo "      Module-level authorization and legacy Assignment paths require separate tests."
echo "Log: $LOG"
