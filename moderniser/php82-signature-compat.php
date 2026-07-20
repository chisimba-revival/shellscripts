<?php
declare(strict_types=1);

/**
 * Chisimba PHP 8 signature compatibility pass.
 *
 * Purpose:
 *   Detect child methods that omit optional trailing parameters accepted by
 *   their parent method, and append those parameters without changing method
 *   behaviour.
 *
 * Safety:
 *   - Only appends parameters that are optional in the parent.
 *   - Never removes or reorders child parameters.
 *   - Creates a backup before changing each file.
 *   - Lints every changed PHP file.
 */

function stderr(string $message): void
{
    fwrite(STDERR, $message . PHP_EOL);
}

function usage(): never
{
    stderr(
        "Usage: php php82-signature-compat.php --backup DIR [--apply] ROOT [ROOT ...]"
    );
    exit(2);
}

$args = $argv;
array_shift($args);

$apply = false;
$backupRoot = null;
$roots = [];

while ($args !== []) {
    $arg = array_shift($args);

    if ($arg === '--apply') {
        $apply = true;
        continue;
    }

    if ($arg === '--backup') {
        $backupRoot = array_shift($args);
        if ($backupRoot === null || $backupRoot === '') {
            usage();
        }
        continue;
    }

    if (str_starts_with($arg, '--')) {
        usage();
    }

    $roots[] = $arg;
}

if ($backupRoot === null || $roots === []) {
    usage();
}

$backupRoot = rtrim($backupRoot, DIRECTORY_SEPARATOR);
if (!is_dir($backupRoot) && !mkdir($backupRoot, 0775, true) && !is_dir($backupRoot)) {
    throw new RuntimeException("Cannot create backup directory: {$backupRoot}");
}

/**
 * @return list<string>
 */
function phpFiles(array $roots): array
{
    $files = [];

    foreach ($roots as $root) {
        if (!is_dir($root)) {
            stderr("SKIP missing root: {$root}");
            continue;
        }

        $iterator = new RecursiveIteratorIterator(
            new RecursiveDirectoryIterator(
                $root,
                FilesystemIterator::SKIP_DOTS
            )
        );

        foreach ($iterator as $file) {
            if (!$file->isFile()) {
                continue;
            }

            $path = $file->getPathname();
            if (strtolower(pathinfo($path, PATHINFO_EXTENSION)) !== 'php') {
                continue;
            }

            // Third-party and generated libraries are not Chisimba application
            // classes and frequently contain legacy parser constructs or their
            // own compatibility constraints. They must not be rewritten by
            // this application-level signature pass.
            $normalisedPath = str_replace('\\', '/', $path);
            $excludedFragments = [
                '/resources/',
                '/lib/',
                '/vendor/',
                '/third_party/',
                '/third-party/',
                '/pear/',
                '/adodb/',
                '/rdfapi-php/',
            ];

            $excluded = false;
            foreach ($excludedFragments as $fragment) {
                if (str_contains(strtolower($normalisedPath), $fragment)) {
                    $excluded = true;
                    break;
                }
            }

            if ($excluded) {
                continue;
            }

            $files[] = $path;
        }
    }

    sort($files);
    return array_values(array_unique($files));
}

/**
 * Convert token_get_all() output to tokens with absolute byte offsets.
 *
 * @return list<array{id:int|null,text:string,start:int,end:int}>
 */
function offsetTokens(string $code): array
{
    $result = [];
    $offset = 0;

    foreach (token_get_all($code) as $token) {
        if (is_array($token)) {
            $id = $token[0];
            $text = $token[1];
        } else {
            $id = null;
            $text = $token;
        }

        $length = strlen($text);
        $result[] = [
            'id' => $id,
            'text' => $text,
            'start' => $offset,
            'end' => $offset + $length,
        ];
        $offset += $length;
    }

    return $result;
}

function insignificant(?int $id): bool
{
    return in_array($id, [T_WHITESPACE, T_COMMENT, T_DOC_COMMENT], true);
}

/**
 * @param list<array{id:int|null,text:string,start:int,end:int}> $tokens
 */
function nextSignificant(array $tokens, int $index, ?int $limit = null): ?int
{
    $count = count($tokens);
    $limit ??= $count;

    for ($i = $index; $i < $limit; $i++) {
        if (!insignificant($tokens[$i]['id'])) {
            return $i;
        }
    }

    return null;
}

