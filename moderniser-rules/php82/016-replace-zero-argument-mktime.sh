#!/usr/bin/env bash
set -Eeuo pipefail

# Chisimba PHP 8 moderniser rule
# Author: Derek Keats
#
# PHP 8 requires the first mktime() argument. Legacy Chisimba code frequently
# used mktime() with no arguments merely to obtain the current Unix timestamp.
# time() is the direct modern equivalent.
#
# This rule uses PHP's tokenizer so comments, strings, declarations, object
# methods and static methods are not altered.

if [[ "$#" -ne 1 ]]; then
    echo "Usage: $0 <assembled-chisimba-root>" >&2
    exit 2
fi

ROOT="$1"
PATCHER="$(mktemp)"
trap 'rm -f "$PATCHER"' EXIT

cat >"$PATCHER" <<'PHP'
<?php
if ($argc !== 2) {
    exit(2);
}

$root = $argv[1];
$changed = 0;
$calls = 0;

function textOf($token): string
{
    return is_array($token) ? $token[1] : $token;
}

function previousSignificant(array $tokens, int $index)
{
    for ($i = $index - 1; $i >= 0; $i--) {
        $token = $tokens[$i];
        if (is_array($token) && in_array($token[0], [T_WHITESPACE, T_COMMENT, T_DOC_COMMENT], true)) {
            continue;
        }
        return $token;
    }
    return null;
}

function nextSignificant(array $tokens, int $index): ?int
{
    for ($i = $index + 1, $count = count($tokens); $i < $count; $i++) {
        $token = $tokens[$i];
        if (is_array($token) && in_array($token[0], [T_WHITESPACE, T_COMMENT, T_DOC_COMMENT], true)) {
            continue;
        }
        return $i;
    }
    return null;
}

$iterator = new RecursiveIteratorIterator(
    new RecursiveDirectoryIterator($root, FilesystemIterator::SKIP_DOTS)
);

foreach ($iterator as $entry) {
    if (!$entry->isFile() || !preg_match('/\.php$/i', $entry->getFilename())) {
        continue;
    }

    $file = $entry->getPathname();
    $source = file_get_contents($file);
    if ($source === false || stripos($source, 'mktime') === false) {
        continue;
    }

    $tokens = token_get_all($source);
    $output = '';
    $fileCalls = 0;

    foreach ($tokens as $i => $token) {
        if (
            is_array($token)
            && $token[0] === T_STRING
            && strcasecmp($token[1], 'mktime') === 0
        ) {
            $previous = previousSignificant($tokens, $i);
            $blocked = is_array($previous)
                && in_array($previous[0], [T_FUNCTION, T_OBJECT_OPERATOR, T_DOUBLE_COLON], true);

            $open = nextSignificant($tokens, $i);
            $close = $open !== null ? nextSignificant($tokens, $open) : null;

            if (
                !$blocked
                && $open !== null
                && textOf($tokens[$open]) === '('
                && $close !== null
                && textOf($tokens[$close]) === ')'
            ) {
                $output .= 'time';
                $fileCalls++;
                continue;
            }
        }

        $output .= textOf($token);
    }

    if ($fileCalls > 0) {
        file_put_contents($file, $output);
        echo "PATCHED {$file} ({$fileCalls})\n";
        $changed++;
        $calls += $fileCalls;
    }
}

echo "TOTAL_FILES_CHANGED={$changed}\n";
echo "TOTAL_CALLS_REPLACED={$calls}\n";
PHP

php "$PATCHER" "$ROOT"
