#!/usr/bin/env bash
set -Eeuo pipefail

BASE="/run/media/derek/main/chisimba-revival"
MODULES="$BASE/modules"
RUNTIME="$BASE/dev-environment/runtime/php85-ch"
DOWNLOADS="/home/derek/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DOWNLOADS/sync-mcq-question-buttons-php85-$STAMP.log"

mkdir -p "$DOWNLOADS"
exec > >(tee "$LOG") 2>&1

fail() { echo "ERROR: $*" >&2; exit 1; }

echo "=== MCQ question button parity sync to PHP 8.5 ==="
echo "Started: $(date -Is)"
echo

[[ "$(id -un)" == "derek" ]] || fail "Run as derek without sudo."
[[ -d "$MODULES/.git" ]] || fail "Modules Git repository not found."
[[ -d "$RUNTIME/packages/mcqtests" ]] || fail "PHP 8.5 MCQ runtime not found."

cd "$MODULES"
[[ "$(git branch --show-current)" == "main" ]] || fail "modules must be on main."
[[ -z "$(git status --porcelain=v1)" ]] || { git status --short; fail "modules working tree is not clean."; }
git fetch origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || git pull --ff-only origin main
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/main)" ]] || fail "modules main does not match origin/main."

echo "MODULES_COMMIT=$(git rev-parse HEAD)"

echo
echo "=== Source checks ==="
php -l mcqtests/templates/content/addquestion_tpl.php
php mcqtests/tests/mcq_question_button_contract_test.php

echo
echo "=== Sync MCQ Tests into PHP 8.5 runtime ==="
rsync -a --delete "$MODULES/mcqtests/" "$RUNTIME/packages/mcqtests/"

echo
echo "=== Runtime checks ==="
docker exec chisimba-php85-web php -l /var/www/html/ch/packages/mcqtests/templates/content/addquestion_tpl.php
docker exec chisimba-php85-web php /var/www/html/ch/packages/mcqtests/tests/mcq_question_button_contract_test.php

echo
echo "Runtime version:"
grep '^MODULE_VERSION:' "$RUNTIME/packages/mcqtests/register.conf" || true

echo
echo "PASS: MCQ question Save/Cancel actions synced with native skin-controlled buttons and shared Lucide icon contract."
echo "Check the add/edit question screen in both Chisimba Reborn and Kenga Learn."
echo "Finished: $(date -Is)"
echo "Log: $LOG"
