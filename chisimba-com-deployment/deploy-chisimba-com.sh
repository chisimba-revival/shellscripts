#!/usr/bin/env bash
# Deploy Chisimba.com from complete, clean Git snapshots with backup and rollback.
set -Eeuo pipefail

WORKSPACE=/run/media/derek/main/chisimba-revival
FRAMEWORK="$WORKSPACE/framework"
MODULES="$WORKSPACE/modules"
CANVASES="$WORKSPACE/canvases"
DEPLOYMENT="$WORKSPACE/shellscripts/chisimba-com-deployment"
SERVER=hostingk@102.209.119.91
IDENTITY=/home/derek/.ssh/derek_rsa
STAMP="$(date +%Y%m%d-%H%M%S)"
SCRATCH="$(mktemp -d)"
BUNDLE="$SCRATCH/bundle"
RELEASE="$BUNDLE/ch"
ARCHIVE="$SCRATCH/chisimba-com-$STAMP.tar.gz"

cleanup() { rm -rf -- "$SCRATCH"; }
trap cleanup EXIT
fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
say() { printf '\n===== %s =====\n' "$*"; }

for command in git ssh scp tar sha256sum curl; do
    command -v "$command" >/dev/null 2>&1 || fail "Missing command: $command"
done
[[ -r "$IDENTITY" ]] || fail "SSH key is not readable: $IDENTITY"
[[ -f "$DEPLOYMENT/compose.yml" ]] || fail "Chisimba.com Compose file is missing"

say "Check the Git sources"
for repository in "$FRAMEWORK" "$MODULES" "$CANVASES"; do
    [[ -d "$repository/.git" ]] || fail "Git repository not found: $repository"
    [[ "$(git -C "$repository" branch --show-current)" == main ]] || fail "$repository must be on main"
    [[ -z "$(git -C "$repository" status --porcelain=v1)" ]] || fail "$repository has uncommitted changes"
    git -C "$repository" fetch origin main
    [[ "$(git -C "$repository" rev-parse HEAD)" == "$(git -C "$repository" rev-parse origin/main)" ]] \
        || fail "$repository does not exactly match origin/main"
done

FRAMEWORK_COMMIT="$(git -C "$FRAMEWORK" rev-parse HEAD)"
MODULES_COMMIT="$(git -C "$MODULES" rev-parse HEAD)"
CANVASES_COMMIT="$(git -C "$CANVASES" rev-parse HEAD)"
printf 'Framework %s\nModules   %s\nCanvases  %s\n' "$FRAMEWORK_COMMIT" "$MODULES_COMMIT" "$CANVASES_COMMIT"

say "Build a clean release"
mkdir -p "$RELEASE/packages" "$BUNDLE/deploy/build"
git -C "$FRAMEWORK" archive "$FRAMEWORK_COMMIT" app | tar -x -C "$RELEASE" --strip-components=1
git -C "$MODULES" archive "$MODULES_COMMIT" | tar -x -C "$RELEASE/packages"
rm -f "$RELEASE/config/installdone.txt" "$RELEASE/tmpinstallfile"
mkdir -p "$RELEASE/config" "$RELEASE/usrfiles" "$RELEASE/user_images" "$RELEASE/error_log" "$RELEASE/error_logs"

[[ -f "$RELEASE/index.php" ]] || fail "The framework snapshot has no index.php"
[[ -f "$RELEASE/packages/discussion/controller.php" ]] || fail "The Discussion module is missing"
[[ -f "$RELEASE/skins/chisimba-reborn/templates/page/page_template.php" ]] || fail "The current skin is missing"
! grep -Eq '^BLOCK:[[:space:]]+context([|[:space:]]|$)' "$RELEASE/core_modules/context/register.conf" \
    || fail "The retired Context block has been registered again"

cp "$WORKSPACE/dev-environment/docker/php85/Dockerfile" "$BUNDLE/deploy/build/Dockerfile"
cp "$WORKSPACE/dev-environment/config/php/php85.ini" "$BUNDLE/deploy/build/php85.ini"
cp "$WORKSPACE/dev-environment/docker/php74/chisimba-runtime-errors.php" "$BUNDLE/deploy/build/chisimba-runtime-errors.php"
cp "$WORKSPACE/dev-environment/docker/php74/99-chisimba-runtime-errors.ini" "$BUNDLE/deploy/build/99-chisimba-runtime-errors.ini"
cp "$WORKSPACE/dev-environment/local-https/chisimba-forwarded-https.conf" "$BUNDLE/deploy/build/chisimba-forwarded-https.conf"
cp "$DEPLOYMENT/compose.yml" "$BUNDLE/deploy/compose.yml"

