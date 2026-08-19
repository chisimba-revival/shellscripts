#!/usr/bin/env bash
set -euo pipefail

DOWNLOADS="/home/derek/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DOWNLOADS/configure-ollama-docker-access-$STAMP.log"
exec > >(tee -a "$LOG") 2>&1

echo "=== Configure desktop Ollama for PHP 8.5 Docker access ==="
echo "Started: $(date -Is)"
echo

if ! command -v systemctl >/dev/null 2>&1; then
  echo "ERROR: systemctl not found."
  exit 1
fi
if ! command -v ollama >/dev/null 2>&1; then
  echo "ERROR: ollama not found on PATH."
  exit 1
fi

# Configure the existing systemd Ollama service. sudo may prompt once for Derek's password.
echo "Configuring existing ollama.service to listen on 0.0.0.0:11434..."
sudo mkdir -p /etc/systemd/system/ollama.service.d
printf '%s\n' '[Service]' 'Environment="OLLAMA_HOST=0.0.0.0:11434"' | sudo tee /etc/systemd/system/ollama.service.d/chisimba-docker.conf >/dev/null
sudo systemctl daemon-reload
sudo systemctl restart ollama

for i in {1..20}; do
  if curl -fsS --max-time 2 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

if ! curl -fsS --max-time 5 http://127.0.0.1:11434/api/tags >/dev/null; then
  echo "ERROR: Ollama did not become ready after restart."
  sudo systemctl status ollama --no-pager || true
  exit 1
fi

echo "Desktop Ollama: reachable"
echo "Listener:"
ss -ltnp 2>/dev/null | grep ':11434' || true

echo
echo "Testing from chisimba-php85-web..."
if docker exec chisimba-php85-web php -r '
$u="http://host.docker.internal:11434/api/tags";
$ch=curl_init($u);
curl_setopt_array($ch,[CURLOPT_RETURNTRANSFER=>true,CURLOPT_CONNECTTIMEOUT=>5,CURLOPT_TIMEOUT=>10]);
$r=curl_exec($ch); $e=curl_error($ch); $c=(int)curl_getinfo($ch,CURLINFO_RESPONSE_CODE); curl_close($ch);
if ($r===false || $c<200 || $c>=300) { fwrite(STDERR,"HTTP $c $e\n"); exit(1); }
echo $r,"\n";
'; then
  echo
  echo "SUCCESS: PHP 8.5 can reach desktop Ollama."
  echo "Use these Chisimba AI settings:"
  echo "  AI_STATE = enabled"
  echo "  AI_PROVIDER = ollama"
  echo "  AI_OLLAMA_BASE_URL = http://host.docker.internal:11434"
  echo "  AI_OLLAMA_MODEL = qwen2.5-coder:14b"
else
  echo "ERROR: PHP 8.5 still cannot reach desktop Ollama."
  exit 1
fi

echo
echo "Finished: $(date -Is)"
echo "Log: $LOG"
