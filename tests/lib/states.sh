#!/usr/bin/env bash
# Called from suites using tests/lib.sh. Capture plan generation separately:
# a failed producer must never look like an empty, passing set of cases.
generated_states() {
    local lane="$1" source="$2" cases row
    local -a words
    if ! python3 -I -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null; then
        echo "SKIP: generated $lane states require python3 3.11+ (isolated mode)" >&2
        return 0
    fi
    cases="$(python3 -I "$TESTS_DIR/lib/states.py" plan "$lane")" &&
        [ -n "$cases" ] || { _no "could not generate $lane plan"; return 1; }
    while IFS= read -r row; do
        read -r -a words <<< "$row"
        run python3 -I "$TESTS_DIR/lib/states.py" "$lane" "$source" "${words[@]}"
        assert_eq 0 "$STATUS" "generated $lane $row: $OUTPUT"
    done <<< "$cases"
}
