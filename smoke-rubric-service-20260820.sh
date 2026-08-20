#!/usr/bin/env bash
set -euo pipefail

DOWNLOADS="/home/derek/Downloads"
STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$DOWNLOADS/rubric-service-smoke-$STAMP.log"
CONTAINER="chisimba-php85-web"
APP_ROOT="/var/www/html/ch"
CONTEXT_CODE="${1:-root}"
RUBRIC_ID="${2:-}"

mkdir -p "$DOWNLOADS"
exec > >(tee "$LOG") 2>&1

echo "=== Chisimba Rubric service smoke test ==="
echo "Started: $(date -Is)"
echo "Container: $CONTAINER"
echo "Application root: $APP_ROOT"
echo "Context: $CONTEXT_CODE"
if [[ -n "$RUBRIC_ID" ]]; then
    echo "Rubric ID: $RUBRIC_ID"
fi
echo "Log: $LOG"
echo

if ! docker inspect "$CONTAINER" >/dev/null 2>&1; then
    echo "FAIL: PHP 8.5 container not found: $CONTAINER"
    exit 1
fi

if [[ "$(docker inspect -f '{{.State.Running}}' "$CONTAINER")" != "true" ]]; then
    echo "FAIL: PHP 8.5 container is not running: $CONTAINER"
    exit 1
fi

echo "[1/3] PHP syntax check"
docker exec "$CONTAINER" php -l "$APP_ROOT/packages/rubric/classes/rubricservice_class_inc.php"
echo "PASS: rubricservice class parses under container PHP."
echo

echo "[2/3] Chisimba service load and rubric discovery"
set +e
docker exec -i \
    -e SMOKE_CONTEXT="$CONTEXT_CODE" \
    -e SMOKE_RUBRIC_ID="$RUBRIC_ID" \
    -e SMOKE_APP_ROOT="$APP_ROOT" \
    "$CONTAINER" php <<'PHP'
<?php
error_reporting(E_ALL);
ini_set('display_errors', '1');

$root = getenv('SMOKE_APP_ROOT') ?: '/var/www/html/ch';
$contextCode = getenv('SMOKE_CONTEXT') ?: 'root';
$requestedRubricId = getenv('SMOKE_RUBRIC_ID') ?: '';

chdir($root);
$_SERVER['REQUEST_METHOD'] = 'POST';
$_SERVER['HTTP_USER_AGENT'] = 'chisimba-rubric-smoke-test';
$_SERVER['HTTP_HOST'] = 'localhost';
$_SERVER['SCRIPT_NAME'] = '/ch/index.php';
$GLOBALS['kewl_entry_point_run'] = true;

require_once 'classes/core/engine_class_inc.php';
$engine = new engine();

$service = $engine->getObject('rubricservice', 'rubric');
if (!is_object($service) || !($service instanceof rubricservice)) {
    fwrite(STDERR, "FAIL: Chisimba did not return rubricservice.\n");
    exit(20);
}

echo "PASS: rubricservice instantiated through Chisimba.\n";

$rubrics = $service->listRubrics($contextCode);
if (!is_array($rubrics)) {
    fwrite(STDERR, "FAIL: listRubrics() did not return an array.\n");
    exit(21);
}

echo "PASS: listRubrics() returned an array.\n";
echo "Rubrics found in context '{$contextCode}': " . count($rubrics) . "\n";

foreach ($rubrics as $rubric) {
    printf(
        "  - %s | %s | %d rows x %d cols\n",
        $rubric['id'] ?? '(no id)',
        $rubric['title'] ?? '(untitled)',
        (int) ($rubric['rows'] ?? 0),
        (int) ($rubric['cols'] ?? 0)
    );
}

$rubricId = $requestedRubricId;
if ($rubricId === '' && !empty($rubrics[0]['id'])) {
    $rubricId = $rubrics[0]['id'];
}

if ($rubricId === '') {
    echo "SKIP: no rubric is available in this context, so structured retrieval cannot be exercised.\n";
    echo "SERVICE_SMOKE=PASS_WITHOUT_SAMPLE\n";
    exit(0);
}

echo "Testing structured rubric: {$rubricId}\n";
$structured = $service->getStructuredRubric($rubricId);
if ($structured === false || !is_array($structured)) {
    fwrite(STDERR, "FAIL: getStructuredRubric() did not return a rubric array.\n");
    exit(22);
}

$required = array('id', 'title', 'rows', 'cols', 'performances', 'criteria');
foreach ($required as $key) {
    if (!array_key_exists($key, $structured)) {
        fwrite(STDERR, "FAIL: structured rubric missing key: {$key}\n");
        exit(23);
    }
}

if (!is_array($structured['performances']) || !is_array($structured['criteria'])) {
    fwrite(STDERR, "FAIL: performances or criteria is not an array.\n");
    exit(24);
}

if (count($structured['performances']) !== (int) $structured['cols']) {
    fwrite(STDERR, "FAIL: performance count does not match rubric column count.\n");
    exit(25);
}

if (count($structured['criteria']) !== (int) $structured['rows']) {
    fwrite(STDERR, "FAIL: criteria count does not match rubric row count.\n");
    exit(26);
}

foreach ($structured['criteria'] as $criterion) {
    if (!isset($criterion['levels']) || !is_array($criterion['levels'])) {
        fwrite(STDERR, "FAIL: criterion has no levels array.\n");
        exit(27);
    }
    if (count($criterion['levels']) !== (int) $structured['cols']) {
        fwrite(STDERR, "FAIL: criterion level count does not match rubric column count.\n");
        exit(28);
    }
}

echo "PASS: getStructuredRubric() returned a complete ordered structure.\n";
echo "Title: " . ($structured['title'] ?? '') . "\n";
echo "Dimensions: " . (int) $structured['rows'] . " rows x " . (int) $structured['cols'] . " cols\n";
echo "Performance levels: " . count($structured['performances']) . "\n";
echo "Criteria: " . count($structured['criteria']) . "\n";
echo "SERVICE_SMOKE=PASS\n";
PHP
STATUS=$?
set -e

echo
if [[ $STATUS -ne 0 ]]; then
    echo "FAIL: Rubric service smoke test exited with status $STATUS."
    echo "Log written to: $LOG"
    exit "$STATUS"
fi

echo "[3/3] Result"
if grep -q '^SERVICE_SMOKE=PASS$' "$LOG"; then
    echo "PASS: Rubric service loaded and structured retrieval was verified."
elif grep -q '^SERVICE_SMOKE=PASS_WITHOUT_SAMPLE$' "$LOG"; then
    echo "PASS WITH SKIP: service loaded, but there was no rubric in context '$CONTEXT_CODE' to exercise structured retrieval."
    echo "Create a rubric or rerun with a context containing one."
else
    echo "FAIL: smoke-test completion marker not found."
    exit 30
fi

echo "Finished: $(date -Is)"
echo "Log written to: $LOG"
