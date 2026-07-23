#!/usr/bin/env python3
"""Token-based structural refactoring operations for legacy PHP class files."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from typing import Any


class ToolError(RuntimeError):
    pass


def run(command: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def inspect_php(path: Path) -> list[dict[str, Any]]:
    php = r"""
$path = $argv[1];
$code = file_get_contents($path);
if ($code === false) {
    fwrite(STDERR, "Unable to read file.\n");
    exit(10);
}

try {
    $tokens = token_get_all($code, TOKEN_PARSE);
} catch (ParseError $e) {
    fwrite(STDERR, $e->getMessage() . "\n");
    exit(11);
}

$count = count($tokens);
$offsets = [];
$offset = 0;

for ($i = 0; $i < $count; $i++) {
    $offsets[$i] = $offset;
    $offset += strlen(is_array($tokens[$i]) ? $tokens[$i][1] : $tokens[$i]);
}

$methods = [];

for ($i = 0; $i < $count; $i++) {
    $token = $tokens[$i];
    if (!is_array($token) || $token[0] !== T_FUNCTION) {
        continue;
    }

    $j = $i + 1;
    while ($j < $count) {
        $candidate = $tokens[$j];
        if (is_array($candidate) &&
            in_array($candidate[0], [T_WHITESPACE, T_COMMENT, T_DOC_COMMENT], true)) {
            $j++;
            continue;
        }
        if ($candidate === '&') {
            $j++;
            continue;
        }
        break;
    }

    if ($j >= $count || !is_array($tokens[$j]) || $tokens[$j][0] !== T_STRING) {
        continue;
    }

    $name = $tokens[$j][1];
    $nameStart = $offsets[$j];
    $nameEnd = $nameStart + strlen($name);

    $k = $j + 1;
    $bodyOpenToken = null;
    while ($k < $count) {
        $piece = $tokens[$k];
        $pieceText = is_array($piece) ? $piece[1] : $piece;
        if ($pieceText === ';') {
            break;
        }
        if ($pieceText === '{') {
            $bodyOpenToken = $k;
            break;
        }
        $k++;
    }

    if ($bodyOpenToken === null) {
        continue;
    }

    $depth = 0;
    $bodyCloseToken = null;
    for ($m = $bodyOpenToken; $m < $count; $m++) {
        $piece = $tokens[$m];
        $pieceText = is_array($piece) ? $piece[1] : $piece;

        if ($pieceText === '{') {
            $depth++;
        } elseif ($pieceText === '}') {
            $depth--;
            if ($depth === 0) {
                $bodyCloseToken = $m;
                break;
            }
        }
    }

    if ($bodyCloseToken === null) {
        fwrite(STDERR, "Unclosed method body for {$name}.\n");
        exit(12);
    }

    $declarationStart = $offsets[$i];
    $p = $i - 1;

    while ($p >= 0) {
        $previous = $tokens[$p];
        if (is_array($previous) &&
            in_array(
                $previous[0],
                [
                    T_WHITESPACE,
                    T_COMMENT,
                    T_DOC_COMMENT,
                    T_PUBLIC,
                    T_PROTECTED,
                    T_PRIVATE,
                    T_STATIC,
                    T_ABSTRACT,
                    T_FINAL
                ],
                true
            )) {
            $declarationStart = $offsets[$p];
            $p--;
            continue;
        }
        break;
    }

    $methods[] = [
        'name' => $name,
        'name_start' => $nameStart,
        'name_end' => $nameEnd,
        'declaration_start' => $declarationStart,
        'function_start' => $offsets[$i],
        'body_open' => $offsets[$bodyOpenToken],
        'body_close' => $offsets[$bodyCloseToken],
        'method_end' => $offsets[$bodyCloseToken] + 1,
    ];
}

