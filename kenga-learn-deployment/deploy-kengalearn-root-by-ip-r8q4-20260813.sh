#!/usr/bin/env bash
set -Eeuo pipefail

# Deploy a fresh Kenga Learn production release from Derek's current working
# tree to the prepared DigitalOcean host. Publicly trusted TLS is deferred;
# temporary encrypted and authenticated IP access protects the installer.

workspace=/run/media/derek/main/chisimba-revival
server_ip=104.248.35.30
server_user=derek
server="${server_user}@${server_ip}"
downloads=/home/derek/Downloads
stamp=$(date +%Y%m%d-%H%M%S)
report="${downloads}/killme-kengalearn-ip-deploy-${stamp}.txt"
release_id="release-${stamp}"
scratch=$(mktemp -d "${TMPDIR:-/tmp}/kengalearn-ip-deploy.XXXXXX")
bundle="${scratch}/${release_id}"
archive="${scratch}/${release_id}.tar.gz"

mkdir -p "$downloads"
chmod 700 "$scratch"
touch "$report"
chmod 600 "$report"
exec > >(tee -a "$report") 2>&1

cleanup()
{
    rm -rf -- "$scratch"
}
trap cleanup EXIT

fail()
{
    echo "ERROR: $*" >&2
    exit 1
}

require_file()
{
    [[ -f $1 ]] || fail "Required file missing: $1"
}

require_dir()
{
    [[ -d $1 ]] || fail "Required directory missing: $1"
}

echo "Kenga Learn production deployment by IP"
echo "Started: $(date --iso-8601=seconds)"
echo "Source: $workspace"
echo "Target: $server"
echo "Release: $release_id"
echo

[[ $(id -un) == derek ]] || fail "Run this script as Derek on the desktop"

for command in git rsync ssh scp tar sha256sum
do
    command -v "$command" >/dev/null || fail "Required command unavailable: $command"
done

require_dir "$workspace/framework/app"
require_dir "$workspace/modules"
require_dir "$workspace/canvases"
require_dir "$workspace/dev-environment"
require_file "$workspace/dev-environment/docker/php85/Dockerfile"
require_file "$workspace/dev-environment/config/php/php85.ini"
require_file "$workspace/dev-environment/docker/php74/chisimba-runtime-errors.php"
require_file "$workspace/dev-environment/docker/php74/99-chisimba-runtime-errors.ini"
require_file "$workspace/dev-environment/local-https/chisimba-forwarded-https.conf"

echo "=== SOURCE EVIDENCE ==="
for repository in framework modules canvases dev-environment
do
    repo_path="$workspace/$repository"
    require_dir "$repo_path/.git"
    branch=$(git -C "$repo_path" branch --show-current)
    commit=$(git -C "$repo_path" rev-parse HEAD)
    changes=$(git -C "$repo_path" status --porcelain=v1 | wc -l)
    printf '%-18s branch=%-16s commit=%s changes=%s\n' \
        "$repository" "$branch" "$commit" "$changes"
done
echo "PASS: source repositories and current working trees recorded"
echo

echo "=== SERVER PREFLIGHT ==="
ssh -o BatchMode=yes -o ConnectTimeout=10 "$server" \
    'set -eu
     test "$(id -un)" = derek
     test -d /srv/kengalearn/releases
     test -d /srv/kengalearn/shared/config
     docker info >/dev/null
     docker compose version >/dev/null
     echo "PASS: Derek SSH, production directories and Docker verified"'
echo

echo "=== ASSEMBLE RELEASE ==="
mkdir -p \
    "$bundle/ch/packages" \
    "$bundle/ch/canvases" \
    "$bundle/deploy/build" \
    "$bundle/deploy/nginx"

rsync -a --delete --exclude='.git' \
    "$workspace/framework/app/" "$bundle/ch/"
rsync -a --delete --exclude='.git' \
    "$workspace/modules/" "$bundle/ch/packages/"
rsync -a --delete --exclude='.git' \
    "$workspace/canvases/" "$bundle/ch/canvases/"

rm -f \
    "$bundle/ch/config/installdone.txt" \
    "$bundle/ch/tmpinstallfile"

mkdir -p \
    "$bundle/ch/config" \
    "$bundle/ch/usrfiles" \
    "$bundle/ch/user_images" \
    "$bundle/ch/error_log" \
    "$bundle/ch/error_logs"

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

