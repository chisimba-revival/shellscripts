# PHP Structure Tool

`php-structure-tool.py` performs token-based structural operations on legacy PHP
class methods.

Supported operations:

- `list-methods`
- `rename-method`
- `insert-before`
- `insert-after`

PHP's `token_get_all()` supplies exact byte offsets. Method discovery does not
depend on whitespace, line breaks, modifiers or reference-return syntax.

Every candidate is checked with `php -l`. Writes are atomic, backups are enabled
by default, and `--dry-run` prints a unified diff without modifying the file.
