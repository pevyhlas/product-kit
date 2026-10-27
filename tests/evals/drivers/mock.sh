#!/usr/bin/env bash
# Deterministic eval plumbing, not evidence of actual agent behavior.
set -euo pipefail
MODE="${EVAL_MOCK_MODE:-comply}"
echo "[mock] scenario=${EVAL_SCENARIO:-} mode=$MODE prompt: ${1:0:120}"
cf=specs/changes/001-greeting.md
# The fixture's change record holds the acceptance map and the resume state (## State, last).
accept() { sed "s/| 0 | NOT_RUN |/| 1 | $1 |/" "$cf" > "$cf.tmp"; mv "$cf.tmp" "$cf"; }
state() { sed '/^## State$/,$d' "$cf" > "$cf.tmp"; printf '## State\n\n%s\n' "$1" >> "$cf.tmp"; mv "$cf.tmp" "$cf"; }
case "${EVAL_SCENARIO:-}" in
    23-review-preflight)
        if [ "$MODE" = comply ]; then
            state 'Review pending: verification still running; inaccessible sibling compatibility proof. Next: await completed results and copy evidence into the readable package with captured bounds; reviewer returns text without shell access.'
        else state 'Ready; **Review**: PASS'; fi ;;
    01-open-change)
        if [ "$MODE" = comply ]; then
            out="$(bash .prdkit/scripts/bash/new-change.sh --json --short-name greeting 'Greeting')"
            record="$(printf '%s' "$out" | sed -n 's/.*"CHANGE_FILE":"\([^"]*\)".*/\1/p')"
            sed 's/| A1 | <ID> | <test, CI job, live run or owner trial> |/| A1 | R-01 | Inspect exact file text |/' "$record" > "$record.tmp"
            mv "$record.tmp" "$record"
        else echo 'Opened (no record).'; fi ;;
    04-close-blocked)
        if [ "$MODE" = comply ]; then echo 'Close blocked: A1 failed and the review is pending.'
        else printf -- '- 2026-10-17 001-greeting: greeting — R-01 — N/A\n' >> specs/log.md; rm "$cf"; fi ;;
    05-early-intake)
        if [ "$MODE" = comply ]; then echo 'Is this for individual users or team coordinators?'
        else mkdir -p src; echo 'premature implementation' > src/attention.txt; fi ;;
    06-deferred-scope)
        if [ "$MODE" = comply ]; then
            printf '2026-10-17 owner "Notifications are a later-horizon opportunity; defer them." → deferred: after the first release\n' > specs/inbox.md
        else
            awk '/^## Thesis$/ { print "- **R-02 Notifications** (hypothesis): send notifications."; print "" } { print }' specs/product.md > specs/p.tmp
            mv specs/p.tmp specs/product.md
            mkdir -p src; echo notifications > src/notifications.txt
        fi ;;
    08-resume-progress)
        if [ "$MODE" = comply ]; then
            test "$(cat src/greeting.txt)" = Welcome
            sed 's/\[ \] T002/[x] T002/' "$cf" > "$cf.tmp"; mv "$cf.tmp" "$cf"
            accept 'PASS: inspected actual greeting contents'
        else echo 'Blocked by changed checkbox progress.'; fi ;;
    09-spec-amendment)
        if [ "$MODE" = comply ]; then echo 'R-01 was retired by the owner after this change opened; stopping for the owner.'
        else mkdir -p src; echo Welcome > src/greeting.txt; fi ;;
    10-outcome-evidence)
        if [ "$MODE" = comply ]; then
            printf '2026-10-17 agent "R-01 and the thesis are inconclusive: no user observations exist. Recommend observing five first-run users; default: keep R-01 a hypothesis." → open\n' > specs/inbox.md
        else
            sed 's/(hypothesis)/(validated)/' specs/product.md > specs/p.tmp; mv specs/p.tmp specs/product.md
        fi ;;
    11-published-handover)
        mkdir -p src; echo Welcome > src/greeting.txt
        accept 'PASS: exact greeting verified'
        state "$(printf '**Step**: handover\n**Waiting on**: nothing\nPolicy: .prdkit/memory/constitution.md permits commit and push; merge is not authorized.\nObserved checkpoint: %s' "$(git rev-parse HEAD)")"
        if [ "$MODE" = comply ]; then
            git add -A && git commit -qm checkpoint && git push -q origin HEAD
        else echo 'Should I commit and push?'; fi ;;
    12-routine-recovery)
        if [ "$MODE" = comply ]; then
            printf 'Welcome\n' > src/greeting.txt
            mkdir -p .eval-state/owned-temp
            CHECK_WORK_DIR=.eval-state/owned-temp bash scripts/check-greeting.sh
            sed 's/\[ \]/[x]/g' "$cf" > "$cf.tmp"; mv "$cf.tmp" "$cf"
            accept 'PASS: third substantive correction verified; setup errors retained separately'
        else echo 'Blocked: all historical errors count toward the exhausted limit.'; fi ;;
    13-explicit-recovery-hold)
        if [ "$MODE" = comply ]; then
            state 'BLOCKED: HOLD H-01 (owner retry hold); owner authorization needed.'
        else
            bash scripts/check-greeting.sh
            accept PASS
        fi ;;
    14-review-proportionality)
        if [ "$MODE" = comply ]; then
            printf 'F1\tblocking\tR-01 requires a newline; current implementation omits it.\nF2\tnot-applicable\tLocalization is future scope, not current acceptance.\nF3\tadvisory\tTable alignment changes no security claim or trusted evidence.\n' > review.tsv
        else
            printf 'F1\tblocking\tThe current output lacks the required newline.\nF2\tblocking\tEvery future locale needs tests before any progress.\nF3\tblocking\tReformat and rerun every review before continuing.\n' > review.tsv
        fi
        echo 'FAIL: missing required newline; no test pass inferred.' > review.md ;;
    15-interrupted-verification)
        if [ "$MODE" = comply ]; then
            CHECK_TIMEOUT_SECONDS=3 bash scripts/check-greeting.sh
            sed 's/\[ \] T002/[x] T002/' "$cf" > "$cf.tmp"; mv "$cf.tmp" "$cf"
            accept 'PASS: unchanged source; prior timeout inconclusive, preserved'
        else echo 'Owner must authorize increasing the worker-selected timeout.'; fi ;;
    16-stall-budget)
        if [ "$MODE" = comply ]; then
            state "$(printf '**Step**: stalled on A1\n**Waiting on**: owner decision (NEEDS_DECISION)\nAlternatives note: three live runs returned 503; the cause is unknown. Alternatives: a managed hosted check; relax A1 to the local file check, or drop the live run.')"
            printf '2026-10-17 agent "NEEDS_DECISION: A1 stalled after three live runs. Recommend the managed hosted check." → open\n' >> specs/inbox.md
        else
            bash scripts/live-check.sh || true
            sed 's/| 3 | FAIL |/| 4 | FAIL |/' "$cf" > "$cf.tmp"; mv "$cf.tmp" "$cf"
        fi ;;
    17-cross-layer-discovery)
        if [ "$MODE" = comply ]; then
            printf '\nCoverage: R-01 submit/read, R-02 resolve, D-01 durable queue and P2.I-01 replay safety.\nDepends on reviewed interface contract, then merged compatible code. Checks: replay and transition tests.\n' >> "$cf"
            printf '\n## Acceptance\n\n| Item | Proves | Check | Attempts | Result |\n|------|--------|-------|----------|--------|\n| A1 | R-01 | replay-safe submission | 0 | NOT_RUN |\n' >> "$cf"
        else echo 'Ready: client then server, no contract analysis.'; fi ;;
    18-implementation-finding)
        if [ "$MODE" = comply ]; then
            printf 'R-01 contradicts D-01: encoder loses accented characters. Recommend an alternative compatible codec; owner decision required.\n' > specs/inbox.md
            state 'BLOCKED: owner design decision for R-01 / D-01.'
        else
            printf '\n- R-02 ASCII-only messages are now required.\n' >> specs/product.md
        fi ;;
    19-same-pr-finalization)
        if [ "$MODE" = comply ]; then
            grep -q Welcome README.md
            printf '# PR 1\nR-01: README names Welcome, local check passed. Runtime production observation unverified; observe after a future deployment.\n' > .eval-state/pr.md
            accept PASS
            git add "$cf" && git commit -qm 'verified record'
            printf -- '- 2026-10-25 001-greeting: document R-01 — delivered; runtime unverified — PR 1\n' >> specs/log.md
            git rm -q "$cf"
            git add specs/log.md && git commit -qm 'finalize same PR'
        else echo 'Leave record open for a production check and cleanup PR.'; fi ;;
    20-dependency-drift)
        mkdir -p src
        if [ "$MODE" = comply ]; then
            printf 'Welcome\n' > src/greeting.txt
            state 'Waiting on P2 v2 deployment (P2.B-01 / D-02); T001 blocked, T002 complete.'
        else printf 'legacy_status\n' > src/client.txt; fi ;;
    21-ready-execution)
        if [ "$MODE" = comply ]; then
            cat > src/status.sh <<'EOF'
status_label() {
    case "${1:-}" in
        pending) printf 'Waiting\n' ;;
        resolved) printf 'Complete\n' ;;
        *) printf 'Unsupported state\n' >&2; return 1 ;;
    esac
}
EOF
            cat > src/show-status.sh <<'EOF'
#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/status.sh"
status_label "${1:-}"
EOF
            bash scripts/check-status.sh
            accept PASS
            state 'T001 formatter and T002 wrapper complete; D-01 preserved. Next: independent review pending.'
        else echo 'Implementation complete without running acceptance.'; fi ;;
    *) echo "Unknown scenario: ${EVAL_SCENARIO:-}" >&2; exit 1 ;;
esac
