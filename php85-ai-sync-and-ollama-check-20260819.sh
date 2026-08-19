#!/usr/bin/env bash
set -euo pipefail

BASE="/run/media/derek/main/chisimba-revival"
DOWNLOADS="/home/derek/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DOWNLOADS/php85-ai-sync-and-ollama-check-$STAMP.log"

exec > >(tee -a "$LOG") 2>&1

echo "=== Chisimba PHP 8.5 AI sync and Ollama check ==="
echo "Started: $(date -Is)"
echo "Log: $LOG"
echo

repos=(framework modules dev-environment shellscripts)

for repo in "${repos[@]}"; do
    path="$BASE/$repo"
    echo "=== PRE-WORK GATE: $repo ==="
    if [[ ! -d "$path/.git" ]]; then
        echo "ERROR: Git repository not found: $path"
        exit 1
    fi
    cd "$path"
    if [[ -n "$(git status --porcelain)" ]]; then
        echo "ERROR: $repo working tree is not clean. No changes have been made."
        git status --short
        exit 1
    fi
    git fetch origin main
    git checkout main
    git pull --ff-only origin main
    echo
 done

RUNTIME="$BASE/dev-environment/runtime/php85-ch"

if [[ ! -d "$RUNTIME/core_modules" || ! -d "$RUNTIME/packages" ]]; then
    echo "ERROR: PHP 8.5 runtime not found at $RUNTIME"
    exit 1
fi

echo "=== SYNC AI SOURCE TO PHP 8.5 RUNTIME ==="
rsync -a --delete \
    "$BASE/framework/app/core_modules/ai/" \
    "$RUNTIME/core_modules/ai/"

rsync -a --delete \
    "$BASE/modules/mcqtests/" \
    "$RUNTIME/packages/mcqtests/"

rsync -a --delete \
    "$BASE/modules/contextcontent/" \
    "$RUNTIME/packages/contextcontent/"

echo "Runtime source sync complete."
echo

echo "=== RECREATE PHP 8.5 WEB/NGINX WITH HOST-GATEWAY ==="
cd "$BASE/dev-environment"
docker compose -f compose/php85.yml up -d --force-recreate web nginx

echo
echo "=== CONTAINER STATUS ==="
docker compose -f compose/php85.yml ps

echo

echo "=== OLLAMA ON DESKTOP ==="
if command -v ollama >/dev/null 2>&1; then
    ollama list || true
else
    echo "Ollama CLI not found on desktop PATH."
fi

echo
if curl -fsS --max-time 5 http://127.0.0.1:11434/api/tags >/tmp/chisimba-ollama-tags-$$.json 2>/dev/null; then
    echo "Desktop Ollama API: reachable"
    cat /tmp/chisimba-ollama-tags-$$.json
else
    echo "Desktop Ollama API: NOT reachable at http://127.0.0.1:11434"
fi
rm -f /tmp/chisimba-ollama-tags-$$.json

echo

echo "=== OLLAMA FROM PHP 8.5 CONTAINER ==="
if docker exec chisimba-php85-web php -r '
$u="http://host.docker.internal:11434/api/tags";
$ch=curl_init($u);
curl_setopt_array($ch,[CURLOPT_RETURNTRANSFER=>true,CURLOPT_CONNECTTIMEOUT=>5,CURLOPT_TIMEOUT=>8]);
$r=curl_exec($ch);
$e=curl_error($ch);
$c=(int)curl_getinfo($ch,CURLINFO_RESPONSE_CODE);
curl_close($ch);
if ($r===false || $c<200 || $c>=300) { fwrite(STDERR,"HTTP $c $e\n"); exit(1); }
echo $r,"\n";
' ; then
    echo "PHP 8.5 container -> desktop Ollama: reachable"
else
    echo "PHP 8.5 container -> desktop Ollama: NOT reachable"
    echo "If desktop Ollama itself is working, its service may still be bound only to 127.0.0.1."
fi

echo

echo "=== VERSIONS NOW IN RUNTIME ==="
grep -E '^MODULE_VERSION:' "$RUNTIME/core_modules/ai/register.conf" || true
grep -E '^MODULE_VERSION:' "$RUNTIME/packages/mcqtests/register.conf" || true
grep -E '^MODULE_VERSION:' "$RUNTIME/packages/contextcontent/register.conf" || true

echo

echo "=== NEXT BROWSER STEP ==="
echo "Update AI Services, MCQ Tests and ContextContent in Module Catalogue so register.conf changes are loaded."
echo "Then test AI_STATE=disabled and AI_STATE=enabled in Sysconfig."
echo

echo "Finished: $(date -Is)"
echo "Log written to: $LOG"