/**
 * @param list<array{id:int|null,text:string,start:int,end:int}> $tokens
 */
function namespaceAt(array $tokens, int $classIndex): string
{
    $namespace = '';

    for ($i = 0; $i < $classIndex; $i++) {
        if ($tokens[$i]['id'] !== T_NAMESPACE) {
            continue;
        }

        $parts = [];
        for ($j = $i + 1, $n = count($tokens); $j < $n; $j++) {
            $text = $tokens[$j]['text'];
            if ($text === ';' || $text === '{') {
                break;
            }

            if (
                $tokens[$j]['id'] === T_STRING
                || $tokens[$j]['id'] === T_NS_SEPARATOR
                || (defined('T_NAME_QUALIFIED') && $tokens[$j]['id'] === T_NAME_QUALIFIED)
            ) {
                $parts[] = $text;
            }
        }

        $namespace = trim(implode('', $parts), '\\');
    }

    return $namespace;
}

/**
 * @param list<array{id:int|null,text:string,start:int,end:int}> $tokens
 */
function matchingToken(array $tokens, int $openIndex, string $open, string $close): ?int
{
    $depth = 0;
    $count = count($tokens);

    for ($i = $openIndex; $i < $count; $i++) {
        $text = $tokens[$i]['text'];

        if ($text === $open) {
            $depth++;
        } elseif ($text === $close) {
            $depth--;
            if ($depth === 0) {
                return $i;
            }
        }
    }

    return null;
}

/**
 * Split a parameter list on top-level commas.
 *
 * @return list<string>
 */
function splitParameters(string $raw): array
{
    if (trim($raw) === '') {
        return [];
    }

    $parts = [];
    $start = 0;
    $round = 0;
    $square = 0;
    $curly = 0;
    $quote = null;
    $escape = false;
    $length = strlen($raw);

    for ($i = 0; $i < $length; $i++) {
        $char = $raw[$i];

        if ($quote !== null) {
            if ($escape) {
                $escape = false;
            } elseif ($char === '\\') {
                $escape = true;
            } elseif ($char === $quote) {
                $quote = null;
            }
            continue;
        }

        if ($char === "'" || $char === '"') {
            $quote = $char;
            continue;
        }

        if ($char === '(') {
            $round++;
        } elseif ($char === ')') {
            $round--;
        } elseif ($char === '[') {
            $square++;
        } elseif ($char === ']') {
            $square--;
        } elseif ($char === '{') {
            $curly++;
        } elseif ($char === '}') {
            $curly--;
        } elseif (
            $char === ','
            && $round === 0
            && $square === 0
            && $curly === 0
        ) {
            $parts[] = trim(substr($raw, $start, $i - $start));
            $start = $i + 1;
        }
    }

    $parts[] = trim(substr($raw, $start));
    return array_values(array_filter($parts, static fn(string $p): bool => $p !== ''));
}

function optionalParameter(string $parameter): bool
{
    if (str_contains($parameter, '...')) {
        return true;
    }

    $tokens = token_get_all('<?php function x(' . $parameter . '){}');
    $round = 0;
    $square = 0;
    $curly = 0;

    foreach ($tokens as $token) {
        $text = is_array($token) ? $token[1] : $token;

        if ($text === '(') {
            $round++;
        } elseif ($text === ')') {
            $round--;
        } elseif ($text === '[') {
            $square++;
        } elseif ($text === ']') {
            $square--;
        } elseif ($text === '{') {
            $curly++;
        } elseif ($text === '}') {
            $curly--;
        } elseif ($text === '=' && $round === 1 && $square === 0 && $curly === 0) {
            return true;
        }
    }

    return false;
}

/**
 * @return list<array{
 *   name:string,fqcn:string,parentRaw:?string,namespace:string,file:string,
 *   methods:array<string,array{
 *     name:string,paramsRaw:string,params:list<string>,
 *     openOffset:int,closeOffset:int
 *   }>
 * }>
 */
