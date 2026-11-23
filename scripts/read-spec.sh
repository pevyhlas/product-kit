#!/usr/bin/env bash
# Read routine spec context with original line numbers; raw source remains the review artifact.
set -euo pipefail
SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/spec-lib.sh"
mode=compact; target=""; path=""
usage() { echo 'Usage: read-spec.sh [--raw | --stats | --target <nav-key>] specs/<file>.md'; }
while [ "$#" -gt 0 ]; do
    case "$1" in
        --raw|--stats)
            [ "$mode" = compact ] || { usage >&2; exit 2; }
            mode="${1#--}" ;;
        --target)
            [ "$mode" = compact ] && [ "$#" -gt 1 ] || { usage >&2; exit 2; }
            mode=target; shift; target="$1" ;;
        --help|-h) usage; exit 0 ;;
        -*) usage >&2; exit 2 ;;
        *)
            [ -z "$path" ] || { usage >&2; exit 2; }
            path="$1" ;;
    esac
    shift
done
case "$path" in specs/*.md) ;; *) usage >&2; exit 2 ;; esac
case "/$path/" in */../*|*/./*|*//*)
    echo 'Use a repository-relative spec path without dot components.' >&2; exit 2 ;;
esac
if [[ "$path" =~ [[:cntrl:]] ]]; then echo 'Control characters in source paths are unsupported.' >&2; exit 2; fi
root="$(get_repo_root)"
require_consumer_root "$root" read-spec.sh
spec_require_layout "$root" || exit 1
file="$root/$path"
[ -f "$file" ] || { printf 'No source file: %s\n' "$path" >&2; exit 2; }
snapshot="$(mktemp)"
trap 'rm -f "$snapshot"' EXIT
cat "$file" > "$snapshot"
cmp -s "$file" "$snapshot" || { printf 'Incomplete spec snapshot: %s\n' "$path" >&2; exit 1; }
if [ "$mode" = raw ]; then cat "$snapshot"; exit 0; fi
if ! verify_lf_file "$snapshot"; then
    printf 'Invalid spec text: %s (expected non-empty LF-terminated text; use --raw to inspect it)\n' "$path" >&2
    exit 1
fi
expected_lines="$(wc -l < "$snapshot")"
expected_bytes="$(wc -c < "$snapshot")"
head="$(GIT_NO_LAZY_FETCH=1 git -C "$root" rev-parse --verify HEAD 2>/dev/null)" || head=uncommitted
blob="$(git -C "$root" hash-object --no-filters -- "$snapshot")"
printf 'Source: %s head=%s content_blob=%s (working-tree bytes; not a committed-snapshot claim)\n' "$path" "$head" "$blob"
spec_navigation "$snapshot" stats '' "$expected_lines" "$expected_bytes"
spec_navigation "$snapshot" diagnostics '' "$expected_lines" "$expected_bytes" >&2
if [ "$mode" = compact ]; then
    spec_navigation "$snapshot" compact '' "$expected_lines" "$expected_bytes"
elif [ "$mode" = target ]; then
    if ! spec_navigation "$snapshot" target "$target" "$expected_lines" "$expected_bytes"; then
        printf 'No validated navigation target for %s; use --raw to inspect the source.\n' "$target" >&2
        exit 1
    fi
fi
