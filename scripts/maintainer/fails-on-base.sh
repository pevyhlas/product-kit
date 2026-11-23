#!/usr/bin/env bash
# CI runs each snapshot on its own hosted runner. Compare consumes data only.
set -euo pipefail
inconclusive() { echo "INCONCLUSIVE: $*" >&2; exit 2; }
case "${1:-}:$#" in
    run:3|compare:5) ;;
    *) inconclusive 'usage: run SUITES.z RESULT.json | compare SUITES.z BASE.json HEAD.json PR_TITLE' ;;
esac

scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
# git diff --name-only -z: never split filenames on whitespace or read an
# unterminated last entry. The plan is independent of both result producers.
: > "$scratch/paths"
while :; do
    path=''
    if ! IFS= read -r -d '' path; then
        [ -z "$path" ] || inconclusive 'truncated suite list'
        break
    fi
    case "$path" in tests/*/*) inconclusive 'nested test path' ;; tests/test_*.sh) ;; *) inconclusive 'invalid test path' ;; esac
    jq -cn --arg path "$path" '$path' >> "$scratch/paths"
done < "${2:?}" || inconclusive 'unreadable suite list'
jq -se 'select(length > 0 and length == (unique|length))' "$scratch/paths" > "$scratch/plan" ||
    inconclusive 'empty or duplicate suite list'

if [ "$1" = run ]; then
    result=$3
    rm -f -- "$result"
    while IFS= read -r -d '' path; do
        [ -f "$path" ] && [ ! -L "$path" ] || inconclusive "cannot run $path"
        status=0
        (unset GITHUB_STEP_SUMMARY; exec bash "$path") </dev/null > "$scratch/log" 2>&1 || status=$?
        # Keep just the harness summary and, for failures, at most 4 KiB / 12 lines.
        LC_ALL=C awk '/^(PASS: [0-9]+ assertion\(s\)|FAIL: [0-9]+ failed, [0-9]+ passed)$/ { s=substr($0,1,120) }
            END { printf "%s", s }' "$scratch/log" > "$scratch/summary"
        : > "$scratch/excerpt"
        if [ "$status" -ne 0 ]; then
            tail -c 4096 "$scratch/log" | tail -n 12 | LC_ALL=C tr -d '\000-\010\013-\037\177' > "$scratch/excerpt"
        fi
        jq -cn --arg suite "$path" --argjson status "$status" --rawfile summary "$scratch/summary" \
            --rawfile excerpt "$scratch/excerpt" '{suite:$suite,status:$status,summary:$summary,excerpt:$excerpt}' >> "$scratch/rows"
    done < "$2"
    jq -s . "$scratch/rows" > "$result"
    exit 0
fi

# Slurp each file separately: reject empty, multiple or incomplete documents,
# including matching omissions from both snapshots.
jq -ne --slurpfile plan "$scratch/plan" --slurpfile base "$3" --slurpfile head "$4" '
    def valid:
        length == 1 and (.[0] | type == "array" and map(.suite) == $plan[0] and
            all(.[]; (.status | type == "number" and floor == . and . >= 0 and . <= 255)
                and (.summary | type == "string" and length <= 120)
                and (.excerpt | type == "string" and length <= 4096)));
    ($base|valid) and ($head|valid)' >/dev/null || inconclusive 'missing, malformed or incomplete snapshot results'

fix='^fix(\([^)]+\))?!?:'
mode=advisory
if [[ $5 =~ $fix ]]; then mode=required; fi
echo "### Fails before the fix ($mode)"
jq -nr --slurpfile b "$3" --slurpfile h "$4" '
    def outcome: if .status == 0 then "PASS" else "FAIL (exit \(.status))" end;
    def details($side): select(.summary != "" or .excerpt != "") |
        "<details><summary>\($side) output</summary><pre>\((.summary + "\n" + .excerpt)|@html)</pre></details>";
    range(0; $b[0]|length) as $i | $b[0][$i] as $base | $h[0][$i] as $head |
        "\n- <code>\($base.suite|@html)</code> — Base: \($base|outcome); Head: \($head|outcome).",
        ($base|details("Base")), ($head|details("Head"))'
count=$(jq -nr --slurpfile b "$3" --slurpfile h "$4" '
    [range(0; $b[0]|length) as $i | select($b[0][$i].status != 0 and $h[0][$i].status == 0)] | length')
printf '\n%s of %s changed test suite(s) fail on base and pass on head.\n' "$count" "$(jq length "$scratch/plan")"
if [ "$mode" = required ] && [ "$count" = 0 ]; then exit 1; fi
