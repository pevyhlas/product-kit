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
            # Read one UTF-8 character of lookbehind, then trim whole characters
            # after decoding. A partial character at the start cannot reach the result.
            tail -c 4100 "$scratch/log" | jq -Rsj 'until(utf8bytelength <= 4096; .[1:])' |
                tail -n 12 | LC_ALL=C tr -d '\000-\010\013-\037\177' > "$scratch/excerpt"
        fi
        jq -cn --arg suite "$path" --argjson status "$status" --rawfile summary "$scratch/summary" \
            --rawfile excerpt "$scratch/excerpt" '{suite:$suite,status:$status,summary:$summary,excerpt:$excerpt}' >> "$scratch/rows"
    done < "$2"
    jq -cSs . "$scratch/rows" > "$result"
    exit 0
fi

# jq accepts some non-JSON numbers and silently discards duplicate keys. Require
# the producer's exact bytes, then report and count only from these checked copies.
validate() {
    jq -cSes --slurpfile plan "$scratch/plan" '
        select(length == 1) | .[0] |
        select(type == "array" and map(.suite) == $plan[0] and
            all(.[]; keys == ["excerpt","status","suite","summary"] and
                (.status | type == "number" and floor == . and . >= 0 and . <= 255)
                and (.summary | type == "string" and length <= 120)
                and (.status != 0 or .excerpt == "")
                and (.excerpt | type == "string" and utf8bytelength <= 4096 and
                    (rtrimstr("\n") | split("\n") | length) <= 12))) |
        map(.status += 0)' "$1" > "$2" ||
        inconclusive 'missing, malformed or incomplete snapshot results'
    cmp -s "$1" "$2" || inconclusive 'noncanonical snapshot results'
}
validate "$3" "$scratch/base"
validate "$4" "$scratch/head"

fix='^fix(\([^)]+\))?!?:'
mode=advisory
if [[ $5 =~ $fix ]]; then mode=required; fi
echo "### Fails before the fix ($mode)"
# ASCII JSON spelling keeps even Unicode control characters visible on one line.
jq -a '.[] | .suite' "$scratch/base" > "$scratch/names"
jq -nr --slurpfile b "$scratch/base" --slurpfile h "$scratch/head" --rawfile names "$scratch/names" '
    def outcome: if .status == 0 then "PASS" else "FAIL (exit \(.status))" end;
    def code_span:
        ("`" * ([0, (scan("`+") | length)] | max + 1)) as $delimiter |
        (if startswith("`") or endswith("`") then " " else "" end) as $pad |
        $delimiter + $pad + . + $pad + $delimiter;
    def details($side): select(.summary != "" or .excerpt != "") |
        ([.summary,.excerpt] | map(select(length > 0)) | join("\n") | rtrimstr("\n")) as $text |
        ([2, ($text | scan("`+") | length)] | max + 1) as $width |
        ("`" * $width) as $fence |
        "\n\($side) output:\n\n\($fence)\n\($text)\n\($fence)\n";
    range(0; $b[0]|length) as $i | $b[0][$i] as $base | $h[0][$i] as $head |
        "\n- \(($names | split("\n"))[$i][1:-1]|code_span) — Base: \($base|outcome); Head: \($head|outcome).",
        ($base|details("Base")), ($head|details("Head"))'
count=$(jq -nr --slurpfile b "$scratch/base" --slurpfile h "$scratch/head" '
    [range(0; $b[0]|length) as $i | select($b[0][$i].status != 0 and $h[0][$i].status == 0)] | length')
printf '\n%s of %s changed test suite(s) fail on base and pass on head.\n' "$count" "$(jq length "$scratch/plan")"
if [ "$mode" = required ] && [ "$count" = 0 ]; then exit 1; fi
