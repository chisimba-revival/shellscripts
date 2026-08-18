#!/usr/bin/env bash
# Deploy KengaLearn from complete, clean Git snapshots.
# Application code is never inherited from the previous production release.
set -Eeuo pipefail

WORKSPACE=/run/media/derek/main/chisimba-revival
FRAMEWORK="$WORKSPACE/framework"
MODULES="$WORKSPACE/modules"
CANVASES="$WORKSPACE/canvases"
LOCAL_COMPOSE="$WORKSPACE/dev-environment/compose/php85.yml"
SERVER=derek@104.248.35.30
DOWNLOADS=/home/derek/Downloads
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$DOWNLOADS/kengalearn-exact-git-deploy-$STAMP.txt"
SCRATCH="$(mktemp -d)"
STAGE="$SCRATCH/ch"
FRAMEWORK_ARCHIVE="$SCRATCH/framework.tar.gz"
MODULES_ARCHIVE="$SCRATCH/modules.tar.gz"
CANVASES_ARCHIVE="$SCRATCH/canvases.tar.gz"

cleanup() { rm -rf -- "$SCRATCH"; }
trap cleanup EXIT
mkdir -p "$DOWNLOADS"
exec > >(tee "$REPORT") 2>&1

say() { printf '\n===== %s =====\n' "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }

[[ "$(id -un)" == derek ]] || fail "Run this script as derek, without sudo."
for repository in "$FRAMEWORK" "$MODULES" "$CANVASES"; do
    [[ -d "$repository/.git" ]] || fail "Git repository not found: $repository"
done
[[ -f "$LOCAL_COMPOSE" ]] || fail "PHP 8.5 Compose file not found: $LOCAL_COMPOSE"
for command in git docker curl ssh scp tar sha256sum gzip awk grep find sort; do
    command -v "$command" >/dev/null 2>&1 || fail "Missing command: $command"
done

say "Prove that Git is authoritative"
for repository in "$FRAMEWORK" "$MODULES" "$CANVASES"; do
    [[ "$(git -C "$repository" branch --show-current)" == main ]] \
        || fail "$repository must be on main."
    [[ -z "$(git -C "$repository" status --porcelain=v1)" ]] \
        || fail "$repository has uncommitted changes. Commit or discard them before deployment."
    git -C "$repository" fetch origin main
    [[ "$(git -C "$repository" rev-parse HEAD)" == "$(git -C "$repository" rev-parse origin/main)" ]] \
        || fail "$repository main does not exactly match origin/main."
done

FRAMEWORK_COMMIT="$(git -C "$FRAMEWORK" rev-parse HEAD)"
MODULES_COMMIT="$(git -C "$MODULES" rev-parse HEAD)"
CANVASES_COMMIT="$(git -C "$CANVASES" rev-parse HEAD)"
FRAMEWORK_TREE="$(git -C "$FRAMEWORK" rev-parse HEAD:app)"
MODULES_TREE="$(git -C "$MODULES" rev-parse 'HEAD^{tree}')"
CANVASES_TREE="$(git -C "$CANVASES" rev-parse 'HEAD^{tree}')"
printf 'FRAMEWORK_COMMIT=%s\nMODULES_COMMIT=%s\nCANVASES_COMMIT=%s\n' \
    "$FRAMEWORK_COMMIT" "$MODULES_COMMIT" "$CANVASES_COMMIT"
printf 'FRAMEWORK_APP_TREE=%s\nMODULES_TREE=%s\nCANVASES_TREE=%s\n' \
    "$FRAMEWORK_TREE" "$MODULES_TREE" "$CANVASES_TREE"

say "Create complete Git snapshots"
git -C "$FRAMEWORK" archive --format=tar.gz --output="$FRAMEWORK_ARCHIVE" \
    "$FRAMEWORK_COMMIT" app
git -C "$MODULES" archive --format=tar.gz --output="$MODULES_ARCHIVE" \
    "$MODULES_COMMIT"
git -C "$CANVASES" archive --format=tar.gz --output="$CANVASES_ARCHIVE" \
    "$CANVASES_COMMIT"

FRAMEWORK_SHA="$(sha256sum "$FRAMEWORK_ARCHIVE" | awk '{print $1}')"
MODULES_SHA="$(sha256sum "$MODULES_ARCHIVE" | awk '{print $1}')"
CANVASES_SHA="$(sha256sum "$CANVASES_ARCHIVE" | awk '{print $1}')"
printf 'FRAMEWORK_ARCHIVE_SHA256=%s\nMODULES_ARCHIVE_SHA256=%s\nCANVASES_ARCHIVE_SHA256=%s\n' \
    "$FRAMEWORK_SHA" "$MODULES_SHA" "$CANVASES_SHA"

say "Assemble an empty local release from those snapshots"
mkdir -p "$STAGE/packages" "$STAGE/canvases"
tar -xzf "$FRAMEWORK_ARCHIVE" -C "$STAGE" --strip-components=1
tar -xzf "$MODULES_ARCHIVE" -C "$STAGE/packages"
tar -xzf "$CANVASES_ARCHIVE" -C "$STAGE/canvases"

[[ -f "$STAGE/index.php" ]] || fail "Framework snapshot did not produce index.php."
[[ -f "$STAGE/core_modules/blocks/classes/blocks_class_inc.php" ]] \
    || fail "Framework Blocks source is missing."
[[ -f "$STAGE/packages/contentblocks/classes/contentblockbase_class_inc.php" ]] \
    || fail "Content blocks source is missing from modules Git."
[[ -f "$STAGE/skins/kenga-learn/canvases/_default/stylesheet.css" ]] \
    || fail "Kenga Learn canvas source is missing."
grep -Fq "'blockType' => 'none'" \
    "$STAGE/packages/contentblocks/classes/contentblockbase_class_inc.php"
grep -Fq 'CHISIMBA COMPLETE COMPONENT WRAPPER CONTRACT' \
    "$STAGE/skins/kenga-learn/canvases/_default/stylesheet.css"
echo "PASS: the clean snapshot contains the renderer and wrapper fix already committed to Git."

say "Run the committed source contracts against the clean snapshot"
web_container="$(docker compose -f "$LOCAL_COMPOSE" ps -q web)"
[[ -n "$web_container" ]] || fail "The local PHP 8.5 web container is not running."
WEB_IMAGE="$(docker inspect --format '{{.Config.Image}}' "$web_container")"
[[ -n "$WEB_IMAGE" ]] || fail "Could not identify the local PHP 8.5 image."

run_local_php() {
    docker run --rm --entrypoint php -v "$STAGE:/var/www/html/ch:ro" \
        "$WEB_IMAGE" "$@"
}

lint_files=(
    /var/www/html/ch/core_modules/blocks/classes/blocks_class_inc.php
    /var/www/html/ch/core_modules/context/classes/coursecatalogue_class_inc.php
    /var/www/html/ch/packages/contentblocks/classes/contentblockbase_class_inc.php
    /var/www/html/ch/packages/contentblocks/classes/dbcontentblocks_class_inc.php
    /var/www/html/ch/packages/contentblocks/controller.php
    /var/www/html/ch/skins/chisimba-reborn/templates/page/page_template.php
    /var/www/html/ch/skins/kenga-learn/templates/page/page_template.php
)
for file in "${lint_files[@]}"; do run_local_php -l "$file" >/dev/null; done

contract_tests=(
    /var/www/html/ch/core_modules/security/tests/login_failure_prg_contract_test.php
    /var/www/html/ch/packages/contentblocks/tests/contentblocks_contract_test.php
    /var/www/html/ch/packages/contentblocks/tests/legacy_postlogin_contract_test.php
    /var/www/html/ch/packages/contentblocks/tests/edit_render_contract_test.php
    /var/www/html/ch/core_modules/context/tests/course_catalogue_contract_test.php
    /var/www/html/ch/skins/chisimba-reborn/tests/canvas_complete_component_contract_test.php
)
for test_file in "${contract_tests[@]}"; do run_local_php "$test_file"; done
echo "PASS: clean Git snapshots pass the presentation-critical source contracts."

say "Verify production boundaries"
ssh -o BatchMode=yes -o ConnectTimeout=15 "$SERVER" \
    'set -eu
     test "$(id -un)" = derek
     test -L /srv/kengalearn/app/current
     test -f /srv/kengalearn/app/deploy/compose.yml
     test -f /srv/kengalearn/shared/secrets/production.env
     test -d /srv/kengalearn/shared/config
     test -d /srv/kengalearn/shared/usrfiles
     test -d /srv/kengalearn/shared/user_images
     docker info >/dev/null
     mkdir -p /srv/kengalearn/app/incoming
     echo "PASS: production keeps code and persistent data in separate locations."'

REMOTE_FRAMEWORK="/srv/kengalearn/app/incoming/framework-exact-$STAMP.tar.gz"
REMOTE_MODULES="/srv/kengalearn/app/incoming/modules-exact-$STAMP.tar.gz"
REMOTE_CANVASES="/srv/kengalearn/app/incoming/canvases-exact-$STAMP.tar.gz"
scp "$FRAMEWORK_ARCHIVE" "$SERVER:$REMOTE_FRAMEWORK"
scp "$MODULES_ARCHIVE" "$SERVER:$REMOTE_MODULES"
scp "$CANVASES_ARCHIVE" "$SERVER:$REMOTE_CANVASES"

say "Deploy a new release containing only the Git snapshots"
ssh "$SERVER" bash -s -- \
    "$REMOTE_FRAMEWORK" "$FRAMEWORK_SHA" \
    "$REMOTE_MODULES" "$MODULES_SHA" \
    "$REMOTE_CANVASES" "$CANVASES_SHA" \
    "$FRAMEWORK_COMMIT" "$MODULES_COMMIT" "$CANVASES_COMMIT" \
    "$FRAMEWORK_TREE" "$MODULES_TREE" "$CANVASES_TREE" "$STAMP" <<'REMOTE'
set -Eeuo pipefail

FRAMEWORK_ARCHIVE=$1
FRAMEWORK_SHA=$2
MODULES_ARCHIVE=$3
MODULES_SHA=$4
CANVASES_ARCHIVE=$5
CANVASES_SHA=$6
FRAMEWORK_COMMIT=$7
MODULES_COMMIT=$8
CANVASES_COMMIT=$9
FRAMEWORK_TREE=${10}
MODULES_TREE=${11}
CANVASES_TREE=${12}
STAMP=${13}

BASE=/srv/kengalearn
DEPLOY_DIR="$BASE/app/deploy"
COMPOSE_FILE="$DEPLOY_DIR/compose.yml"
ENV_FILE="$BASE/shared/secrets/production.env"
CURRENT_LINK="$BASE/app/current"
PREVIOUS_RELEASE="$(readlink -f "$CURRENT_LINK")"
RELEASE_ROOT="$BASE/releases/release-git-$STAMP"
RELEASE_CH="$RELEASE_ROOT/ch"
BACKUP_DIR="$BASE/backups/git-deploy-$STAMP"
SWITCHED=0

set -a
# shellcheck disable=SC1090
source "$ENV_FILE"
set +a

compose() { docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"; }

cleanup_archives() {
    rm -f -- "$FRAMEWORK_ARCHIVE" "$MODULES_ARCHIVE" "$CANVASES_ARCHIVE"
}

rollback() {
    status=$?
    trap - ERR
    echo "ERROR: clean Git deployment failed." >&2
    if [[ "$SWITCHED" == 1 ]]; then
        echo "Restoring previous application release: $PREVIOUS_RELEASE"
        ln -sfn "$PREVIOUS_RELEASE" "$CURRENT_LINK.rollback"
        mv -Tf "$CURRENT_LINK.rollback" "$CURRENT_LINK"
        compose up -d --no-deps --force-recreate web </dev/null || true
    fi
    cleanup_archives
    echo "ROLLBACK_RELEASE=$PREVIOUS_RELEASE"
    echo "FAILED_RELEASE=$RELEASE_CH"
    exit "$status"
}
trap rollback ERR

[[ "$(id -un)" == derek ]]
[[ -d "$PREVIOUS_RELEASE" ]]
[[ ! -e "$RELEASE_ROOT" ]]
[[ "$(sha256sum "$FRAMEWORK_ARCHIVE" | awk '{print $1}')" == "$FRAMEWORK_SHA" ]]
[[ "$(sha256sum "$MODULES_ARCHIVE" | awk '{print $1}')" == "$MODULES_SHA" ]]
[[ "$(sha256sum "$CANVASES_ARCHIVE" | awk '{print $1}')" == "$CANVASES_SHA" ]]

echo "Creating precautionary backups of persistent state..."
mkdir -p "$BACKUP_DIR" "$RELEASE_CH/packages" "$RELEASE_CH/canvases"
compose exec -T db mariadb-dump -u"$MARIADB_USER" "-p$MARIADB_PASSWORD" \
    --single-transaction --quick --routines --triggers "$MARIADB_DATABASE" \
    </dev/null | gzip -9 > "$BACKUP_DIR/database.sql.gz"
gzip -t "$BACKUP_DIR/database.sql.gz"
compose exec -T web tar -C /var/www/html -czf - config usrfiles user_images \
    </dev/null > "$BACKUP_DIR/persistent-files.tar.gz"
tar -tzf "$BACKUP_DIR/persistent-files.tar.gz" >/dev/null
sha256sum "$BACKUP_DIR/database.sql.gz" "$BACKUP_DIR/persistent-files.tar.gz" \
    > "$BACKUP_DIR/SHA256SUMS"

echo "Extracting into an empty application directory..."
tar -xzf "$FRAMEWORK_ARCHIVE" -C "$RELEASE_CH" --strip-components=1
tar -xzf "$MODULES_ARCHIVE" -C "$RELEASE_CH/packages"
tar -xzf "$CANVASES_ARCHIVE" -C "$RELEASE_CH/canvases"
cleanup_archives

# Bind-mount targets are structural only; their contents remain in /shared.
mkdir -p "$RELEASE_CH/config" "$RELEASE_CH/usrfiles" "$RELEASE_CH/user_images" \
    "$RELEASE_CH/error_log" "$RELEASE_CH/error_logs"

printf '%s\n' \
    "FRAMEWORK_COMMIT=$FRAMEWORK_COMMIT" \
    "FRAMEWORK_APP_TREE=$FRAMEWORK_TREE" \
    "MODULES_COMMIT=$MODULES_COMMIT" \
    "MODULES_TREE=$MODULES_TREE" \
    "CANVASES_COMMIT=$CANVASES_COMMIT" \
    "CANVASES_TREE=$CANVASES_TREE" \
    "FRAMEWORK_ARCHIVE_SHA256=$FRAMEWORK_SHA" \
    "MODULES_ARCHIVE_SHA256=$MODULES_SHA" \
    "CANVASES_ARCHIVE_SHA256=$CANVASES_SHA" \
    "PREVIOUS_RELEASE=$PREVIOUS_RELEASE" \
    > "$RELEASE_ROOT/source-identity.txt"

[[ -f "$RELEASE_CH/index.php" ]]
[[ -f "$RELEASE_CH/packages/contentblocks/classes/contentblockbase_class_inc.php" ]]
[[ -f "$RELEASE_CH/skins/kenga-learn/canvases/_default/stylesheet.css" ]]
grep -Fq "'blockType' => 'none'" \
    "$RELEASE_CH/packages/contentblocks/classes/contentblockbase_class_inc.php"
grep -Fq 'CHISIMBA COMPLETE COMPONENT WRAPPER CONTRACT' \
    "$RELEASE_CH/skins/kenga-learn/canvases/_default/stylesheet.css"
[[ ! -e "$RELEASE_CH/packages/contentblocks/classes/contentblockui_class_inc.php" ]]
[[ ! -e "$RELEASE_CH/packages/contentblocks/templates/content/editajax_tpl.php" ]]

echo "Testing the clean release before it can become current..."
web_image="$(docker inspect --format '{{.Config.Image}}' kengalearn-production-web-1)"
run_release_php() {
    docker run --rm --entrypoint php -v "$RELEASE_CH:/var/www/html:ro" \
        "$web_image" "$@"
}
production_tests=(
    /var/www/html/core_modules/security/tests/login_failure_prg_contract_test.php
    /var/www/html/packages/contentblocks/tests/contentblocks_contract_test.php
    /var/www/html/packages/contentblocks/tests/legacy_postlogin_contract_test.php
    /var/www/html/packages/contentblocks/tests/edit_render_contract_test.php
    /var/www/html/core_modules/context/tests/course_catalogue_contract_test.php
    /var/www/html/skins/chisimba-reborn/tests/canvas_complete_component_contract_test.php
)
for test_file in "${production_tests[@]}"; do run_release_php "$test_file"; done

echo "Atomically switching production to the clean Git release..."
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
echo "DEPLOYMENT_POLICY=complete-clean-git-snapshots"
echo "CURRENT_RELEASE=$RELEASE_CH"
echo "PREVIOUS_RELEASE=$PREVIOUS_RELEASE"
echo "BACKUP_DIR=$BACKUP_DIR"
echo "FRAMEWORK_COMMIT=$FRAMEWORK_COMMIT"
echo "MODULES_COMMIT=$MODULES_COMMIT"
echo "CANVASES_COMMIT=$CANVASES_COMMIT"
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
    || fail "External HTTP verification failed: home=$EXTERNAL_HOME catalogue=$EXTERNAL_CATALOGUE"

say "Complete"
echo "KENGALEARN_EXACT_GIT_DEPLOY=PASS"
echo "Production now contains complete Git snapshots, assembled in an empty release directory."
echo "No application code was copied from the preceding release."
echo "Persistent configuration, uploads, user images, logs and database data were retained separately."
echo "FRAMEWORK_COMMIT=$FRAMEWORK_COMMIT"
echo "MODULES_COMMIT=$MODULES_COMMIT"
echo "CANVASES_COMMIT=$CANVASES_COMMIT"
echo "EXTERNAL_HOME_HTTP=$EXTERNAL_HOME"
echo "EXTERNAL_CATALOGUE_HTTP=$EXTERNAL_CATALOGUE"
echo "REPORT=$REPORT"
