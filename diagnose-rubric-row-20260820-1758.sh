#!/usr/bin/env bash
set -euo pipefail

DOWNLOADS="/home/derek/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DOWNLOADS/rubric-row-diagnostic-$STAMP.log"
CONTAINER="chisimba-php85-web"
APP_ROOT="/var/www/html/ch"
RUBRIC_ID="${1:-gen17Srv16Nme16_62731_1787241295}"
TMP_PHP="/tmp/chisimba-rubric-row-diagnostic.php"
HOST_TMP="$(mktemp /tmp/chisimba-rubric-row-diagnostic.XXXXXX.php)"

mkdir -p "$DOWNLOADS"
exec > >(tee "$LOG") 2>&1

cleanup() {
    rm -f "$HOST_TMP" >/dev/null 2>&1 || true
    docker exec "$CONTAINER" rm -f "$TMP_PHP" >/dev/null 2>&1 || true
}
trap cleanup EXIT

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "FAIL: PHP 8.5 container not found: $CONTAINER"
    exit 1
fi

cat > "$HOST_TMP" <<'PHP'
<?php
error_reporting(E_ALL);
ini_set('display_errors', '1');

$root = getenv('DIAG_APP_ROOT') ?: '/var/www/html/ch';
$rubricId = getenv('DIAG_RUBRIC_ID') ?: '';
chdir($root);
$_SERVER['REQUEST_METHOD'] = 'POST';
$_SERVER['HTTP_USER_AGENT'] = 'chisimba-rubric-row-diagnostic';
$_SERVER['HTTP_HOST'] = 'localhost';
$_SERVER['SCRIPT_NAME'] = '/ch/index.php';
$GLOBALS['kewl_entry_point_run'] = true;

require_once 'classes/core/engine_class_inc.php';
$engine = new engine();
$dbTables = $engine->getObject('dbrubrictables', 'rubric');
$service = $engine->getObject('rubricservice', 'rubric');

$row = $dbTables->getRow('id', $rubricId);
echo "RUBRIC_ID={$rubricId}\n";
echo "RAW_ROW=" . var_export($row, true) . "\n";

$rootRows = $dbTables->getArray("SELECT id, contextCode, title, userId FROM tbl_rubric_tables WHERE contextCode='root' ORDER BY title");
echo "ROOT_ROWS=" . var_export($rootRows, true) . "\n";

$nullRows = $dbTables->getArray("SELECT id, contextCode, title, userId FROM tbl_rubric_tables WHERE contextCode='root' AND userId IS NULL ORDER BY title");
echo "ROOT_NULL_USER_ROWS=" . var_export($nullRows, true) . "\n";

$emptyRows = $dbTables->getArray("SELECT id, contextCode, title, userId FROM tbl_rubric_tables WHERE contextCode='root' AND userId='' ORDER BY title");
echo "ROOT_EMPTY_USER_ROWS=" . var_export($emptyRows, true) . "\n";

$list = $service->listRubrics('root');
echo "SERVICE_LIST=" . var_export($list, true) . "\n";
echo "DIAGNOSTIC_DONE=1\n";
PHP

echo "=== Rubric row diagnostic ==="
echo "Started: $(date -Is)"
echo "Rubric ID: $RUBRIC_ID"
echo "Log: $LOG"
echo

docker cp "$HOST_TMP" "$CONTAINER:$TMP_PHP" >/dev/null
docker exec "$CONTAINER" php -l "$TMP_PHP"
docker exec \
    -e DIAG_APP_ROOT="$APP_ROOT" \
    -e DIAG_RUBRIC_ID="$RUBRIC_ID" \
    "$CONTAINER" php "$TMP_PHP"

echo
echo "Finished: $(date -Is)"
echo "Log written to: $LOG"