# The repository Dockerfile paths are development-context paths. These four
# substitutions retain the audited image recipe while making this bundle its
# self-contained Docker build context.
sed -i \
    -e 's#COPY config/php/php85.ini#COPY php85.ini#' \
    -e 's#COPY docker/php74/chisimba-runtime-errors.php#COPY chisimba-runtime-errors.php#' \
    -e 's#COPY docker/php74/99-chisimba-runtime-errors.ini#COPY 99-chisimba-runtime-errors.ini#' \
    -e 's#COPY local-https/chisimba-forwarded-https.conf#COPY chisimba-forwarded-https.conf#' \
    -e 's#WORKDIR /var/www/html/ch#WORKDIR /var/www/html#' \
    "$bundle/deploy/build/Dockerfile"

cat > "$bundle/deploy/nginx/default.conf" <<'NGINX'
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl default_server;
    listen [::]:443 ssl default_server;
    server_name _;

    ssl_certificate /etc/nginx/certs/ip.crt;
    ssl_certificate_key /etc/nginx/certs/ip.key;
    ssl_protocols TLSv1.2 TLSv1.3;

    client_max_body_size 256m;

    location / {
        auth_basic "Kenga Learn installation";
        auth_basic_user_file /etc/nginx/auth/htpasswd;

        proxy_pass http://web:80;
        proxy_http_version 1.1;
        proxy_set_header Host $http_host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_set_header X-Forwarded-Host $host;
    }
}
NGINX

cat > "$bundle/deploy/compose.yml" <<'COMPOSE'
name: kengalearn-production

services:
  web:
    build:
      context: ./build
      dockerfile: Dockerfile
    image: kengalearn/chisimba-php85:8.5.4
    restart: unless-stopped
    volumes:
      - /srv/kengalearn/app/current:/var/www/html:ro
      - /srv/kengalearn/shared/config:/var/www/html/config
      - /srv/kengalearn/shared/usrfiles:/var/www/html/usrfiles
      - /srv/kengalearn/shared/user_images:/var/www/html/user_images
      - /srv/kengalearn/shared/error_log:/var/www/html/error_log
      - /srv/kengalearn/shared/error_logs:/var/www/html/error_logs
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "--fail", "--silent", "http://127.0.0.1/"]
      interval: 15s
      timeout: 5s
      retries: 12
      start_period: 30s
    networks:
      - internal

  nginx:
    image: nginx:1.31.3-alpine
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/default.conf:/etc/nginx/conf.d/default.conf:ro
      - ./nginx/certs:/etc/nginx/certs:ro
      - ./nginx/htpasswd:/etc/nginx/auth/htpasswd:ro
    depends_on:
      web:
        condition: service_healthy
    networks:
      - internal

  db:
    image: mariadb:10.11.18
    restart: unless-stopped
    environment:
      MARIADB_ROOT_PASSWORD: ${MARIADB_ROOT_PASSWORD:?required}
      MARIADB_DATABASE: ${MARIADB_DATABASE:?required}
      MARIADB_USER: ${MARIADB_USER:?required}
      MARIADB_PASSWORD: ${MARIADB_PASSWORD:?required}
    volumes:
      - database:/var/lib/mysql
    healthcheck:
      test: ["CMD-SHELL", "healthcheck.sh --connect --innodb_initialized"]
      interval: 10s
      timeout: 5s
      retries: 15
      start_period: 30s
    networks:
      - internal

volumes:
  database:

networks:
  internal:
    driver: bridge
COMPOSE

cat > "$bundle/deploy/install-release.sh" <<'REMOTE'
#!/usr/bin/env bash
set -Eeuo pipefail

release_id=${1:?release id required}
base=/srv/kengalearn
incoming="$base/app/incoming/$release_id"
release="$base/releases/$release_id"
deploy="$base/app/deploy"
env_file="$base/shared/secrets/production.env"

[[ $(id -un) == derek ]] || { echo "ERROR: run as Derek" >&2; exit 1; }
[[ -d "$incoming/ch" ]] || { echo "ERROR: incoming release missing" >&2; exit 1; }
[[ ! -e "$release" ]] || { echo "ERROR: release already exists" >&2; exit 1; }

mv "$incoming" "$release"
mkdir -p \
    "$base/shared/config" \
    "$base/shared/secrets" \
    "$base/shared/usrfiles" \
    "$base/shared/user_images" \
    "$base/shared/error_log" \
    "$base/shared/error_logs"

if [[ ! -f "$env_file" ]]; then
    umask 077
    db_root_password=$(openssl rand -hex 24)
    db_password=$(openssl rand -hex 24)
    ip_access_password=$(openssl rand -hex 12)
    cat > "$env_file" <<ENV
MARIADB_ROOT_PASSWORD=$db_root_password
MARIADB_DATABASE=chisimba
MARIADB_USER=chisimba
MARIADB_PASSWORD=$db_password
KENGALEARN_IP_ACCESS_PASSWORD=$ip_access_password
ENV
fi
chmod 600 "$env_file"
chmod 700 "$base/shared/secrets"

