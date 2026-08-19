#!/usr/bin/env bash
set -euo pipefail

DOWNLOADS="/home/derek/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DOWNLOADS/ollama-php85-bridge-check-$STAMP.log"
PORT=11435
HOST_URL="http://127.0.0.1:$PORT"
CONTAINER_URL="http://host.docker.internal:$PORT"
CONTAINER="chisimba-php85-web"

exec > >(tee -a "$LOG") 2>&1

echo "=== Desktop Ollama -> PHP 8.5 bridge check ==="
echo "Started: $(date -Is)"
echo "Log: $LOG"
echo

if ! command -v ollama >/dev/null 2>&1; then
    echo "ERROR: Ollama CLI not found on desktop PATH."
    exit 1
fi

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "ERROR: PHP 8.5 container not found: $CONTAINER"
    exit 1
fi

if curl -fsS --max-time 3 "$HOST_URL/api/tags" >/dev/null 2>&1; then
    echo "Ollama bridge already listening on $HOST_URL"
else
    echo "Starting a Docker-reachable Ollama listener on port $PORT..."
    nohup env OLLAMA_HOST="0.0.0.0:$PORT" ollama serve >/dev/null 2>&1 &
    BRIDGE_PID=$!
    echo "$BRIDGE_PID" > /tmp/chisimba-ollama-bridge.pid

    ready=0
    for _ in $(seq 1 20); do
        if curl -fsS --max-time 2 "$HOST_URL/api/tags" >/dev/null 2>&1; then
            ready=1
            break
        fi
        sleep 1
    done
    if [[ "$ready" -ne 1 ]]; then
        echo "ERROR: bridge listener did not become ready on $HOST_URL"
        exit 1
    fi
    echo "Bridge listener started (PID $BRIDGE_PID)."
fi

echo
echo "=== DESKTOP MODELS ==="
ollama list

echo
echo "=== PHP 8.5 -> DESKTOP OLLAMA ==="
if docker exec "$CONTAINER" php -r '
$u="http://host.docker.internal:11435/api/tags";
$ch=curl_init($u);
curl_setopt_array($ch,[CURLOPT_RETURNTRANSFER=>true,CURLOPT_CONNECTTIMEOUT=>5,CURLOPT_TIMEOUT=>8]);
$r=curl_exec($ch);
$e=curl_error($ch);
$c=(int)curl_getinfo($ch,CURLINFO_RESPONSE_CODE);
curl_close($ch);
if ($r===false || $c<200 || $c>=300) { fwrite(STDERR,"HTTP $c $e\n"); exit(1); }
echo $r,"\n";
'; then
    echo
    echo "PASS: PHP 8.5 can reach desktop Ollama."
    echo "Use AI_OLLAMA_BASE_URL=$CONTAINER_URL"
    echo "Recommended first model: qwen2.5-coder:14b"
else
    echo "ERROR: PHP 8.5 still cannot reach desktop Ollama on port $PORT."
    exit 1
fi

echo
echo "Finished: $(date -Is)"
echo "Log written to: $LOG"