function parseClasses(string $file): array
{
    $code = file_get_contents($file);
    if ($code === false) {
        throw new RuntimeException("Cannot read {$file}");
    }

    $tokens = offsetTokens($code);
    $classes = [];
    $count = count($tokens);

    for ($i = 0; $i < $count; $i++) {
        if ($tokens[$i]['id'] !== T_CLASS) {
            continue;
        }

        $previous = $i - 1;
        while ($previous >= 0 && insignificant($tokens[$previous]['id'])) {
            $previous--;
        }
        if ($previous >= 0 && $tokens[$previous]['id'] === T_NEW) {
            continue; // anonymous class
        }

        $nameIndex = nextSignificant($tokens, $i + 1);
        if ($nameIndex === null || $tokens[$nameIndex]['id'] !== T_STRING) {
            continue;
        }

        $name = $tokens[$nameIndex]['text'];
        $namespace = namespaceAt($tokens, $i);
        $fqcn = $namespace === '' ? $name : $namespace . '\\' . $name;

        $parentRaw = null;
        $bodyOpen = null;

        for ($j = $nameIndex + 1; $j < $count; $j++) {
            if ($tokens[$j]['text'] === '{') {
                $bodyOpen = $j;
                break;
            }

            if ($tokens[$j]['id'] === T_EXTENDS) {
                $parts = [];
                for ($k = $j + 1; $k < $count; $k++) {
                    if ($tokens[$k]['text'] === '{' || $tokens[$k]['id'] === T_IMPLEMENTS) {
                        break;
                    }

                    if (
                        $tokens[$k]['id'] === T_STRING
                        || $tokens[$k]['id'] === T_NS_SEPARATOR
                        || (defined('T_NAME_QUALIFIED') && $tokens[$k]['id'] === T_NAME_QUALIFIED)
                        || (defined('T_NAME_FULLY_QUALIFIED') && $tokens[$k]['id'] === T_NAME_FULLY_QUALIFIED)
                    ) {
                        $parts[] = $tokens[$k]['text'];
                    }
                }
                $parentRaw = trim(implode('', $parts), '\\');
            }
        }

        if ($bodyOpen === null) {
            continue;
        }

        $bodyClose = matchingToken($tokens, $bodyOpen, '{', '}');
        if ($bodyClose === null) {
            throw new RuntimeException("Unbalanced class body in {$file}: {$fqcn}");
        }

        $methods = [];
        $depth = 0;

        for ($j = $bodyOpen; $j <= $bodyClose; $j++) {
            $text = $tokens[$j]['text'];

            if ($text === '{') {
                $depth++;
                continue;
            }

            if ($text === '}') {
                $depth--;
                continue;
            }

            if ($depth !== 1 || $tokens[$j]['id'] !== T_FUNCTION) {
                continue;
            }

            $methodNameIndex = nextSignificant($tokens, $j + 1, $bodyClose);
            if ($methodNameIndex === null) {
                continue;
            }

            if ($tokens[$methodNameIndex]['text'] === '&') {
                $methodNameIndex = nextSignificant($tokens, $methodNameIndex + 1, $bodyClose);
            }

            if ($methodNameIndex === null || $tokens[$methodNameIndex]['id'] !== T_STRING) {
                continue; // closure
            }

            $methodName = $tokens[$methodNameIndex]['text'];
            $openIndex = nextSignificant($tokens, $methodNameIndex + 1, $bodyClose);
            if ($openIndex === null || $tokens[$openIndex]['text'] !== '(') {
                continue;
            }

            $closeIndex = matchingToken($tokens, $openIndex, '(', ')');
            if ($closeIndex === null || $closeIndex > $bodyClose) {
                throw new RuntimeException(
                    "Unbalanced method parameters in {$file}: {$fqcn}::{$methodName}"
                );
            }

            $openOffset = $tokens[$openIndex]['end'];
            $closeOffset = $tokens[$closeIndex]['start'];
            $paramsRaw = substr($code, $openOffset, $closeOffset - $openOffset);

            $methods[strtolower($methodName)] = [
                'name' => $methodName,
                'paramsRaw' => $paramsRaw,
                'params' => splitParameters($paramsRaw),
                'openOffset' => $openOffset,
                'closeOffset' => $closeOffset,
            ];
        }

        $classes[] = [
            'name' => $name,
            'fqcn' => $fqcn,
            'parentRaw' => $parentRaw,
            'namespace' => $namespace,
            'file' => $file,
            'methods' => $methods,
        ];

        $i = $bodyClose;
    }

    return $classes;
}

