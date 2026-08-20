#!/usr/bin/env bash
set -euo pipefail

DOWNLOADS="/home/derek/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DOWNLOADS/rubric-fixture-create-$STAMP.log"
CONTAINER="chisimba-php85-web"
APP_ROOT="/var/www/html/ch"
CONTEXT_CODE="${1:-root}"
FIXTURE_TITLE="Worksheet AI Test Rubric"
TMP_PHP="/tmp/chisimba-create-rubric-fixture-1835.php"
HOST_TMP="$(mktemp /tmp/chisimba-create-rubric-fixture-1835.XXXXXX.php)"

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

$root = getenv('FIXTURE_APP_ROOT') ?: '/var/www/html/ch';
$contextCode = getenv('FIXTURE_CONTEXT') ?: 'root';
$title = getenv('FIXTURE_TITLE') ?: 'Worksheet AI Test Rubric';

chdir($root);
$_SERVER['REQUEST_METHOD'] = 'POST';
$_SERVER['HTTP_USER_AGENT'] = 'chisimba-rubric-fixture-creator';
$_SERVER['HTTP_HOST'] = 'localhost';
$_SERVER['SCRIPT_NAME'] = '/ch/index.php';
$GLOBALS['kewl_entry_point_run'] = true;

require_once 'classes/core/engine_class_inc.php';
$engine = new engine();

$dbTables = $engine->getObject('dbrubrictables', 'rubric');
$dbObjectives = $engine->getObject('dbrubricobjectives', 'rubric');
$dbPerformances = $engine->getObject('dbrubricperformances', 'rubric');
$dbCells = $engine->getObject('dbrubriccells', 'rubric');
$service = $engine->getObject('rubricservice', 'rubric');

$existing = $service->listRubrics($contextCode);
foreach ($existing as $rubric) {
    if (($rubric['title'] ?? '') === $title) {
        echo "EXISTS: fixture already present.\n";
        echo "RUBRIC_ID=" . $rubric['id'] . "\n";
        echo "FIXTURE_RESULT=EXISTS\n";
        exit(0);
    }
}

$rubricId = $dbTables->insertSingle(
    $contextCode,
    $title,
    'Deterministic rubric fixture for Worksheet integration and Rubric service smoke testing.',
    2,
    3,
    null
);

if (!$rubricId) {
    fwrite(STDERR, "FAIL: rubric table record was not created.\n");
    exit(20);
}

echo "Created rubric ID: {$rubricId}\n";

$dbObjectives->insertSingle($rubricId, 1, 'Accuracy of response');
$dbObjectives->insertSingle($rubricId, 2, 'Quality of reasoning');

$dbPerformances->insertSingle($rubricId, 1, 'Developing');
$dbPerformances->insertSingle($rubricId, 2, 'Competent');
$dbPerformances->insertSingle($rubricId, 3, 'Excellent');

$cells = array(
    1 => array(
        1 => 'Response contains major factual errors or significant omissions.',
        2 => 'Response is substantially accurate with only minor errors or omissions.',
        3 => 'Response is accurate, complete, and appropriately precise.',
    ),
    2 => array(
        1 => 'Reasoning is unclear, unsupported, or poorly connected to the response.',
        2 => 'Reasoning is generally clear and supported by relevant explanation.',
        3 => 'Reasoning is clear, well supported, and demonstrates strong understanding.',
    ),
);
foreach ($cells as $row => $columns) {
    foreach ($columns as $col => $contents) {
        $dbCells->insertSingle($rubricId, $row, $col, $contents);
    }
}

$visible = false;
foreach ($service->listRubrics($contextCode) as $rubric) {
    if (($rubric['id'] ?? '') === $rubricId) {
        $visible = true;
        break;
    }
}
if (!$visible) {
    fwrite(STDERR, "FAIL: newly created rubric is not visible through listRubrics().\n");
    exit(21);
}

$structured = $service->getStructuredRubric($rubricId);
if ($structured === false
    || count($structured['criteria'] ?? array()) !== 2
    || count($structured['performances'] ?? array()) !== 3
) {
    fwrite(STDERR, "FAIL: structured rubric verification failed.\n");
    exit(22);
}

echo "PASS: rubric fixture created, listed, and structured retrieval verified.\n";
echo "RUBRIC_ID={$rubricId}\n";
echo "FIXTURE_RESULT=CREATED\n";
PHP

echo "=== Rubric fixture creator after reserved-column fix ==="
echo "Started: $(date -Is)"
echo "Context: $CONTEXT_CODE"
echo "Log: $LOG"
echo

docker cp "$HOST_TMP" "$CONTAINER:$TMP_PHP" >/dev/null
docker exec "$CONTAINER" php -l "$TMP_PHP"

set +e
docker exec \
    -e FIXTURE_CONTEXT="$CONTEXT_CODE" \
    -e FIXTURE_TITLE="$FIXTURE_TITLE" \
    -e FIXTURE_APP_ROOT="$APP_ROOT" \
    "$CONTAINER" php "$TMP_PHP"
STATUS=$?
set -e

if [[ $STATUS -ne 0 ]]; then
    echo "FAIL: fixture creator exited with status $STATUS."
    echo "Log written to: $LOG"
    exit "$STATUS"
fi

RUBRIC_ID="$(grep '^RUBRIC_ID=' "$LOG" | tail -1 | cut -d= -f2-)"
if [[ -z "$RUBRIC_ID" ]]; then
    echo "FAIL: no RUBRIC_ID was reported."
    exit 30
fi

echo
echo "PASS: Rubric fixture ready."
echo "Rubric ID: $RUBRIC_ID"
echo "Next:"
echo "  bash smoke-rubric-service-20260820-1724.sh \"$CONTEXT_CODE\" \"$RUBRIC_ID\""
echo "Finished: $(date -Is)"
echo "Log written to: $LOG"
