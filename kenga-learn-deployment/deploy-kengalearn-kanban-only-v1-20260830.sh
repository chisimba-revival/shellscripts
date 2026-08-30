#!/usr/bin/env bash
# Deploy only the committed Kanban module on top of the current KengaLearn release.
# The preceding immutable release remains available as the rollback target.
set -Eeuo pipefail

WORKSPACE=/run/media/derek/main/chisimba-revival
MODULES="$WORKSPACE/modules"
SERVER=derek@104.248.35.30
DOWNLOADS=/home/derek/Downloads
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$DOWNLOADS/kengalearn-kanban-only-$STAMP.txt"
SCRATCH="$(mktemp -d)"
KANBAN_ARCHIVE="$SCRATCH/kanban.tar.gz"
REMOTE_ARCHIVE="/srv/kengalearn/app/incoming/kanban-$STAMP.tar.gz"

cleanup() { rm -rf -- "$SCRATCH"; }
trap cleanup EXIT
mkdir -p "$DOWNLOADS"
exec > >(tee "$REPORT") 2>&1

say() { printf '\n===== %s =====\n' "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

[[ "$(id -un)" == derek ]] || fail "Run this script as derek, without sudo."
[[ -d "$MODULES/.git" ]] || fail "Modules Git repository not found."
[[ -z "$(git -C "$MODULES" status --porcelain=v1 -- kanban)" ]] \
    || fail "The Kanban directory has uncommitted changes."

KANBAN_COMMIT="$(git -C "$MODULES" rev-parse HEAD)"
KANBAN_TREE="$(git -C "$MODULES" rev-parse HEAD:kanban)"
KANBAN_VERSION="$(awk -F': ' '$1=="MODULE_VERSION"{print $2}' "$MODULES/kanban/register.conf")"
[[ "$KANBAN_VERSION" == 0.117 ]] || fail "Expected Kanban 0.117; found $KANBAN_VERSION."

say "Test the committed Kanban source"
php -l "$MODULES/kanban/controller.php" >/dev/null
php -l "$MODULES/kanban/templates/content/index_tpl.php" >/dev/null
php "$MODULES/kanban/tests/kanban_contract_test.php"
node --check "$MODULES/kanban/resources/kanban.js"

say "Create the Kanban-only Git archive"
git -C "$MODULES" archive --format=tar.gz --output="$KANBAN_ARCHIVE" "$KANBAN_COMMIT" kanban
KANBAN_SHA="$(sha256sum "$KANBAN_ARCHIVE" | awk '{print $1}')"
tar -tzf "$KANBAN_ARCHIVE" | grep -Ev '^kanban(/|$)' && fail "Archive contains files outside kanban."
printf 'KANBAN_COMMIT=%s\nKANBAN_TREE=%s\nKANBAN_VERSION=%s\nKANBAN_SHA256=%s\n' \
    "$KANBAN_COMMIT" "$KANBAN_TREE" "$KANBAN_VERSION" "$KANBAN_SHA"

say "Verify production boundaries"
ssh -o BatchMode=yes -o ConnectTimeout=15 "$SERVER" \
    'set -eu
     test "$(id -un)" = derek
     test -L /srv/kengalearn/app/current
     test -f /srv/kengalearn/app/deploy/compose.yml
     test -f /srv/kengalearn/shared/secrets/production.env
     test -d /srv/kengalearn/backups
     test -d "$(readlink -f /srv/kengalearn/app/current)/core_modules/security"
     test -d "$(readlink -f /srv/kengalearn/app/current)/core_modules/context"
     test -d "$(readlink -f /srv/kengalearn/app/current)/core_modules/contextgroups"
     test -d "$(readlink -f /srv/kengalearn/app/current)/core_modules/ui"
     docker info >/dev/null
     mkdir -p /srv/kengalearn/app/incoming'

scp "$KANBAN_ARCHIVE" "$SERVER:$REMOTE_ARCHIVE"

say "Create and switch to an isolated Kanban release"
ssh "$SERVER" bash -s -- \
    "$REMOTE_ARCHIVE" "$KANBAN_SHA" "$KANBAN_COMMIT" "$KANBAN_TREE" \
    "$KANBAN_VERSION" "$STAMP" <<'REMOTE'
set -Eeuo pipefail

ARCHIVE=$1
ARCHIVE_SHA=$2
KANBAN_COMMIT=$3
KANBAN_TREE=$4
KANBAN_VERSION=$5
STAMP=$6
BASE=/srv/kengalearn
DEPLOY_DIR="$BASE/app/deploy"
COMPOSE_FILE="$DEPLOY_DIR/compose.yml"
ENV_FILE="$BASE/shared/secrets/production.env"
CURRENT_LINK="$BASE/app/current"
PREVIOUS_RELEASE="$(readlink -f "$CURRENT_LINK")"
RELEASE_ROOT="$BASE/releases/release-kanban-$STAMP"
RELEASE_CH="$RELEASE_ROOT/ch"
BACKUP_DIR="$BASE/backups/kanban-$STAMP"
SWITCHED=0

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a
compose() { docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }

rollback() {
    status=$?
    trap - ERR
    echo "ERROR: Kanban-only deployment failed." >&2
    if [[ "$SWITCHED" == 1 ]]; then
        ln -sfn "$PREVIOUS_RELEASE" "$CURRENT_LINK.rollback"
        mv -Tf "$CURRENT_LINK.rollback" "$CURRENT_LINK"
        compose up -d --no-deps --force-recreate web </dev/null || true
    fi
    rm -f -- "$ARCHIVE"
    rm -rf -- "$RELEASE_ROOT"
    echo "ROLLBACK_RELEASE=$PREVIOUS_RELEASE"
    exit "$status"
}
trap rollback ERR

[[ -d "$PREVIOUS_RELEASE" ]]
[[ ! -e "$RELEASE_ROOT" ]]
[[ "$(sha256sum "$ARCHIVE" | awk '{print $1}')" == "$ARCHIVE_SHA" ]]

echo "Backing up the production database before the module becomes available..."
mkdir -p "$BACKUP_DIR" "$RELEASE_CH"
compose exec -T db mariadb-dump -u"$MARIADB_USER" "-p$MARIADB_PASSWORD" \
    --single-transaction --quick --routines --triggers "$MARIADB_DATABASE" \
    </dev/null | gzip -9 > "$BACKUP_DIR/database.sql.gz"
gzip -t "$BACKUP_DIR/database.sql.gz"
sha256sum "$BACKUP_DIR/database.sql.gz" > "$BACKUP_DIR/SHA256SUMS"

echo "Cloning the known production release and adding only packages/kanban..."
cp -a --reflink=auto "$PREVIOUS_RELEASE/." "$RELEASE_CH/"
rm -rf -- "$RELEASE_CH/packages/kanban"
tar -xzf "$ARCHIVE" -C "$RELEASE_CH/packages"
rm -f -- "$ARCHIVE"

printf '%s\n' \
    "DEPLOYMENT_POLICY=production-release-plus-kanban-only" \
    "PREVIOUS_RELEASE=$PREVIOUS_RELEASE" \
    "KANBAN_COMMIT=$KANBAN_COMMIT" \
    "KANBAN_TREE=$KANBAN_TREE" \
    "KANBAN_VERSION=$KANBAN_VERSION" \
    "KANBAN_ARCHIVE_SHA256=$ARCHIVE_SHA" \
    > "$RELEASE_ROOT/source-identity.txt"

[[ -f "$RELEASE_CH/packages/kanban/register.conf" ]]
[[ "$(awk -F': ' '$1=="MODULE_VERSION"{print $2}' "$RELEASE_CH/packages/kanban/register.conf")" == "$KANBAN_VERSION" ]]
for dependency in security context contextgroups ui; do
    [[ -d "$RELEASE_CH/core_modules/$dependency" ]]
done

web_image="$(docker inspect --format '{{.Config.Image}}' kengalearn-production-web-1)"
run_release_php() {
    docker run --rm --entrypoint php -v "$RELEASE_CH:/var/www/html:ro" "$web_image" "$@"
}
run_release_php -l /var/www/html/packages/kanban/controller.php >/dev/null
run_release_php -l /var/www/html/packages/kanban/templates/content/index_tpl.php >/dev/null
run_release_php /var/www/html/packages/kanban/tests/kanban_contract_test.php

echo "Switching the application symlink atomically..."
ln -sfn "$RELEASE_CH" "$CURRENT_LINK.new"
mv -Tf "$CURRENT_LINK.new" "$CURRENT_LINK"
SWITCHED=1
compose up -d --no-deps --force-recreate web </dev/null

for attempt in $(seq 1 30); do
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        kengalearn-production-web-1 2>/dev/null || true)"
    [[ "$health" == healthy ]] && break
    [[ "$attempt" != 30 ]] || { compose logs --tail=120 web </dev/null; false; }
    sleep 3