sed -i 's#^include_path = "\.:/var/www/html/ch/lib/pear"$#include_path = ".:/var/www/html/lib/pear"#' "$BUNDLE/deploy/build/php85.ini"
printf '\nsession.save_path = "/var/lib/php/sessions"\n' >> "$BUNDLE/deploy/build/php85.ini"
sed -i \
    -e 's#COPY config/php/php85.ini#COPY php85.ini#' \
    -e 's#COPY docker/php74/chisimba-runtime-errors.php#COPY chisimba-runtime-errors.php#' \
    -e 's#COPY docker/php74/99-chisimba-runtime-errors.ini#COPY 99-chisimba-runtime-errors.ini#' \
    -e 's#COPY local-https/chisimba-forwarded-https.conf#COPY chisimba-forwarded-https.conf#' \
    -e 's#WORKDIR /var/www/html/ch#WORKDIR /var/www/html#' \
    "$BUNDLE/deploy/build/Dockerfile"

cat > "$BUNDLE/source-identity.txt" <<EOF
FRAMEWORK_COMMIT=$FRAMEWORK_COMMIT
MODULES_COMMIT=$MODULES_COMMIT
CANVASES_COMMIT=$CANVASES_COMMIT
CREATED_AT=$(date --iso-8601=seconds)
EOF

tar -czf "$ARCHIVE" -C "$BUNDLE" .
ARCHIVE_SHA="$(sha256sum "$ARCHIVE" | awk '{print $1}')"
REMOTE_ARCHIVE="/tmp/chisimba-com-$STAMP.tar.gz"

say "Check the production host"
ssh -o BatchMode=yes -o ConnectTimeout=15 -i "$IDENTITY" "$SERVER" \
    'test -L /srv/chisimba-com/app/current && test -f /srv/chisimba-com/shared/secrets/production.env && sudo docker info >/dev/null && test "$(df -Pk /srv/chisimba-com | awk '\''NR==2 {print ($4 >= 1048576)}'\'')" = 1'
scp -i "$IDENTITY" "$ARCHIVE" "$SERVER:$REMOTE_ARCHIVE"

say "Back up, deploy and verify"
ssh -i "$IDENTITY" "$SERVER" sudo bash -s -- "$STAMP" "$REMOTE_ARCHIVE" "$ARCHIVE_SHA" <<'REMOTE'
set -Eeuo pipefail
STAMP=$1
ARCHIVE=$2
EXPECTED_SHA=$3
BASE=/srv/chisimba-com
RELEASE_ROOT="$BASE/releases/release-git-$STAMP"
RELEASE_CH="$RELEASE_ROOT/ch"
CURRENT="$BASE/app/current"
PREVIOUS="$(readlink -f "$CURRENT")"
DEPLOY="$BASE/app/deploy"
COMPOSE="$DEPLOY/compose.yml"
SECRETS="$BASE/shared/secrets/production.env"
BACKUP="$BASE/backups/git-deploy-$STAMP"
SWITCHED=0

set -a
source "$SECRETS"
set +a
compose() { docker compose --env-file "$SECRETS" -f "$COMPOSE" "$@"; }

rollback() {
    status=$?
    trap - ERR
    echo "ERROR: deployment failed; restoring the preceding release" >&2
    if [[ "$SWITCHED" == 1 && -d "$PREVIOUS" ]]; then
        ln -sfn "$PREVIOUS" "$CURRENT.rollback"
        mv -Tf "$CURRENT.rollback" "$CURRENT"
        compose up -d --no-deps --force-recreate web </dev/null || true
    fi
    rm -f -- "$ARCHIVE"
    rm -rf -- "$RELEASE_ROOT"
    rm -rf -- "$BACKUP"
    echo "RESTORED_RELEASE=$PREVIOUS"
    exit "$status"
}
trap rollback ERR

[[ "$(sha256sum "$ARCHIVE" | awk '{print $1}')" == "$EXPECTED_SHA" ]]
[[ -d "$PREVIOUS" && ! -e "$RELEASE_ROOT" ]]
mkdir -p "$BACKUP" "$RELEASE_ROOT" "$BASE/shared/sessions"

# The web container is disposable; authenticated PHP sessions are not. On the
# first deployment with the sessions mount, carry the active session files into
# shared storage before recreating the container.
old_session_path="$(docker exec chisimba-com-web-1 php -r 'echo ini_get("session.save_path");')"
old_session_path="${old_session_path##*;}"
[[ -n "$old_session_path" ]] || old_session_path=/tmp
if [[ "$old_session_path" != /var/lib/php/sessions ]] && docker exec chisimba-com-web-1 sh -lc "find '$old_session_path' -maxdepth 1 -type f -name 'sess_*' -print -quit | grep -q ."; then
    docker exec chisimba-com-web-1 sh -lc "cd '$old_session_path' && tar -cf - sess_*" | tar -xf - -C "$BASE/shared/sessions"
fi
chown -R 33:33 "$BASE/shared/sessions"

echo "Backing up the database and persistent files..."
compose exec -T db mariadb-dump -u"$MARIADB_USER" "-p$MARIADB_PASSWORD" \
    --single-transaction --quick --routines --triggers "$MARIADB_DATABASE" </dev/null | gzip -9 > "$BACKUP/database.sql.gz"