for path in config usrfiles user_images error_log error_logs
do
    source_path="$release/ch/$path"
    target_path="$base/shared/$path"
    if [[ -d "$source_path" ]]; then
        rsync -a --ignore-existing "$source_path/" "$target_path/"
    fi
    chmod 2770 "$target_path"
    setfacl -m u:33:rwx,d:u:33:rwx "$target_path"
done

rm -rf "$deploy"
mkdir -p "$deploy"
cp -a "$release/deploy/." "$deploy/"

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

mkdir -p "$deploy/nginx/certs"
openssl req -x509 -nodes -newkey rsa:2048 -days 30 \
    -keyout "$deploy/nginx/certs/ip.key" \
    -out "$deploy/nginx/certs/ip.crt" \
    -subj '/CN=104.248.35.30' \
    -addext 'subjectAltName=IP:104.248.35.30' \
    >/dev/null 2>&1
printf 'derek:%s\n' \
    "$(openssl passwd -apr1 "$KENGALEARN_IP_ACCESS_PASSWORD")" \
    > "$deploy/nginx/htpasswd"
chmod 600 \
    "$deploy/nginx/certs/ip.key"
chmod 644 "$deploy/nginx/htpasswd"

ln -sfn "$release/ch" "$base/app/current.new"
mv -Tf "$base/app/current.new" "$base/app/current"

cd "$deploy"
docker compose --env-file "$env_file" -f compose.yml build --pull web
docker compose --env-file "$env_file" -f compose.yml up -d

for attempt in $(seq 1 30)
do
    if curl --insecure --fail --silent --output /dev/null \
        --user "derek:$KENGALEARN_IP_ACCESS_PASSWORD" \
        https://127.0.0.1/; then
        break
    fi
    if [[ $attempt -eq 30 ]]; then
        docker compose --env-file "$env_file" -f compose.yml ps
        docker compose --env-file "$env_file" -f compose.yml logs --tail=100
        echo "ERROR: HTTP verification failed" >&2
        exit 1
    fi
    sleep 4
done

echo "PASS: production containers started and HTTP responded"
echo "CHISIMBA_URL=https://104.248.35.30/"
echo "TEMPORARY_ACCESS_USER=derek"
echo "TEMPORARY_ACCESS_PASSWORD=$KENGALEARN_IP_ACCESS_PASSWORD"
echo "INSTALLER_DATABASE_HOST=db"
echo "INSTALLER_DATABASE_NAME=$MARIADB_DATABASE"
echo "INSTALLER_DATABASE_USER=$MARIADB_USER"
echo "INSTALLER_DATABASE_PASSWORD=$MARIADB_PASSWORD"
echo "RELEASE=$release_id"
echo
docker compose --env-file "$env_file" -f compose.yml ps
REMOTE
chmod 750 "$bundle/deploy/install-release.sh"

find "$bundle/ch" -type f -print0 \
    | sort -z \
    | xargs -0 sha256sum > "$bundle/SHA256SUMS"
tar -C "$scratch" -czf "$archive" "$release_id"
archive_sha=$(sha256sum "$archive" | awk '{print $1}')
echo "Artifact: $(basename "$archive")"
echo "SHA256: $archive_sha"
echo "PASS: fresh runtime assembled from the current working tree"
echo

echo "=== TRANSFER AND START ==="
remote_archive="/srv/kengalearn/app/$(basename "$archive")"
scp "$archive" "$server:$remote_archive"
ssh "$server" bash -s -- "$remote_archive" "$release_id" "$archive_sha" <<'INSTALL'
set -Eeuo pipefail
archive=${1:?archive required}
release_id=${2:?release required}
expected_sha=${3:?checksum required}
base=/srv/kengalearn
incoming="$base/app/incoming/$release_id"

actual_sha=$(sha256sum "$archive" | awk '{print $1}')
[[ $actual_sha == "$expected_sha" ]] || {
    echo "ERROR: transferred artifact checksum mismatch" >&2
    exit 1
}

mkdir -p "$base/app/incoming"
[[ ! -e "$incoming" ]] || {
    echo "ERROR: incoming release path already exists: $incoming" >&2
    exit 1
}
tar -C "$base/app/incoming" -xzf "$archive"
rm -f "$archive"
"$incoming/deploy/install-release.sh" "$release_id"
INSTALL

echo
echo "=== RESULT ==="
echo "KENGALEARN_IP_DEPLOY=PASS"
echo "URL=https://${server_ip}/"
echo "Report: $report"
