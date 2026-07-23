#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


class PatchError(RuntimeError):
    pass


def run(command: list[str], input_text: str | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def php_method_ranges(path: Path, method: str) -> list[dict[str, int | str]]:
    php_code = r'''
$path = $argv[1];
$wanted = $argv[2];
$code = file_get_contents($path);
if ($code === false) {
    fwrite(STDERR, "Unable to read PHP file.\n");
    exit(10);
}
try {
    $tokens = token_get_all($code, TOKEN_PARSE);
} catch (ParseError $e) {
    fwrite(STDERR, $e->getMessage() . "\n");
    exit(11);
}
$offset = 0;
$count = count($tokens);
$results = [];
for ($i = 0; $i < $count; $i++) {
    $token = $tokens[$i];
    $text = is_array($token) ? $token[1] : $token;
    $tokenStart = $offset;
    $offset += strlen($text);
    if (!is_array($token) || $token[0] !== T_FUNCTION) {
        continue;
    }
    $j = $i + 1;
    $scanOffset = $offset;
    while ($j < $count) {
        $next = $tokens[$j];
        $nextText = is_array($next) ? $next[1] : $next;
        if (is_array($next) && in_array($next[0], [T_WHITESPACE, T_COMMENT, T_DOC_COMMENT], true)) {
            $scanOffset += strlen($nextText);
            $j++;
            continue;
        }
        if ($nextText === '&') {
            $scanOffset += strlen($nextText);
            $j++;
            continue;
        }
        break;
    }
    if ($j >= $count || !is_array($tokens[$j]) || $tokens[$j][0] !== T_STRING) {
        continue;
    }
    $name = $tokens[$j][1];
    if ($name !== $wanted) {
        continue;
    }
    $k = $j + 1;
    $bodyOpen = null;
    $cursor = $scanOffset + strlen($name);
    while ($k < $count) {
        $piece = $tokens[$k];
        $pieceText = is_array($piece) ? $piece[1] : $piece;
        if ($pieceText === ';') {
            break;
        }
        if ($pieceText === '{') {
            $bodyOpen = $cursor;
            break;
        }
        $cursor += strlen($pieceText);
        $k++;
    }
    if ($bodyOpen === null) {
        continue;
    }
    $depth = 0;
    $bodyClose = null;
    $cursor = $bodyOpen;
    for (; $k < $count; $k++) {
        $piece = $tokens[$k];
        $pieceText = is_array($piece) ? $piece[1] : $piece;
        if ($pieceText === '{') {
            $depth++;
        } elseif ($pieceText === '}') {
            $depth--;
            if ($depth === 0) {
                $bodyClose = $cursor;
                break;
            }
        }
        $cursor += strlen($pieceText);
    }
    if ($bodyClose === null) {
        fwrite(STDERR, "Could not find closing brace.\n");
        exit(12);
    }
    $results[] = [
        'method' => $name,
        'function_token_start' => $tokenStart,
        'body_open' => $bodyOpen,
        'body_close' => $bodyClose,
    ];
}
echo json_encode($results, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
'''
    proc = run(["php", "-r", php_code, str(path), method])
    if proc.returncode != 0:
        raise PatchError(proc.stderr.strip() or "PHP tokenizer failed")
    try:
        result = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise PatchError(f"Invalid tokenizer response: {exc}") from exc
    if not isinstance(result, list):
        raise PatchError("Unexpected tokenizer response")
    return result


def detect_indent(source: str, body_open: int) -> tuple[str, str]:
    line_start = source.rfind("\n", 0, body_open) + 1
    signature_line = source[line_start:body_open]
    method_indent = signature_line[: len(signature_line) - len(signature_line.lstrip(" \t"))]
    return method_indent, method_indent + "    "


def normalize_body(body: str, body_indent: str, method_indent: str) -> str:
    lines = body.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()
    if not lines:
        return "\n" + method_indent
    nonblank = [line for line in lines if line.strip()]
    min_indent = min(len(line) - len(line.lstrip(" \t")) for line in nonblank)
    output: list[str] = []
    for line in lines:
        output.append("" if not line.strip() else body_indent + line[min_indent:])
    return "\n" + "\n".join(output) + "\n" + method_indent


def validate_php(path: Path) -> None:
    proc = run(["php", "-l", str(path)])
    if proc.returncode != 0:
        raise PatchError(proc.stdout.strip() or proc.stderr.strip() or "PHP syntax validation failed")


def main() -> int:
    parser = argparse.ArgumentParser(description="Replace one PHP method body structurally")
    parser.add_argument("--file", required=True)
    parser.add_argument("--method", required=True)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--body-file")
    group.add_argument("--body")
    parser.add_argument("--backup-suffix", default=".bak")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--no-lint", action="store_true")
    parser.add_argument("--occurrence", type=int, default=1)
    args = parser.parse_args()

    path = Path(args.file).resolve()
    if not path.is_file():
        raise PatchError(f"PHP file not found: {path}")
    if args.occurrence < 1:
        raise PatchError("--occurrence must be at least 1")

    source = path.read_text(encoding="utf-8")
    body = Path(args.body_file).read_text(encoding="utf-8") if args.body_file else str(args.body)
    ranges = php_method_ranges(path, args.method)
    if not ranges:
        print(f"Method not found: {args.method}", file=sys.stderr)
        return 2
    if args.occurrence > len(ranges):
        print(f"Requested occurrence {args.occurrence}, but only {len(ranges)} match(es) exist", file=sys.stderr)
        return 3

    target = ranges[args.occurrence - 1]
    body_open = int(target["body_open"])
    body_close = int(target["body_close"])
    method_indent, body_indent = detect_indent(source, body_open)
    replacement = normalize_body(body, body_indent, method_indent)
    patched = source[: body_open + 1] + replacement + source[body_close:]
    if patched == source:
        raise PatchError("Replacement produced no change")

    with tempfile.TemporaryDirectory(prefix="php-method-patcher-") as tmp:
        before = Path(tmp) / "before.php"
        candidate = Path(tmp) / path.name
        before.write_text(source, encoding="utf-8")
        candidate.write_text(patched, encoding="utf-8")
        if not args.no_lint:
            validate_php(candidate)
        diff_proc = run(["diff", "-u", str(before), str(candidate)])
        if args.dry_run:
            print(diff_proc.stdout, end="")
            return 0
        if args.backup_suffix:
            backup = Path(str(path) + args.backup_suffix)
            shutil.copy2(path, backup)
            print(f"Backup: {backup}")
        original_mode = path.stat().st_mode
        temp_target = path.with_name(path.name + ".php-method-patcher.tmp")
        temp_target.write_text(patched, encoding="utf-8")
        os.chmod(temp_target, original_mode)
        os.replace(temp_target, path)
        if not args.no_lint:
            validate_php(path)
        print(diff_proc.stdout, end="")
        print(f"Patched: {path}")
        print(f"Method:  {args.method}")
        print("PHP syntax: PASS" if not args.no_lint else "PHP syntax: SKIPPED")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except PatchError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
