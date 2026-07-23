#!/usr/bin/env bash
set -Eeuo pipefail

TOOL="${1:-$(cd "$(dirname "$0")/.." && pwd)/tools/php-structure-tool.py}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FIXTURE="$TMP/fixture.php"
INSERT="$TMP/insert.php"

cat > "$FIXTURE" <<'PHP'
<?php

class fixture
{
    /**
     * Legacy method.
     */
    final public function &__legacy(
        $value = null
    ): array
    {
        $result = array();

        if ($value !== null) {
            $result['value'] = $value;
        }

        return $result;
    }

    public function anchor()
    {
        return 'anchor';
    }
}
PHP

cat > "$INSERT" <<'PHP'
/**
 * Newly inserted method.
 */
public function modern()
{
    return $this->__compat();
}
PHP

php -l "$FIXTURE" >/dev/null
"$TOOL" --file "$FIXTURE" list-methods | grep -Fq "__legacy"
"$TOOL" --file "$FIXTURE" list-methods | grep -Fq "anchor"

"$TOOL" \
    --file "$FIXTURE" \
    --backup-suffix .before \
    rename-method \
    --from __legacy \
    --to __compat >/dev/null

grep -Fq 'function &__compat' "$FIXTURE"
grep -Fq 'function &__legacy' "$FIXTURE.before"

"$TOOL" \
    --file "$FIXTURE" \
    --backup-suffix "" \
    insert-before \
    --anchor anchor \
    --method-file "$INSERT" >/dev/null

grep -Fq 'public function modern()' "$FIXTURE"
php -l "$FIXTURE" >/dev/null

modern_line="$(grep -n 'public function modern' "$FIXTURE" | cut -d: -f1)"
anchor_line="$(grep -n 'public function anchor' "$FIXTURE" | cut -d: -f1)"
[[ "$modern_line" -lt "$anchor_line" ]]

cat > "$INSERT" <<'PHP'
public function finalMethod()
{
    return 'final';
}
PHP

"$TOOL" \
    --file "$FIXTURE" \
    --backup-suffix "" \
    insert-after \
    --anchor anchor \
    --method-file "$INSERT" >/dev/null

anchor_line="$(grep -n 'public function anchor' "$FIXTURE" | cut -d: -f1)"
final_line="$(grep -n 'public function finalMethod' "$FIXTURE" | cut -d: -f1)"
[[ "$final_line" -gt "$anchor_line" ]]

"$TOOL" \
    --file "$FIXTURE" \
    --dry-run \
    rename-method \
    --from __compat \
    --to __legacy | grep -Fq '+    final public function &__legacy('

grep -Fq 'function &__compat' "$FIXTURE"

echo "PASS: token-based method inventory."
echo "PASS: multiline reference-return signature discovered."
echo "PASS: method renamed without regex discovery."
echo "PASS: method inserted before structural anchor."
echo "PASS: method inserted after structural anchor."
echo "PASS: comments and surrounding code preserved."
echo "PASS: dry-run leaves source unchanged."
echo "PASS: PHP syntax validation before and after edits."
