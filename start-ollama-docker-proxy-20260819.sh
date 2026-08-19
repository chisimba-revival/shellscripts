#!/usr/bin/env bash
set -euo pipefail

DOWNLOADS="/home/derek/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DOWNLOADS/start-ollama-docker-proxy-$STAMP.log"
PROXY_PORT=11435
TARGET_HOST=127.0.0.1
TARGET_PORT=11434
PIDFILE=/tmp/chisimba-ollama-proxy.pid
PYFILE=/tmp/chisimba-ollama-proxy.py

exec > >(tee -a "$LOG") 2>&1

echo "=== Ollama localhost -> Docker proxy ==="
echo "Started: $(date -Is)"

echo "Checking existing Ollama on http://127.0.0.1:11434 ..."
if ! curl -fsS --max-time 5 http://127.0.0.1:11434/api/tags >/dev/null; then
  echo "ERROR: desktop Ollama is not reachable on 127.0.0.1:11434"
  exit 1
fi

echo "Desktop Ollama: reachable"

if [[ -f "$PIDFILE" ]]; then
  OLD_PID="$(cat "$PIDFILE" 2>/dev/null || true)"
  if [[ -n "$OLD_PID" ]] && kill -0 "$OLD_PID" 2>/dev/null; then
    kill "$OLD_PID" || true
    sleep 1
  fi
  rm -f "$PIDFILE"
fi

cat > "$PYFILE" <<'PY'
import socket, threading
LISTEN=('0.0.0.0',11435)
TARGET=('127.0.0.1',11434)

def pipe(src,dst):
    try:
        while True:
            data=src.recv(65536)
            if not data: break
            dst.sendall(data)
    except Exception:
        pass
    finally:
        try: dst.shutdown(socket.SHUT_WR)
        except Exception: pass

def handle(client):
    try:
        upstream=socket.create_connection(TARGET,timeout=10)
    except Exception:
        client.close(); return
    threading.Thread(target=pipe,args=(client,upstream),daemon=True).start()
    threading.Thread(target=pipe,args=(upstream,client),daemon=True).start()

s=socket.socket(socket.AF_INET,socket.SOCK_STREAM)
s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(LISTEN)
s.listen(64)
while True:
    c,_=s.accept()
    handle(c)
PY

nohup python3 "$PYFILE" >/tmp/chisimba-ollama-proxy.out 2>&1 &
PROXY_PID=$!
echo "$PROXY_PID" > "$PIDFILE"

for _ in $(seq 1 20); do
  if curl -fsS --max-time 2 http://127.0.0.1:${PROXY_PORT}/api/tags >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -fsS --max-time 5 http://127.0.0.1:${PROXY_PORT}/api/tags >/dev/null; then
  echo "ERROR: proxy did not become ready on port ${PROXY_PORT}"
  cat /tmp/chisimba-ollama-proxy.out 2>/dev/null || true
  exit 1
fi

echo "Proxy ready on 0.0.0.0:${PROXY_PORT} (PID ${PROXY_PID})"
ss -ltnp 2>/dev/null | grep ":${PROXY_PORT}" || true

echo
echo "Testing from PHP 8.5 container..."
if docker exec chisimba-php85-web php -r '
$u="http://host.docker.internal:11435/api/tags";
$ch=curl_init($u);
curl_setopt_array($ch,[CURLOPT_RETURNTRANSFER=>true,CURLOPT_CONNECTTIMEOUT=>5,CURLOPT_TIMEOUT=>10]);
$r=curl_exec($ch); $e=curl_error($ch); $c=(int)curl_getinfo($ch,CURLINFO_RESPONSE_CODE); curl_close($ch);
if ($r===false || $c<200 || $c>=300) { fwrite(STDERR,"HTTP $c $e\n"); exit(1); }
echo $r,"\n";
'; then
  echo
  echo "SUCCESS: PHP 8.5 can reach desktop Ollama through the local proxy."
  echo "Use these Chisimba settings:"
  echo "  AI_STATE = enabled"
  echo "  AI_PROVIDER = ollama"
  echo "  AI_OLLAMA_BASE_URL = http://host.docker.internal:11435"
  echo "  AI_OLLAMA_MODEL = qwen2.5-coder:14b"
else
  echo "ERROR: PHP 8.5 still cannot reach the Ollama proxy."
  exit 1
fi

echo
echo "Finished: $(date -Is)"
echo "Log: $LOG"
