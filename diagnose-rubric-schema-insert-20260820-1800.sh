#!/usr/bin/env bash
set -euo pipefail

DOWNLOADS="/home/derek/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DOWNLOADS/rubric-schema-insert-diagnostic-$STAMP.log"
CONTAINER="chisimba-php85-web"
APP_ROOT="/var/www/html/ch"
TMP_PHP="/tmp/chisimba-rubric-schema-insert-diagnostic.php"
HOST_TMP="$(mktemp /tmp/chisimba-rubric-schema-insert-diagnostic.XXXXXX.php)"

mkdir -p "$DOWNLOADS"
exec > >(tee "$LOG") 2>&1

cleanup() {
    rm -f "$HOST_TMP" >/dev/null 2>&1 || true
    docker exec "$CONTAINER" rm -f "$TMP_PHP" >/dev/null 2>&1 || true
}
trap cleanup EXIT

cat > "$HOST_TMP" <<'PHP'
<?php
error_reporting(E_ALL);
ini_set('display_errors', '1');

$root = '/var/www/html/ch';
chdir($root);
$_SERVER['REQUEST_METHOD'] = 'POST';
$_SERVER['HTTP_USER_AGENT'] = 'chisimba-rubric-schema-diagnostic';
$_SERVER['HTTP_HOST'] = 'localhost';
$_SERVER['SCRIPT_NAME'] = '/ch/index.php';
$GLOBALS['kewl_entry_point_run'] = true;

require_once 'classes/core/engine_class_inc.php';
$engine = new engine();
$dbTables = $engine->getObject('dbrubrictables', 'rubric');

function dump_section($label, $value) {
    echo "=== {$label} ===\n";
    var_export($value);
    echo "\n\n";
}

dump_section('SHOW COLUMNS tbl_rubric_tables', $dbTables->getArray('SHOW COLUMNS FROM tbl_rubric_tables'));
dump_section('SHOW CREATE TABLE tbl_rubric_tables', $dbTables->getArray('SHOW CREATE TABLE tbl_rubric_tables'));
dump_section('CURRENT ROW COUNT', $dbTables->getArray('SELECT COUNT(*) AS cnt FROM tbl_rubric_tables'));
dump_section('CURRENT IDS', $dbTables->getArray('SELECT id, LENGTH(id) AS id_len, contextCode, userId, LENGTH(userId) AS user_len, title FROM tbl_rubric_tables ORDER BY updated DESC, id DESC LIMIT 20'));

$probeId = 'rubric_probe_' . time();
$probeTitle = 'Rubric insert diagnostic probe';

$dbTables->beginTransaction();
$ret = $dbTables->insert(array(
    'id' => $probeId,
    'contextCode' => 'root',
    'title' => $probeTitle,
    'description' => 'Transactional diagnostic probe; rolled back.',
    'rows' => 1,
    'cols' => 1,
));

dump_section('PROBE INSERT RETURN', $ret);
dump_section('PROBE ROW AFTER INSERT', $dbTables->getArray("SELECT id, LENGTH(id) AS id_len, contextCode, userId, title FROM tbl_rubric_tables WHERE id='" . addslashes($probeId) . "'"));

$dbTables->rollbackTransaction();
dump_section('PROBE ROW AFTER ROLLBACK', $dbTables->getArray("SELECT id FROM tbl_rubric_tables WHERE id='" . addslashes($probeId) . "'"));

echo "DIAGNOSTIC_DONE=1\n";
PHP

echo "=== Rubric schema/insert diagnostic ==="
echo "Started: $(date -Is)"
echo "Log: $LOG"
echo

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "FAIL: PHP 8.5 container not found: $CONTAINER"
    exit 1
fi

docker cp "$HOST_TMP" "$CONTAINER:$TMP_PHP" >/dev/null
docker exec "$CONTAINER" php -l "$TMP_PHP"
docker exec "$CONTAINER" php "$TMP_PHP"

echo
echo "Finished: $(date -Is)"
echo "Log written to: $LOG"
