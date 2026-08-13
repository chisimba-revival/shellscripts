#!/usr/bin/env bash
set -Eeuo pipefail

# Resume the first Kenga Learn IP deployment after the Nginx password-file
# permission prevented the final HTTP verification.

server=derek@104.248.35.30
downloads=/home/derek/Downloads
stamp=$(date +%Y%m%d-%H%M%S)
report="$downloads/killme-kengalearn-ip-auth-repair-${stamp}.txt"

mkdir -p "$downloads"
touch "$report"
chmod 600 "$report"
exec > >(tee -a "$report") 2>&1

echo "Kenga Learn IP access repair"
echo "Started: $(date --iso-8601=seconds)"
echo

[[ $(id -un) == derek ]] || {
    echo "ERROR: run this script as Derek on the desktop" >&2
    exit 1
}

ssh -o BatchMode=yes -o ConnectTimeout=10 "$server" bash -s <<'REMOTE'
set -Eeuo pipefail

base=/srv/kengalearn
deploy="$base/app/deploy"
env_file="$base/shared/secrets/production.env"
password_file="$deploy/nginx/htpasswd"

[[ -f "$deploy/compose.yml" ]] || {
    echo "ERROR: production Compose file is missing" >&2
    exit 1
}
[[ -f "$env_file" ]] || {
    echo "ERROR: production environment file is missing" >&2
    exit 1
}
[[ -f "$password_file" ]] || {
    echo "ERROR: Nginx password file is missing" >&2
    exit 1
}

chmod 644 "$password_file"

set -a
# shellcheck disable=SC1090
source "$env_file"
set +a

cd "$deploy"
docker compose --env-file "$env_file" -f compose.yml restart nginx

for attempt in $(seq 1 15)
do
    if curl --insecure --fail --silent --output /dev/null \
        --user "derek:$KENGALEARN_IP_ACCESS_PASSWORD" \
        https://127.0.0.1/; then
        break
    fi
    if [[ $attempt -eq 15 ]]; then
        docker compose --env-file "$env_file" -f compose.yml ps
        docker compose --env-file "$env_file" -f compose.yml logs --tail=80 nginx web
        echo "ERROR: HTTPS verification still fails" >&2
        exit 1
    fi
    sleep 2
done

echo "PASS: authenticated HTTPS responded at the site root"
echo "CHISIMBA_URL=https://104.248.35.30/"
echo "TEMPORARY_ACCESS_USER=derek"
echo "TEMPORARY_ACCESS_PASSWORD=$KENGALEARN_IP_ACCESS_PASSWORD"
echo "INSTALLER_DATABASE_HOST=db"
echo "INSTALLER_DATABASE_NAME=$MARIADB_DATABASE"
echo "INSTALLER_DATABASE_USER=$MARIADB_USER"
echo "INSTALLER_DATABASE_PASSWORD=$MARIADB_PASSWORD"
echo
docker compose --env-file "$env_file" -f compose.yml ps
REMOTE

echo
echo "KENGALEARN_IP_AUTH_REPAIR=PASS"
echo "Report: $report"