echo json_encode($methods, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES);
"""
    proc = run(["php", "-r", php, str(path)])
    if proc.returncode != 0:
        raise ToolError(proc.stderr.strip() or "PHP token inspection failed.")
    try:
        result = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise ToolError(f"Invalid tokenizer output: {exc}") from exc
    if not isinstance(result, list):
        raise ToolError("Unexpected tokenizer result.")
    return result


def lint(path: Path) -> None:
    proc = run(["php", "-l", str(path)])
    if proc.returncode != 0:
        raise ToolError(proc.stdout.strip() or proc.stderr.strip())


def select_method(methods: list[dict[str, Any]], name: str, occurrence: int) -> dict[str, Any]:
    matches = [item for item in methods if item["name"] == name]
    if not matches:
        raise ToolError(f"Method not found: {name}")
    if occurrence < 1 or occurrence > len(matches):
        raise ToolError(
            f"Method {name} has {len(matches)} occurrence(s); "
            f"requested occurrence {occurrence}."
        )
    return matches[occurrence - 1]


def line_indent(source: str, offset: int) -> str:
    start = source.rfind("\n", 0, offset) + 1
    prefix = source[start:offset]
    return prefix[: len(prefix) - len(prefix.lstrip(" \t"))]


def normalize_method_text(text: str, indent: str) -> str:
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    while lines and not lines[0].strip():
        lines.pop(0)
    while lines and not lines[-1].strip():
        lines.pop()

    if not lines:
        raise ToolError("Inserted method text is empty.")

    nonblank = [line for line in lines if line.strip()]
    minimum = min(len(line) - len(line.lstrip(" \t")) for line in nonblank)

    output: list[str] = []
    for line in lines:
        if line.strip():
            output.append(indent + line[minimum:])
        else:
            output.append("")
    return "\n".join(output)


def commit_change(
    path: Path,
    original: str,
    changed: str,
    *,
    backup_suffix: str,
    dry_run: bool,
) -> None:
    if changed == original:
        raise ToolError("Operation produced no change.")

    with tempfile.TemporaryDirectory(prefix="php-structure-tool-") as temp:
        temp_dir = Path(temp)
        before = temp_dir / "before.php"
        after = temp_dir / "after.php"
        before.write_text(original, encoding="utf-8")
        after.write_text(changed, encoding="utf-8")
        lint(after)

        diff_proc = run(["diff", "-u", str(before), str(after)])
        print(diff_proc.stdout, end="")

        if dry_run:
            return

        if backup_suffix:
            backup = Path(str(path) + backup_suffix)
            shutil.copy2(path, backup)
            print(f"Backup: {backup}")

        mode = path.stat().st_mode
        temporary = path.with_name(path.name + ".php-structure-tool.tmp")
        temporary.write_text(changed, encoding="utf-8")
        os.chmod(temporary, mode)
        os.replace(temporary, path)
        lint(path)
        print(f"Updated: {path}")


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Token-based structural operations for PHP class methods."
    )
    parser.add_argument("--file", required=True, help="PHP source file")
    parser.add_argument("--backup-suffix", default=".bak")
    parser.add_argument("--dry-run", action="store_true")

    sub = parser.add_subparsers(dest="operation", required=True)
    sub.add_parser("list-methods")

    rename = sub.add_parser("rename-method")
    rename.add_argument("--from", dest="old_name", required=True)
    rename.add_argument("--to", dest="new_name", required=True)
    rename.add_argument("--occurrence", type=int, default=1)

    before = sub.add_parser("insert-before")
    before.add_argument("--anchor", required=True)
    before.add_argument("--method-file", required=True)
    before.add_argument("--occurrence", type=int, default=1)

    after = sub.add_parser("insert-after")
    after.add_argument("--anchor", required=True)
    after.add_argument("--method-file", required=True)
    after.add_argument("--occurrence", type=int, default=1)

    return parser


def main() -> int:
    args = build_parser().parse_args()
    path = Path(args.file).resolve()
    if not path.is_file():
        raise ToolError(f"PHP file not found: {path}")

    lint(path)
    source = path.read_text(encoding="utf-8")
    methods = inspect_php(path)

    if args.operation == "list-methods":
        for index, method in enumerate(methods, start=1):
            print(
                f"{index:03d} {method['name']} "
                f"declaration={method['declaration_start']} "
                f"body={method['body_open']}:{method['body_close']}"
            )
        return 0

    if args.operation == "rename-method":
        target = select_method(methods, args.old_name, args.occurrence)
        if any(item["name"] == args.new_name for item in methods):
            raise ToolError(f"Destination method already exists: {args.new_name}")
        changed = (
            source[: int(target["name_start"])]
            + args.new_name
            + source[int(target["name_end"]) :]
        )
        commit_change(
            path,
            source,
            changed,
            backup_suffix=args.backup_suffix,
            dry_run=args.dry_run,
        )
        return 0

    target = select_method(methods, args.anchor, args.occurrence)
    method_text = Path(args.method_file).read_text(encoding="utf-8")

    if args.operation == "insert-before":
        insertion = int(target["declaration_start"])
        indent = line_indent(source, int(target["function_start"]))
        normalized = normalize_method_text(method_text, indent)
        changed = source[:insertion] + normalized + "\n\n" + source[insertion:]
    else:
        insertion = int(target["method_end"])
        indent = line_indent(source, int(target["function_start"]))
        normalized = normalize_method_text(method_text, indent)
        changed = source[:insertion] + "\n\n" + normalized + source[insertion:]

    commit_change(
        path,
        source,
        changed,
        backup_suffix=args.backup_suffix,
        dry_run=args.dry_run,
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ToolError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(1)
