#!/usr/bin/env bash
set -euo pipefail

DOWNLOADS="/home/derek/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DOWNLOADS/restart-user-ollama-for-php85-$STAMP.log"
CONTAINER="chisimba-php85-web"
URL="http://host.docker.internal:11434"

exec > >(tee -a "$LOG") 2>&1

echo "=== Restart user Ollama for PHP 8.5 access ==="
echo "Started: $(date -Is)"
echo

command -v ollama >/dev/null || { echo "ERROR: ollama not found"; exit 1; }
docker inspect "$CONTAINER" >/dev/null 2>&1 || { echo "ERROR: $CONTAINER not found"; exit 1; }

# Stop only Ollama processes owned by the current user. This intentionally ends
# any current `ollama run` session before starting one canonical API server.
echo "Stopping current user-owned Ollama processes..."
pkill -u "$(id -u)" -x ollama 2>/dev/null || true
sleep 2

echo "Starting Ollama on 0.0.0.0:11434..."
OLLAMA_HOST="0.0.0.0:11434" nohup ollama serve >"$DOWNLOADS/ollama-serve-$STAMP.log" 2>&1 &
PID=$!
echo "$PID" > /tmp/chisimba-ollama.pid

ready=0
for _ in $(seq 1 20); do
  if curl -fsS --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done

if [[ "$ready" -ne 1 ]]; then
  echo "ERROR: Ollama did not start."
  tail -40 "$DOWNLOADS/ollama-serve-$STAMP.log" || true
  exit 1
fi

echo "Desktop Ollama is ready (PID $PID)."
ss -ltn 2>/dev/null | grep ':11434' || true

echo
echo "Testing from PHP 8.5 container..."
docker exec "$CONTAINER" php -r '
$u="http://host.docker.internal:11434/api/tags";
$ch=curl_init($u);
curl_setopt_array($ch,[CURLOPT_RETURNTRANSFER=>true,CURLOPT_CONNECTTIMEOUT=>5,CURLOPT_TIMEOUT=>10]);
$r=curl_exec($ch); $e=curl_error($ch); $c=(int)curl_getinfo($ch,CURLINFO_RESPONSE_CODE); curl_close($ch);
if ($r===false || $c<200 || $c>=300) { fwrite(STDERR,"HTTP $c $e\n"); exit(1); }
echo $r,"\n";
'

echo
echo "SUCCESS"
echo "AI_STATE = enabled"
echo "AI_PROVIDER = ollama"
echo "AI_OLLAMA_BASE_URL = $URL"
echo "AI_OLLAMA_MODEL = qwen2.5-coder:14b"
echo
echo "Log: $LOG"