done

home_status="$(curl --fail --silent --location --resolve kengalearn.com:443:127.0.0.1 \
    --output /dev/null --write-out '%{http_code}' https://kengalearn.com/)"
catalogue_status="$(curl --fail --silent --location --resolve kengalearn.com:443:127.0.0.1 \
    --output /dev/null --write-out '%{http_code}' \
    'https://kengalearn.com/index.php?module=context&action=catalogue')"
[[ "$home_status" == 200 && "$catalogue_status" == 200 ]]
[[ "$(readlink -f "$CURRENT_LINK")" == "$RELEASE_CH" ]]

trap - ERR
echo "DEPLOYMENT=PASS"
echo "CURRENT_RELEASE=$RELEASE_CH"
echo "PREVIOUS_RELEASE=$PREVIOUS_RELEASE"
echo "BACKUP_DIR=$BACKUP_DIR"
echo "KANBAN_VERSION=$KANBAN_VERSION"
echo "HOME_HTTP=$home_status"
echo "CATALOGUE_HTTP=$catalogue_status"
compose ps
REMOTE

say "Verify through public DNS"
EXTERNAL_HOME="$(curl --fail --silent --location --max-time 30 \
    --output /dev/null --write-out '%{http_code}' https://kengalearn.com/)"
EXTERNAL_CATALOGUE="$(curl --fail --silent --location --max-time 30 \
    --output /dev/null --write-out '%{http_code}' \
    'https://kengalearn.com/index.php?module=context&action=catalogue')"
[[ "$EXTERNAL_HOME" == 200 && "$EXTERNAL_CATALOGUE" == 200 ]] \
    || fail "External verification failed: home=$EXTERNAL_HOME catalogue=$EXTERNAL_CATALOGUE"

say "Complete"
echo "KENGALEARN_KANBAN_ONLY_DEPLOY=PASS"
echo "KANBAN_VERSION=$KANBAN_VERSION"
echo "EXTERNAL_HOME_HTTP=$EXTERNAL_HOME"
echo "EXTERNAL_CATALOGUE_HTTP=$EXTERNAL_CATALOGUE"
echo "REPORT=$REPORT"