function resolveParent(array $class, array $byFqcn, array $byShort): ?array
{
    $raw = $class['parentRaw'];
    if ($raw === null || $raw === '') {
        return null;
    }

    $rawKey = strtolower(ltrim($raw, '\\'));
    if (isset($byFqcn[$rawKey])) {
        return $byFqcn[$rawKey];
    }

    if ($class['namespace'] !== '') {
        $candidate = strtolower($class['namespace'] . '\\' . $raw);
        if (isset($byFqcn[$candidate])) {
            return $byFqcn[$candidate];
        }
    }

    $short = strtolower(($pos = strrpos($raw, '\\')) === false ? $raw : substr($raw, $pos + 1));
    if (isset($byShort[$short]) && count($byShort[$short]) === 1) {
        return $byShort[$short][0];
    }

    return null;
}

$files = phpFiles($roots);
echo "PHP files scanned: " . count($files) . PHP_EOL;

$classes = [];
$parseSkipped = [];
$preLintSkipped = [];

foreach ($files as $file) {
    $lintCommand = 'php -l ' . escapeshellarg($file) . ' 2>&1';
    $lintOutput = [];
    $lintStatus = 0;
    exec($lintCommand, $lintOutput, $lintStatus);

    if ($lintStatus !== 0) {
        $preLintSkipped[] = [
            'file' => $file,
            'error' => implode("\n", $lintOutput),
        ];

        stderr(
            "PRELINT-SKIP: {$file}: " . implode(" | ", $lintOutput)
        );
        continue;
    }

    try {
        foreach (parseClasses($file) as $class) {
            $classes[] = $class;
        }
    } catch (Throwable $error) {
        $parseSkipped[] = [
            'file' => $file,
            'error' => $error->getMessage(),
        ];

        stderr(
            "PARSE-SKIP: {$file}: {$error->getMessage()}"
        );
    }
}

echo "Classes indexed: " . count($classes) . PHP_EOL;
echo "PHP 8 pre-lint failures skipped: " . count($preLintSkipped) . PHP_EOL;
echo "Parser-hostile files skipped: " . count($parseSkipped) . PHP_EOL;

$byFqcn = [];
$byShort = [];
foreach ($classes as $class) {
    $byFqcn[strtolower($class['fqcn'])] = $class;
    $byShort[strtolower($class['name'])][] = $class;
}

$editsByFile = [];
$findings = [];
$unresolved = [];

foreach ($classes as $child) {
    if ($child['parentRaw'] === null) {
        continue;
    }

    $parent = resolveParent($child, $byFqcn, $byShort);
    if ($parent === null) {
        $unresolved[] = "{$child['fqcn']} extends {$child['parentRaw']}";
        continue;
    }

    foreach ($child['methods'] as $methodKey => $childMethod) {
        if (!isset($parent['methods'][$methodKey])) {
            continue;
        }

        $parentMethod = $parent['methods'][$methodKey];
        $childCount = count($childMethod['params']);
        $parentCount = count($parentMethod['params']);

        if ($childCount >= $parentCount) {
            continue;
        }

        $missing = array_slice($parentMethod['params'], $childCount);
        if ($missing === []) {
            continue;
        }

        $childParameterNames = [];
        foreach ($childMethod['params'] as $childParameter) {
            if (preg_match('/\\$([A-Za-z_][A-Za-z0-9_]*)/', $childParameter, $nameMatch)) {
                $childParameterNames[strtolower($nameMatch[1])] = true;
            }
        }

        $allOptional = true;
        $duplicateName = false;

        foreach ($missing as $parameter) {
            if (!optionalParameter($parameter)) {
                $allOptional = false;
            }

            if (preg_match('/\\$([A-Za-z_][A-Za-z0-9_]*)/', $parameter, $nameMatch)) {
                if (isset($childParameterNames[strtolower($nameMatch[1])])) {
                    $duplicateName = true;
                }
            }
        }

        // Never append a parameter whose variable name is already present in
        // the child declaration, even where legacy spelling or case differs.
        // Such cases require manual review because position-based comparison
        // alone is not sufficient to prove compatibility.
        if ($duplicateName) {
            $allOptional = false;
        }

        $finding = [
            'child' => $child['fqcn'],
            'parent' => $parent['fqcn'],
            'method' => $childMethod['name'],
            'file' => $child['file'],
            'missing' => $missing,
            'safe' => $allOptional,
        ];
        $findings[] = $finding;

        if (!$allOptional) {
            continue;
        }

        $existing = trim($childMethod['paramsRaw']);
        $addition = implode(', ', $missing);
        $replacement = $existing === '' ? $addition : $existing . ', ' . $addition;

        $editsByFile[$child['file']][] = [
            'start' => $childMethod['openOffset'],
            'end' => $childMethod['closeOffset'],
            'replacement' => $replacement,
            'description' => "{$child['fqcn']}::{$childMethod['name']}",
        ];
    }
}