gzip -t "$BACKUP/database.sql.gz"
compose exec -T web tar -C /var/www/html -czf - config usrfiles user_images </dev/null > "$BACKUP/persistent-files.tar.gz"
tar -tzf "$BACKUP/persistent-files.tar.gz" >/dev/null
sha256sum "$BACKUP/database.sql.gz" "$BACKUP/persistent-files.tar.gz" > "$BACKUP/SHA256SUMS"

# These Context blocks were deliberately retired with their ExtJS browser.
# Remove stale catalogue rows before the new code can try to instantiate them.
compose exec -T db mariadb -u"$MARIADB_USER" "-p$MARIADB_PASSWORD" "$MARIADB_DATABASE" \
    -e "DELETE FROM tbl_module_blocks WHERE moduleid='context' AND blockname IN ('context','browsecontext');" </dev/null

tar -xzf "$ARCHIVE" -C "$RELEASE_ROOT"
rm -f -- "$ARCHIVE"
[[ -f "$RELEASE_CH/index.php" ]]
[[ -f "$RELEASE_CH/packages/discussion/controller.php" ]]
! grep -Eq '^BLOCK:[[:space:]]+context([|[:space:]]|$)' "$RELEASE_CH/core_modules/context/register.conf"

cp -a "$RELEASE_ROOT/deploy/." "$DEPLOY/"
web_image="$(docker inspect --format '{{.Config.Image}}' chisimba-com-web-1)"
run_php() { docker run --rm --entrypoint php -v "$RELEASE_CH:/var/www/html:ro" "$web_image" "$@"; }
echo "Checking the new PHP source..."
run_php -l /var/www/html/core_modules/context/controller.php
run_php -l /var/www/html/packages/discussion/controller.php
for test_file in "$RELEASE_CH"/packages/discussion/tests/*_test.php; do
    echo "Running Discussion check: $(basename "$test_file")"
    run_php "/var/www/html/packages/discussion/tests/$(basename "$test_file")"
done
echo "Running login failure check"
run_php /var/www/html/core_modules/security/tests/login_failure_prg_contract_test.php
echo "Running module-update data cleanup check"
run_php /var/www/html/core_modules/modulecatalogue/tests/delete_rows_patch_contract_test.php
run_php /var/www/html/core_modules/modulecatalogue/tests/batch_install_redirect_contract_test.php
run_php /var/www/html/core_modules/context/tests/legacy_context_browser_retirement_contract_test.php

ln -sfn "$RELEASE_CH" "$CURRENT.new"
mv -Tf "$CURRENT.new" "$CURRENT"
SWITCHED=1
compose up -d db </dev/null
compose up -d --build --no-deps --force-recreate web </dev/null

for attempt in $(seq 1 40); do
    health="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' chisimba-com-web-1 2>/dev/null || true)"
    [[ "$health" == healthy ]] && break
    [[ "$attempt" != 40 ]] || { compose logs --tail=150 web </dev/null; false; }
    sleep 3
done

internal_status="$(curl -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1:8085/)"
[[ "$internal_status" == 301 || "$internal_status" == 302 ]]
[[ "$(curl -fsS -L --resolve www.chisimba.com:443:127.0.0.1 -o /dev/null -w '%{http_code}' https://www.chisimba.com/)" == 200 ]]
[[ "$(readlink -f "$CURRENT")" == "$RELEASE_CH" ]]

mapfile -t releases < <(find "$BASE/releases" -mindepth 1 -maxdepth 1 -type d -name 'release-git-*' -printf '%T@ %p\n' | sort -nr | awk '{print $2}')
for index in "${!releases[@]}"; do
    (( index < 2 )) && continue
    [[ "${releases[$index]}" == "$RELEASE_ROOT" || "${releases[$index]}/ch" == "$PREVIOUS" ]] && continue
    rm -rf -- "${releases[$index]}"
done

# Persistent backups can be much larger than code releases. Keep only the
# backup created by this verified deployment.
while IFS= read -r old_backup; do
    [[ "$old_backup" == "$BACKUP" ]] && continue
    rm -rf -- "$old_backup"
done < <(find "$BASE/backups" -mindepth 1 -maxdepth 1 -type d \( -name 'git-deploy-*' -o -name 'git-update-*' \) -print)

trap - ERR
echo "DEPLOYMENT=PASS"
echo "CURRENT_RELEASE=$RELEASE_CH"
echo "PREVIOUS_RELEASE=$PREVIOUS"
echo "BACKUP=$BACKUP"
echo "INTERNAL_HTTP_REDIRECT=$internal_status"
cat "$RELEASE_ROOT/source-identity.txt"
compose ps
REMOTE

say "Verify through public DNS"
HOME_STATUS="$(curl -fsS -L --max-time 30 -o /dev/null -w '%{http_code}' https://www.chisimba.com/)"
[[ "$HOME_STATUS" == 200 ]] || fail "Public verification returned HTTP $HOME_STATUS"

say "Deployment complete"
echo "CHISIMBA_COM_DEPLOYMENT=PASS"
echo "PUBLIC_HOME_HTTP=$HOME_STATUS"
echo "The database backup and the preceding release were retained for rollback."
