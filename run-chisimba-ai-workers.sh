#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Run or check the Chisimba background workers that use the shared AI service.

Usage:
  run-chisimba-ai-workers.sh check [--container NAME]
  run-chisimba-ai-workers.sh run [--container NAME] [--worksheet-batch N] [--essay-batch N] [--quiz-batch N]

Options:
  --container NAME       PHP container (default: chisimba-php85-web)
  --worksheet-batch N    Worksheet jobs per run, 1-20 (default: 5)
  --essay-batch N        Essay jobs per run, 1-20 (default: 5)
  --quiz-batch N         Chapter-quiz steps per run, 1-50 (default: 20)
  --docker PATH          Docker executable (default: discovered on PATH)
  --lock-file PATH       Host lock file (default: /tmp/chisimba-ai-workers.lock)
  --help                 Show this help

The script runs the worksheet-marking, essay-marking and chapter-quiz queues sequentially.
It does not contain or require an AI provider key; workers read Chisimba's
protected shared-AI configuration inside the PHP container.
EOF
}

action="${1:-}"
if [[ "$action" == "--help" || "$action" == "-h" ]]; then usage; exit 0; fi
if [[ "$action" != "check" && "$action" != "run" ]]; then usage >&2; exit 64; fi
shift

container_name="chisimba-php85-web"
worksheet_batch=5
essay_batch=5
quiz_batch=20
docker_binary="$(command -v docker || true)"
lock_file="/tmp/chisimba-ai-workers.lock"

while (( $# > 0 )); do
    case "$1" in
        --container) container_name="${2:?Missing value for --container}"; shift 2 ;;
        --worksheet-batch) worksheet_batch="${2:?Missing value for --worksheet-batch}"; shift 2 ;;
        --essay-batch) essay_batch="${2:?Missing value for --essay-batch}"; shift 2 ;;
        --quiz-batch) quiz_batch="${2:?Missing value for --quiz-batch}"; shift 2 ;;
        --docker) docker_binary="${2:?Missing value for --docker}"; shift 2 ;;
        --lock-file) lock_file="${2:?Missing value for --lock-file}"; shift 2 ;;
        --help|-h) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 64 ;;
    esac
done

[[ "$worksheet_batch" =~ ^([1-9]|1[0-9]|20)$ ]] || { echo "Worksheet batch must be from 1 to 20." >&2; exit 64; }
[[ "$essay_batch" =~ ^([1-9]|1[0-9]|20)$ ]] || { echo "Essay batch must be from 1 to 20." >&2; exit 64; }
[[ "$quiz_batch" =~ ^([1-9]|[1-4][0-9]|50)$ ]] || { echo "Quiz batch must be from 1 to 50." >&2; exit 64; }
[[ -n "$docker_binary" && -x "$docker_binary" ]] || { echo "Docker executable not found." >&2; exit 69; }

if [[ "$("$docker_binary" inspect --format '{{.State.Running}}' "$container_name" 2>/dev/null || true)" != "true" ]]; then
    echo "PHP container is not running: $container_name" >&2
    exit 69
fi

find_worker() {
    local module="$1" script="$2" candidate
    for candidate in \
        "/var/www/html/ch/packages/$module/scripts/$script" \
        "/var/www/html/packages/$module/scripts/$script" \
        "/var/www/html/ch/modules/$module/scripts/$script"
    do
        if "$docker_binary" exec "$container_name" test -f "$candidate"; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

worksheet_worker="$(find_worker worksheet run_ai_marking_worker.php || true)"
essay_worker="$(find_worker essay run_ai_marking_worker.php || true)"
quiz_worker="$(find_worker mcqtests run_chapter_quiz_worker.php || true)"

[[ -n "$worksheet_worker" ]] || { echo "Worksheet AI worker was not found in a supported mounted module path." >&2; exit 66; }
[[ -n "$essay_worker" ]] || { echo "Essay AI worker was not found in a supported mounted module path." >&2; exit 66; }
[[ -n "$quiz_worker" ]] || { echo "Chapter-quiz AI worker was not found in a supported mounted module path." >&2; exit 66; }

if [[ "$action" == "check" ]]; then
    printf 'Container: %s (running)\n' "$container_name"
    printf 'Worksheet worker: %s\n' "$worksheet_worker"
    printf 'Essay worker: %s\n' "$essay_worker"
    printf 'Chapter-quiz worker: %s\n' "$quiz_worker"
    exit 0
fi

run_workers() {
    local output
    output="$("$docker_binary" exec "$container_name" php "$worksheet_worker" "$worksheet_batch" 2>&1)" || {
        printf 'worksheet: %s\n' "$output" >&2
        return 1
    }
    printf 'worksheet: %s\n' "$(printf '%s\n' "$output" | awk '/^\{"selected":/{line=$0} END{print line}')"

    output="$("$docker_binary" exec "$container_name" php "$essay_worker" "$essay_batch" 2>&1)" || {
        printf 'essay: %s\n' "$output" >&2
        return 1
    }
    printf 'essay: %s\n' "$(printf '%s\n' "$output" | awk '/^\{"selected":/{line=$0} END{print line}')"

    output="$("$docker_binary" exec "$container_name" php "$quiz_worker" "$quiz_batch" 2>&1)" || {
        printf 'chapter-quiz: %s\n' "$output" >&2
        return 1
    }
    printf 'chapter-quiz: %s\n' "$(printf '%s\n' "$output" | awk '/^\{"selected":/{line=$0} END{print line}')"
}

exec 9>"$lock_file"
if ! /usr/bin/flock --nonblock 9; then
    echo "Another Chisimba AI worker run is already active; this run was skipped."
    exit 0
fi
run_workers
