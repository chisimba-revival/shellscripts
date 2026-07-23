# PHP Method Patcher

`php-method-patcher.py` replaces the body of one named PHP method.

It uses PHP's `token_get_all()` parser, so it does not depend on legacy
whitespace or formatting.

## Safety

- preserves signatures and surrounding comments;
- handles nested braces;
- validates with `php -l` before writing;
- creates a backup by default;
- writes atomically;
- supports dry-run unified diffs.

## Usage

```bash
php-method-patcher.py \
  --file /path/to/class.php \
  --method methodName \
  --body-file /path/to/new-body.txt
```

The body file contains only statements inside the method braces.

## Exit codes

- `0`: success
- `1`: input, patch, or validation error
- `2`: method not found
- `3`: requested occurrence does not exist
