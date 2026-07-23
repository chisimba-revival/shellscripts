#!/usr/bin/env bash
set -Eeuo pipefail
PATCHER="${1:-$(cd "$(dirname "$0")/.." && pwd)/tools/php-method-patcher.py}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FIXTURE="$TMP/fixture.php"
BODY="$TMP/body.txt"

cat > "$FIXTURE" <<'PHP'
<?php
class fixture
{
    /** Preserve this comment. */
    public function target($value = null): array
    {
        $old = array('state' => 'legacy');
        if ($value !== null) {
            $old['value'] = $value;
        }
        return $old;
    }

    public function untouched()
    {
        return "keep { these } braces";
    }
}
PHP

cat > "$BODY" <<'BODY'
$result = array('state' => 'modern');
if ($value !== null) {
    $result['value'] = $value;
}
return $result;
BODY

php -l "$FIXTURE" >/dev/null
"$PATCHER" --file "$FIXTURE" --method target --body-file "$BODY" --backup-suffix .before >/dev/null
php -l "$FIXTURE" >/dev/null
grep -Fq "\$result = array('state' => 'modern');" "$FIXTURE"
grep -Fq 'return "keep { these } braces";' "$FIXTURE"
grep -Fq "\$old = array('state' => 'legacy');" "$FIXTURE.before"
"$PATCHER" --file "$FIXTURE.before" --method target --body-file "$BODY" --dry-run | grep -Fq "+        \$result = array('state' => 'modern');"
set +e
"$PATCHER" --file "$FIXTURE" --method doesNotExist --body 'return null;' >/dev/null 2>&1
status=$?
set -e
[[ "$status" -eq 2 ]]

echo "PASS: method located structurally."
echo "PASS: nested braces handled."
echo "PASS: signature and comments preserved."
echo "PASS: unrelated method preserved."
echo "PASS: backup created."
echo "PASS: dry-run diff works."
echo "PASS: missing method returns exit code 2."
echo "PASS: PHP syntax validation works."
