#!/usr/bin/env bash
# shellcheck disable=SC2016 # Literal markdown phrases: backticks are data, not command substitution.
# Contract guardrails complement real-agent evals; no fixed prose/line-count quotas. Each
# assertion pins a rule whose loss an earlier replay or incident showed to be expensive.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
W="$PK_ROOT/workflows"; T="$PK_ROOT/templates"
# Prose wraps freely, so match phrases against whitespace-normalized text.
flat() { cat "$@" | tr '\n' ' ' | tr -s ' '; }
protocol="$(flat "$W/protocol.md")"; spec="$(flat "$W/spec.md")"; change="$(flat "$W/change.md")"

it "operational playbooks identify inputs, writes, and results"
for file in "$W"/*.md; do
    case "$(basename "$file")" in README.md|protocol.md) continue ;; esac
    content="$(cat "$file")"
    for field in Inputs Writes Result; do assert_contains "$content" "**$field**:" "$(basename "$file") $field contract"; done
done

it "work cannot silently grant itself authority"
assert_contains "$protocol" 'A generated plan never grants permission to commit, push, merge, publish, spend or deploy' "explicit authority boundary"
assert_contains "$protocol" 'Only a human extends or grants: the intent owner, or a human the owner names.' "agents cannot grant themselves more"
assert_contains "$protocol" 'Owner words relayed verbatim through another session or tool, with date and source, are owner direction' "relayed owner words stay owner words"
assert_contains "$protocol" "An agent's paraphrase, summary or allocation is information." "agent summaries are not direction"
assert_not_contains "$protocol" 'even when it is delivered in a user turn' "dropped v4 wording stays dropped"

it "asking carries a recommendation and a default; one-way doors wait"
assert_contains "$protocol" 'Every question to the owner carries a recommendation' "recommendation"
assert_contains "$protocol" 'state the default you will apply if no answer arrives' "default"
assert_contains "$protocol" 'A one-way door' "one-way doors wait"
assert_contains "$protocol" 'never only in harness memory or a session log' "owner direction is durable"

it "stalls go to the owner with alternatives; fix rounds are bounded"
assert_contains "$protocol" 'Count attempts per acceptance item and per blocker' "attempts counted across tasks and PRs"
assert_contains "$protocol" 'a merged PR whose own checks pass while' "a green PR is not progress"
assert_contains "$protocol" 'Review allows at most three fix rounds after' "bounded review fixes"
assert_contains "$protocol" 'managed or off-the-shelf' "alternatives include a managed option"
assert_contains "$protocol" 'Only the owner grants further attempts, with a stated limit' "stall routes to the owner"

it "external systems are sampled first and stay diagnosable"
assert_contains "$protocol" 'capture a secret-safe sample or cite the upstream contract' "sample first"
assert_contains "$protocol" 'Readers accept unknown fields' "tolerant readers"
assert_contains "$protocol" "Never discard an external tool's stderr" "stderr kept"

it "review is independent, tiered and never empty"
assert_contains "$protocol" '| T0 | docs only, no behavior change | none |' "T0"
assert_contains "$protocol" '| T3 | L0 edit or L1 one-way door | design review plus the owner |' "T3"
assert_contains "$protocol" 'never dispatch a round when no source changed' "no empty re-review"
assert_contains "$change" 'did not implement' "independent reviewer"
assert_contains "$change" 'untracked file contents' "uncommitted review includes new files"
assert_contains "$change" '.prdkit/scripts/bash/build-review-package.sh <change-id> <base>' "package helper"
assert_contains "$(flat "$T/review-prompt-template.md")" 'You did not implement this change' "reviewer contract"

it "merged, live and validated stay distinct; status answers first and names the longest pole"
assert_contains "$protocol" 'Merged, live (deployed) and validated (owner or user outcome) are distinct claims' "distinct claims"
assert_contains "$(flat "$W/status.md")" 'Answer the owner' "answer first"
assert_contains "$(flat "$W/status.md")" 'Longest pole' "longest pole"

it "evidence stays out of specs/"
assert_contains "$protocol" 'Raw evidence never lives in `specs/`' "evidence rule"
assert_contains "$change" 'A green PR does' "green PR is not acceptance"

it "spec rules: line test, planned only for decided intent, budgets never targets"
assert_contains "$spec" 'It rejects no valid real input, environment or use.' "two-sided line test"
assert_contains "$spec" '`planned: <change>` marks owner-decided intent not built yet' "planned is decided intent"
assert_contains "$spec" 'Undecided intent stays in the change record' "undecided intent is not planned"
assert_contains "$spec" 'stays in the change record' "undecided intent stays in the change"
assert_contains "$spec" 'Budgets are reading budgets, never targets' "budgets"
assert_contains "$spec" 'never drop an item that' "budgets never drop items"
assert_contains "$spec" 'no amendment journals' "no journals"
assert_not_contains "$spec" 'proposed' "no constraint proposed mechanics"

it "changes: spec edits with code, test edits touch IDs, Spec impact lines, no no-op notes"
assert_contains "$change" 'Spec edits land in the PR whose code and tests realize them' "spec with code"
assert_contains "$change" 'also edits that ID' "tests and IDs move together"
assert_contains "$change" 'Spec impact: none — <reason>' "spec impact"
assert_contains "$change" 'Unaffected changes' "no no-op notes"
assert_contains "$change" 'one sentence of disposition' "parent dispositions stay one sentence"
assert_contains "$change" '.prdkit/scripts/bash/check-delivery.sh --json' "remote checkpoint verified"

it "dropped v4 rules stay dropped"
all="$(flat "$W"/*.md "$T"/*.md "$PK_ROOT"/commands/*.md)"
assert_not_contains "$all" 'kit version while a change is open' "no kit-version freeze"
assert_not_contains "$all" 'Only the owner writes HOLD' "agents record owner-decided holds"
assert_contains "$(flat "$T/records-template.md")" 'never invent one' "agents never invent holds"
assert_not_contains "$all" '(proposed)' "no proposed constraints"

it "cutover condenses old canon, removes it from main, and never picks between contradictions"
compact="$(flat "$W/compact.md")"
assert_contains "$compact" 'do not' "contradictions are not resolved by the agent"
assert_contains "$compact" '**Still binds**' "binding rules, decisions and facts go into the spec"
assert_contains "$compact" '**Worth remembering**' "directions tried go into the archive digest"
assert_contains "$compact" 'Then `git rm` them all; git keeps them.' "no raw archive on main"
assert_not_contains "$compact" '`git mv`' "nothing is moved under an archive folder"
assert_contains "$compact" 'becomes a change record' "no leftover 0.x feature"
assert_contains "$protocol" '`specs/archive.md` only on demand' "the archive is read on demand"
assert_not_contains "$protocol" '`specs/archive/`' "no archive folder on the load table"
assert_contains "$(flat "$T/archive-template.md")" 'never by default' "the template says agents do not load it"

finish
