#!/usr/bin/env bash
# Local report formatting only: no publication, review authority or merge decision.
set -uo pipefail

usage() {
    cat <<'EOF'
Usage:
  review-report.sh scaffold --reviewer NAME --harness HARNESS --base REV --head REV
                            --scope TEXT [--since REV]
  review-report.sh lint [--strict] [--rigor light|full] REPORT
  review-report.sh normalize REPORT

scaffold writes a header and an empty Findings section to stdout, with no verdict.
Use the report's reviewed revisions; Since defaults to "initial". NAME must be in
the project's Review registry, and Model comes from its tier map for NAME and HARNESS.

lint takes an LF text file. Put other report context before the ## Findings section.
Leave that section empty for zero findings. Otherwise use one block per finding:

  - High: path/to/file:42
    Scenario: What happens and why it matters.
    Evidence: What demonstrates it (or where to find the evidence).

Use exactly Critical, High, Medium or Low and a positive line number. The last two
lines, with no text or blank lines after them, must be:

  Verdict: PASS
  Counts: 0 critical, 0 high, 0 medium, 0 low

Use PASS or FAIL and the actual counts. Critical and high block PASS; medium also
blocks under full rigor. Supply trusted policy's --rigor, or lint uses the installed
project's constitution. A PASS with medium findings needs known rigor.

normalize writes a copy to stdout, changing only the explicit Verdict: line
immediately before the final Counts: line. It does not infer a verdict from counts.
Values are matched case-insensitively, ignoring surrounding whitespace:

  PASS | PASSED | APPROVE | APPROVED | ACCEPT | ACCEPTED | LGTM -> PASS
  FAIL | FAILED | REJECT | REJECTED | REQUEST CHANGES
       | CHANGES REQUESTED | CHANGES_REQUESTED                  -> FAIL

Exit 0: ran (lint diagnostics on stdout); 1: lint diagnostics with --strict;
2: could not run, including normalize without a recognized explicit verdict.
EOF
}

die() { printf 'review-report.sh: %s\n' "$*" >&2; exit 2; }

mode="${1:-}"
case "$mode" in
    -h|--help) usage; exit ;;
    scaffold|lint|normalize) shift ;;
    *) die 'choose scaffold, lint or normalize; see --help' ;;
esac
case "${1:-}" in -h|--help) usage; exit ;; esac

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
source "$SCRIPT_DIR/common.sh" || die 'cannot load common.sh; reinstall the kit'
source "$SCRIPT_DIR/spec-lib.sh" || die 'cannot load spec-lib.sh; reinstall the kit'
source "$SCRIPT_DIR/review-policy-lib.sh" || die 'cannot load review-policy-lib.sh; reinstall the kit'
export LC_ALL=C