echo "Signature findings: " . count($findings) . PHP_EOL;

$safeCount = 0;
$unsafeCount = 0;
foreach ($findings as $finding) {
    $status = $finding['safe'] ? 'SAFE' : 'REPORT-ONLY';
    if ($finding['safe']) {
        $safeCount++;
    } else {
        $unsafeCount++;
    }

    echo sprintf(
        "%s: %s::%s extends %s; missing [%s] (%s)%s",
        $status,
        $finding['child'],
        $finding['method'],
        $finding['parent'],
        implode(', ', $finding['missing']),
        $finding['file'],
        PHP_EOL
    );
}

echo "Safe append repairs: {$safeCount}" . PHP_EOL;
echo "Non-optional/report-only mismatches: {$unsafeCount}" . PHP_EOL;
echo "Unresolved parent references: " . count($unresolved) . PHP_EOL;

if (!$apply) {
    echo "Audit only; no files changed." . PHP_EOL;
    exit(0);
}

$changed = [];

foreach ($editsByFile as $file => $edits) {
    $code = file_get_contents($file);
    if ($code === false) {
        throw new RuntimeException("Cannot read {$file}");
    }

    usort(
        $edits,
        static fn(array $a, array $b): int => $b['start'] <=> $a['start']
    );

    $backupPath = $backupRoot . DIRECTORY_SEPARATOR . ltrim($file, DIRECTORY_SEPARATOR);
    $backupDir = dirname($backupPath);
    if (!is_dir($backupDir) && !mkdir($backupDir, 0775, true) && !is_dir($backupDir)) {
        throw new RuntimeException("Cannot create backup directory {$backupDir}");
    }

    if (!copy($file, $backupPath)) {
        throw new RuntimeException("Cannot back up {$file}");
    }

    foreach ($edits as $edit) {
        $code = substr($code, 0, $edit['start'])
            . $edit['replacement']
            . substr($code, $edit['end']);
    }

    if (file_put_contents($file, $code) === false) {
        throw new RuntimeException("Cannot write {$file}");
    }

    $command = 'php -l ' . escapeshellarg($file) . ' 2>&1';
    exec($command, $lintOutput, $lintStatus);

    if ($lintStatus !== 0) {
        copy($backupPath, $file);

        stderr(
            "PATCH-LINT-SKIP: restored {$file}: "
            . implode(" | ", $lintOutput)
        );
        continue;
    }

    echo "PATCHED: {$file}" . PHP_EOL;
    foreach ($edits as $edit) {
        echo "  - {$edit['description']}" . PHP_EOL;
    }

    $changed[] = $file;
}

$manifest = $backupRoot . DIRECTORY_SEPARATOR . 'changed-files.txt';
file_put_contents(
    $manifest,
    implode(PHP_EOL, $changed) . ($changed !== [] ? PHP_EOL : '')
);

$preLintReport = $backupRoot . DIRECTORY_SEPARATOR . 'prelint-skipped.txt';
$preLintLines = [];
foreach ($preLintSkipped as $skip) {
    $preLintLines[] = $skip['file'] . " :: " . str_replace("\n", " | ", $skip['error']);
}
file_put_contents(
    $preLintReport,
    implode(PHP_EOL, $preLintLines) . ($preLintLines !== [] ? PHP_EOL : '')
);

$skipReport = $backupRoot . DIRECTORY_SEPARATOR . 'parser-skipped.txt';
$skipLines = [];
foreach ($parseSkipped as $skip) {
    $skipLines[] = $skip['file'] . " :: " . $skip['error'];
}
file_put_contents(
    $skipReport,
    implode(PHP_EOL, $skipLines) . ($skipLines !== [] ? PHP_EOL : '')
);

echo "Files changed: " . count($changed) . PHP_EOL;
echo "Manifest: {$manifest}" . PHP_EOL;
echo "Pre-lint skip report: {$preLintReport}" . PHP_EOL;
echo "Parser skip report: {$skipReport}" . PHP_EOL;
