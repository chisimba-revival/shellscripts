#!/usr/bin/env bash

# Stage a clean Chisimba PHP 8.5 release beside the retired public demo.
# This script deliberately does not alter Apache, TLS or DNS.
set -Eeuo pipefail

workspace=/run/media/derek/main/chisimba-revival
framework="$workspace/framework"
modules="$workspace/modules"
canvases="$workspace/canvases"
deployment="$workspace/shellscripts/chisimba-com-deployment"
server=hostingk@102.209.119.91
identity=/home/derek/.ssh/derek_rsa
stamp="$(date +%Y%m%d-%H%M%S)"
scratch="$(mktemp -d)"
bundle="$scratch/bundle"
release="$bundle/ch"

cleanup() { rm -rf -- "$scratch"; }
trap cleanup EXIT
fail() { echo "ERROR: $*" >&2; exit 1; }

for repository in "$framework" "$modules" "$canvases"; do
    [[ -d "$repository/.git" ]] || fail "Git repository not found: $repository"
    [[ "$(git -C "$repository" branch --show-current)" == main ]] \
        || fail "$repository must be on main"
    [[ -z "$(git -C "$repository" status --porcelain=v1)" ]] \
        || fail "$repository has uncommitted changes"
    git -C "$repository" fetch origin main
    [[ "$(git -C "$repository" rev-parse HEAD)" == \
       "$(git -C "$repository" rev-parse origin/main)" ]] \
        || fail "$repository does not exactly match origin/main"
done

framework_commit="$(git -C "$framework" rev-parse HEAD)"
modules_commit="$(git -C "$modules" rev-parse HEAD)"
canvases_commit="$(git -C "$canvases" rev-parse HEAD)"

mkdir -p "$release/packages" "$bundle/deploy/build"
git -C "$framework" archive "$framework_commit" app \
    | tar -x -C "$release" --strip-components=1
git -C "$modules" archive "$modules_commit" \
    | tar -x -C "$release/packages"

rm -f "$release/config/installdone.txt" "$release/tmpinstallfile"
mkdir -p "$release/config" "$release/usrfiles" "$release/user_images" \
    "$release/error_log" "$release/error_logs"

cp "$workspace/dev-environment/docker/php85/Dockerfile" \
    "$bundle/deploy/build/Dockerfile"
cp "$workspace/dev-environment/config/php/php85.ini" \
    "$bundle/deploy/build/php85.ini"
cp "$workspace/dev-environment/docker/php74/chisimba-runtime-errors.php" \
    "$bundle/deploy/build/chisimba-runtime-errors.php"
cp "$workspace/dev-environment/docker/php74/99-chisimba-runtime-errors.ini" \
    "$bundle/deploy/build/99-chisimba-runtime-errors.ini"
cp "$workspace/dev-environment/local-https/chisimba-forwarded-https.conf" \
    "$bundle/deploy/build/chisimba-forwarded-https.conf"
cp "$deployment/compose.yml" "$bundle/deploy/compose.yml"

sed -i \
    's#^include_path = "\.:/var/www/html/ch/lib/pear"$#include_path = ".:/var/www/html/lib/pear"#' \
    "$bundle/deploy/build/php85.ini"
sed -i \
    -e 's#COPY config/php/php85.ini#COPY php85.ini#' \
    -e 's#COPY docker/php74/chisimba-runtime-errors.php#COPY chisimba-runtime-errors.php#' \
    -e 's#COPY docker/php74/99-chisimba-runtime-errors.ini#COPY 99-chisimba-runtime-errors.ini#' \
    -e 's#COPY local-https/chisimba-forwarded-https.conf#COPY chisimba-forwarded-https.conf#' \
    -e 's#WORKDIR /var/www/html/ch#WORKDIR /var/www/html#' \
    "$bundle/deploy/build/Dockerfile"

cat > "$bundle/source-identity.txt" <<EOF
FRAMEWORK_COMMIT=$framework_commit
MODULES_COMMIT=$modules_commit
CANVASES_COMMIT=$canvases_commit
CREATED_AT=$(date --iso-8601=seconds)
EOF

tar -czf "$scratch/chisimba-com-stage.tar.gz" -C "$bundle" .
scp -i "$identity" "$scratch/chisimba-com-stage.tar.gz" \
    "$server:/tmp/chisimba-com-stage-$stamp.tar.gz"

ssh -i "$identity" "$server" bash -s -- "$stamp" \
    "/tmp/chisimba-com-stage-$stamp.tar.gz" <<'REMOTE'
set -Eeuo pipefail
stamp=$1
archive=$2
base=/srv/chisimba-com
release_root="$base/releases/release-git-$stamp"
release_ch="$release_root/ch"
deploy="$base/app/deploy"
secrets="$base/shared/secrets/production.env"

sudo mkdir -p "$release_root" "$deploy" \
    "$base/shared/config" "$base/shared/usrfiles" \
    "$base/shared/user_images" "$base/shared/error_log" \
    "$base/shared/error_logs" "$base/shared/filemanager" \
    "$base/shared/secrets"
sudo tar -xzf "$archive" -C "$release_root"
sudo cp -a "$release_root/deploy/." "$deploy/"

if [[ ! -f "$secrets" ]]; then
    root_password="$(openssl rand -hex 32)"
    app_password="$(openssl rand -hex 32)"
    sudo install -m 600 /dev/null "$secrets"
    sudo tee "$secrets" >/dev/null <<EOF
MARIADB_ROOT_PASSWORD=$root_password
MARIADB_DATABASE=chisimba
MARIADB_USER=chisimba
MARIADB_PASSWORD=$app_password
EOF
fi

sudo chown -R 33:33 "$base/shared/config" "$base/shared/usrfiles" \
    "$base/shared/user_images" "$base/shared/error_log" \
    "$base/shared/error_logs" "$base/shared/filemanager"
sudo ln -sfn "$release_ch" "$base/app/current.new"
sudo mv -Tf "$base/app/current.new" "$base/app/current"

cd "$deploy"
# A bind mount whose source is the `current` symlink is resolved when the
# container is created. Recreate the web container after switching releases;
# a plain `compose up` can otherwise continue serving the previous target
# while the release identity file reports the new commit.
sudo docker compose --env-file "$secrets" -f compose.yml up -d db
sudo docker compose --env-file "$secrets" -f compose.yml up -d --build \
    --no-deps --force-recreate web

for attempt in $(seq 1 30); do
    status="$(sudo docker inspect --format \
        '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' \
        chisimba-com-web-1 2>/dev/null || true)"
    [[ "$status" == healthy ]] && break
    sleep 3
done

[[ "$(sudo docker inspect --format '{{.State.Health.Status}}' \
    chisimba-com-web-1)" == healthy ]]
curl --fail --silent --show-error --output /dev/null http://127.0.0.1:8085/

sudo rm -f "$archive"
echo "STAGING=PASS"
echo "RELEASE=$release_ch"
cat "$release_root/source-identity.txt"
sudo docker compose --env-file "$secrets" -f compose.yml ps
REMOTE