scaffold() {
    local reviewer='' harness='' base='' head='' since='' scope='' value seen=' ' key
    local root registry eligibility def tier problems
    while [ "$#" -gt 0 ]; do
        key="$1"; value="${2:-}"
        case "$key" in
            --reviewer|--harness|--base|--head|--since|--scope) ;;
            *) die "unknown scaffold option '$key'; see --help" ;;
        esac
        case "$seen" in *" $key "*) die "supply $key only once" ;; esac
        case "$value" in --*|*[[:cntrl:]]*) die "$key needs a single-line value" ;; esac
        [[ "$value" = *[![:space:]]* ]] || die "$key needs a nonblank value"
        seen="$seen$key "
        case "$key" in
            --reviewer) reviewer="$value" ;;
            --harness) harness="$value" ;;
            --base) base="$value" ;;
            --head) head="$value" ;;
            --since) since="$value" ;;
            --scope) scope="$value" ;;
        esac
        shift 2
    done
    [ -n "$reviewer" ] && [ -n "$harness" ] && [ -n "$base" ] && [ -n "$head" ] && [ -n "$scope" ] ||
        die 'scaffold requires --reviewer, --harness, --base, --head and --scope; see --help'
    [[ "$reviewer" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || die '--reviewer must be a lowercase registry identity'

    root="$(get_repo_root)" || die 'cannot locate the installed project'
    require_consumer_root "$root" review-report.sh
    source "$SCRIPT_DIR/install-lib.sh" || die 'cannot load install-lib.sh; reinstall the kit'
    source "$SCRIPT_DIR/agent-tiers-lib.sh" || die 'cannot load agent-tiers-lib.sh; reinstall the kit'
    case "$harness" in *[!a-z]*) die "--harness must be one of: $AT_HARNESSES" ;; esac
    case " $AT_HARNESSES " in *" $harness "*) ;; *) die "--harness must be one of: $AT_HARNESSES" ;; esac

    verify_lf_file "$root/.prdkit/memory/agents.md" ||
        die 'expected readable LF text in .prdkit/memory/agents.md; register the reviewer and configure the tier map there'
    registry="$(review_registry < "$root/.prdkit/memory/agents.md")" ||
        die 'cannot read the Review registry in .prdkit/memory/agents.md'
    eligibility="$(review_eligibility "$registry" "$reviewer")" || die 'cannot check reviewer eligibility'
    [ "$eligibility" = reviewer ] ||
        die "'$reviewer' is $eligibility; expected one reviewer entry in the Review registry in .prdkit/memory/agents.md"

    def="$root/.prdkit/agents/$reviewer.md"
    [ -f "$def" ] && verify_lf_file "$def" && tier="$(at_fm_value "$def" tier)" && [ -n "$tier" ] ||
        die "set tier: in the neutral definition .prdkit/agents/$reviewer.md"
    at_def_harnesses "$def"
    [ -z "$AT_DH_ERR" ] || die ".prdkit/agents/$reviewer.md: $AT_DH_ERR"
    if $AT_DH_SET; then
        case " $AT_DH_LIST " in *" $harness "*) ;; *) die "'$reviewer' does not target '$harness' in its neutral definition" ;; esac
    fi
    at_load "$root" || die 'cannot load the configured tier map'
    problems="$(at_lint_map)" || die 'cannot check the configured tier map'
    [ -z "$problems" ] || die "$problems"
    # shellcheck disable=SC2153 # Set by at_resolve in agent-tiers-lib.sh.
    at_resolve "$reviewer" "$tier" "$harness" || die "cannot resolve Model for '$reviewer': $AT_R_ERR"
    case "$AT_R_MODEL" in *[[:cntrl:]]*) die 'resolved Model must be one line of text; fix the tier map' ;; esac

    printf '# Review report\n\nReviewer: %s\nBase: %s\nHead: %s\nSince: %s\nScope: %s\nModel: %s\n\n## Findings\n' \
        "$reviewer" "$base" "$head" "${since:-initial}" "$scope" "$AT_R_MODEL" ||
        die 'cannot write report scaffold'
}

if [ "$mode" = scaffold ]; then scaffold "$@"; exit; fi

strict=false; rigor=''; report=''
while [ "$#" -gt 0 ]; do
    case "$mode:$1" in
        lint:--strict) strict=true ;;
        lint:--rigor)
            [ -z "$rigor" ] || die 'supply --rigor only once'
            rigor="${2:-}"
            case "$rigor" in light|full) ;; *) die '--rigor needs light or full' ;; esac
            shift ;;
        *:-*) die "unknown $mode option '$1'; see --help (prefix local paths starting with - with ./)" ;;
        *) [ -z "$report" ] || die "$mode takes one report file; see --help"
            report="$1" ;;
    esac
    shift
done
[ -n "$report" ] || die "$mode needs a report file; see --help"
if ! [ -f "$report" ] || ! verify_lf_file "$report" allow-empty; then
    die "cannot read '$report' as an LF-terminated text file"
fi

if [ "$mode" = lint ] && [ -z "$rigor" ]; then
    root="$(get_repo_root)" || die 'cannot locate project policy; supply --rigor'
    constitution="$root/.prdkit/memory/constitution.md"
    rigor=unknown
    if [ -f "$constitution" ] && verify_lf_file "$constitution"; then
        rigor="$(read_rigor_text < "$constitution")" || die 'cannot read Rigor; supply --rigor'
    fi
fi

