#!/usr/bin/env bash
set -euo pipefail

BASE=/run/media/derek/main/chisimba-revival
FRAMEWORK="$BASE/framework"
RUNTIME="$BASE/dev-environment/runtime/php85-ch"
DOWNLOADS=/home/derek/Downloads
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DOWNLOADS/sync-shared-action-buttons-php85-$STAMP.log"

exec > >(tee "$LOG") 2>&1

echo "=== Shared modern action buttons -> PHP 8.5 ==="
[[ "$(id -un)" == derek ]] || { echo "ERROR: run as derek"; exit 1; }
[[ -d "$FRAMEWORK/.git" ]] || { echo "ERROR: framework repo missing"; exit 1; }
[[ -d "$RUNTIME/skins/_common2/css" ]] || { echo "ERROR: PHP 8.5 runtime missing"; exit 1; }

cd "$FRAMEWORK"
[[ "$(git branch --show-current)" == main ]] || { echo "ERROR: framework must be on main"; exit 1; }
[[ -z "$(git status --porcelain)" ]] || { echo "ERROR: framework working tree not clean"; git status --short; exit 1; }
git fetch origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || git pull --ff-only origin main

echo "Framework commit: $(git rev-parse HEAD)"

rsync -a \
  "$FRAMEWORK/app/skins/_common2/css/basecss.php" \
  "$FRAMEWORK/app/skins/_common2/css/modern-action-compat.css" \
  "$RUNTIME/skins/_common2/css/"

php_file="$RUNTIME/skins/_common2/css/basecss.php"
css_file="$RUNTIME/skins/_common2/css/modern-action-compat.css"
grep -Fq "modern-action-compat.css" "$php_file"
grep -Fq ".chisimba-form-actions button.button > span" "$css_file"
grep -Fq ".chisimba-action-icon" "$css_file"

echo "PASS: shared button compatibility is in PHP 8.5 runtime."
echo "Hard-refresh the MCQ question edit page in both maintained skins."
echo "Log: $LOG"