status=0
# Keep two lines in reserve for the trailer. Use awk status 3 for a completed
# lint with findings (or a normalization refusal), not for execution failures.
awk -v mode="$mode" -v rigor="$rigor" "$SPEC_METADATA_SKIP_AWK"'
    function problem(n, text) { printf "line %d: %s\n", n, text; bad = 1 }
    function finish_finding() {
        if (!start) return
        if (!scenario) problem(start, "finding needs a nonblank Scenario: line")
        if (!evidence) problem(start, "finding needs a nonblank Evidence: line")
    }
    function body(line, n, skip,   sep, severity, location) {
        if (!skip && line == "## Findings") {
            if (findings) problem(n, "keep exactly one ## Findings section")
            findings = 1
            return
        }
        if (!skip && line ~ /^(Verdict|Counts):/) {
            problem(n, "keep Verdict: and Counts: only in the final two lines")
            return
        }
        if (!findings && !skip && line ~ /^- (Critical|High|Medium|Low):/)
            problem(n, "move the finding under ## Findings")
        if (!findings || line ~ /^[ \t]*$/) return
        if (line ~ /^- / && !skip) {
            finish_finding()
            start = n; scenario = evidence = 0
            line = substr(line, 3)
            sep = index(line, ": ")
            severity = (sep ? substr(line, 1, sep - 1) : "")
            if (severity !~ /^(Critical|High|Medium|Low)$/)
                problem(n, "start a finding with - Critical:, - High:, - Medium: or - Low:")
            else count[severity]++
            location = (sep ? substr(line, sep + 2) : "")
            if (location !~ /^[^[:space:]].*:[1-9][0-9]*$/)
                problem(n, "give the finding a file:line location with a positive line number")
        } else if (start && !skip && line ~ /^  Scenario: [[:space:]]*[^[:space:]]/) {
            if (scenario++) problem(n, "give the finding only one Scenario: line")
        } else if (start && !skip && line ~ /^  Evidence: [[:space:]]*[^[:space:]]/) {
            if (evidence++) problem(n, "give the finding only one Evidence: line")
        } else problem(n, "expected a finding or its indented Scenario: or Evidence:; see --help")
    }
    function normalized(verdict) {
        sub(/^Verdict:[ \t]*/, "", verdict); sub(/[ \t]+$/, "", verdict)
        verdict = tolower(verdict)
        if (verdict ~ /^(pass|passed|approve|approved|accept|accepted|lgtm)$/) return "PASS"
        if (verdict ~ /^(fail|failed|reject|rejected|request changes|changes requested|changes_requested)$/) return "FAIL"
        return ""
    }
    {
        if (mode == "normalize") lines[NR] = $0
        else if (NR > 2) body(before, NR - 2, before_hidden)
        before = last; before_hidden = last_hidden
        last = $0; last_hidden = metadata_skip($0)
    }
    END {
        verdict_line = NR >= 2 && !before_hidden && before ~ /^Verdict:/
        counts_line = NR >= 1 && !last_hidden && last ~ /^Counts:/
        if (mode == "normalize") {
            verdict = (verdict_line && counts_line ? normalized(before) : "")
            if (verdict == "") exit 3
            for (i = 1; i <= NR - 2; i++) print lines[i]
            print "Verdict: " verdict
            print last
            exit
        }
        if (NR >= 2 && !verdict_line) body(before, NR - 1, before_hidden)
        if (NR >= 1 && !counts_line) body(last, NR, last_hidden)
        finish_finding()
        if (!findings) problem(1, "add a ## Findings section (empty if there are no findings)")
        if (!verdict_line || before !~ /^Verdict: (PASS|FAIL)$/)
            problem(NR < 2 ? 1 : NR - 1, "penultimate line must be exactly Verdict: PASS or Verdict: FAIL")
        expected = sprintf("Counts: %d critical, %d high, %d medium, %d low",
                           count["Critical"], count["High"], count["Medium"], count["Low"])
        if (!counts_line || last != expected)
            problem(NR ? NR : 1, "last line must match the findings: " expected)
        if (verdict_line && before == "Verdict: PASS") {
            if (count["Critical"] || count["High"] || (rigor == "full" && count["Medium"]))
                problem(NR - 1, "PASS is inconsistent with blocking findings")
            else if (count["Medium"] && rigor != "light")
                problem(NR - 1, "cannot verify PASS with medium findings; supply --rigor from trusted policy")
        }
        if (bad) exit 3
    }
' < "$report" || status=$?

case "$status:$mode" in
    0:*) exit 0 ;;
    3:lint) if $strict; then exit 1; else exit 0; fi ;;
    3:normalize) die 'expected a recognized Verdict: value immediately before the final Counts: line; see --help' ;;
    *) die "cannot $mode '$report'; check the input and output" ;;
esac
