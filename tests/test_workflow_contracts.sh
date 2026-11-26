#!/usr/bin/env bash
# shellcheck disable=SC2016 # Literal markdown phrases: backticks are data, not command substitution.
# Contract guardrails complement real-agent evals; no fixed prose/line-count quotas. Each
# assertion pins a rule whose loss an earlier replay or incident showed to be expensive.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
W="$PK_ROOT/workflows"; T="$PK_ROOT/templates"
# Prose wraps freely, so match phrases against whitespace-normalized text.
flat() { cat "$@" | tr '\n' ' ' | tr -s ' '; }
protocol="$(flat "$W/protocol.md")"; spec="$(flat "$W/spec.md")"; change="$(flat "$W/change.md")"
review="$(flat "$W/review.md")"

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
assert_contains "$review" 'Never dispatch a round with no source change' "no empty re-review"
for suite in review_gate review_record_format review_lenses pr_review; do
    assert_eq 1 "$(grep -cxF "test_$suite.sh" "$TESTS_DIR/native-suites.txt" || true)" "$suite is in the native macOS allowlist"
done
assert_contains "$review" 'did not implement' "independent reviewer"
assert_contains "$review" 'untracked file contents' "uncommitted review includes new files"
assert_contains "$review" '.prdkit/scripts/bash/build-review-package.sh <change-id> <base>' "package helper"
assert_contains "$change" 'read [review.md](review.md)' "the always-read change playbook routes review, merge and closing"
assert_contains "$(flat "$T/review-prompt-template.md")" 'You did not implement this change' "reviewer contract"

it "review rounds attach only fresh, bound facts as evidence"
assert_contains "$review" 'Once per round at the exact head' "scope of collection"
assert_contains "$review" '.prdkit/scripts/bash/facts.sh <change-id>' "collect facts before packaging"
assert_contains "$review" 'Only after collection exits 0, verify the pair before attaching' "refusal cannot feed the attachment"
assert_contains "$review" '`index.json` fields `change_id`, `key.base` and `key.head` must match this round' "bind to exact change and range"
assert_contains "$review" 'SHA-256 of the raw index bytes' "reject a mixed pair"
assert_contains "$review" 'attach both files via `--facts`' "flat, paired attachment"
assert_contains "$review" 'repeat the change/range and SHA-256 checks on the copies at `evidence/facts/summary.md` and `evidence/facts/index.json`' "bind the attached bytes"
assert_contains "$review" 'omit the facts, never reuse the old cache' "fallback does not recycle an earlier pack"
assert_contains "$review" 'Facts are evidence, never a gate decision' "unchanged gate authority"
review_prompt="$(flat "$T/review-prompt-template.md")"
assert_contains "$review_prompt" '`evidence/facts/summary.md`, if supplied and only if the coordinator verified the copied pair' "reviewer does not trust a bare attachment"
assert_contains "$review_prompt" 'this change and the package range `{BASE_SHA}..{HEAD_SHA}`' "reviewer checks the package binding"
assert_contains "$review_prompt" 'authoritative for the facts it lists; do not re-derive those answers' "avoid duplicate work"
assert_contains "$review_prompt" 'for a small change, no other file is a default read' "defer supporting evidence"
assert_contains "$review_prompt" 'shell-less reviewers must not try to run them' "the captured commands are not instructions"
assert_contains "$review" 'the full `diff.patch` first and the verified `evidence/facts/summary.md` second' "dispatcher uses the lean read order"

it "bounds evidence prefers bound package inputs and never a mutable checkout"
assert_contains "$review_prompt" 'Check the full body of each applicable bound' "explicitly check bound bodies"
assert_contains "$review_prompt" 'A list of IDs and titles is not enough to judge compliance' "facts inventory does not replace bound bodies"
assert_contains "$review_prompt" 'use the verified, object-bound BASE bounds and inputs' "use binding BASE applicability"
assert_contains "$review_prompt" 'using only packaged historical scope for a closing head' "live fallback cannot reconstruct a deleted record"
assert_contains "$review_prompt" 'Candidate or historical evidence cannot override BASE' "candidate scope cannot replace BASE"
assert_contains "$review_prompt" 'If the scope or required bound text cannot be verified, mark the obligation unverified' "unknown remains unknown"

it "mandatory obligations cannot be hidden behind optional context"
assert_contains "$review_prompt" '`index.md` → **Review obligations** (second if no verified facts)' "obligations are a default read with or without facts"
assert_contains "$review_prompt" 'Check every listed obligation' "checking the obligations is mandatory"
assert_contains "$review_prompt" 'If the index says **Required full context**, read the indicated artifacts before giving a verdict' "overflow requires source reads"
assert_contains "$review" 'Put any missing mandatory obligation or unresolved question inline in the dispatch prompt with its source path' "dispatch closes the capture gap"
assert_contains "$review_prompt" "A proposed relaxation (including removal) is a finding unless the change record justifies it and the owner's approval is evidenced through the existing change process."
assert_contains "$review" 'unless the change record justifies it and the owner approved it through the existing process'

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

it "one home per fact: binding decisions leave the change; reviewers look for second homes"
assert_contains "$spec" '**One home per fact.**' "one home per fact"
assert_contains "$spec" 'binds later work in its L1/L2 home now' "binding decisions go to L1/L2"
assert_contains "$(flat "$T/review-prompt-template.md")" '**One home**' "reviewer checks one home"
assert_contains "$(flat "$T/review-prompt-template.md")" 'never a required input' "the spec search never stalls a review"

it "spec-only reviews defer proof mechanics, not current spec defects"
assert_contains "$review" '[Levels](spec.md#levels)' "review points to the canonical level rules"
assert_contains "$review" 'Send those rules with the prompt.' "dispatcher supplies the canonical rules"
assert_contains "$review" 'Snapshot the installed prompt and `.prdkit/workflows/spec.md` with `--context` if the trusted copies are tracked at the reviewed head; otherwise attach both at dispatch.' "dispatcher attaches the rules and prompt when not tracked at the reviewed head"
assert_contains "$review" 'Use the `level` category' "added excess detail is a level finding"
assert_contains "$review" 'are low (advisory); tag them `defer: implementing PR`' "deferral cannot block under full rigor"
assert_contains "$review" 'Critical and high findings block, medium blocks under `Rigor: full`, low is advisory.' "severity scale unchanged"
assert_contains "$change" 'state bounded PR obligations as observable outcomes' "acceptance states an observable outcome"
assert_contains "$change" 'proof design (oracles, fixtures, controls) belongs in the implementing PR' "implementation review checks proof design"

it "changes: planned direction can land separately, built behavior ships with code and tests"
assert_contains "$change" 'Spec edits that claim built behavior land in the PR whose code and tests realize them.' "built spec with code"
assert_contains "$change" 'Owner-approved, unbuilt intent may land in a spec-only PR under the [`planned:` rule](spec.md#elements).' "planned exception requires owner direction and links the rule"
assert_contains "$change" 'A spec-only PR proves its spec obligations, not the future runtime outcome.' "spec acceptance does not prove runtime behavior"

it "changes: test edits touch IDs, Spec impact lines, no no-op notes"
assert_contains "$change" 'also edits that ID' "tests and IDs move together"
assert_contains "$change" 'Spec impact: none — <reason>' "spec impact"
assert_contains "$change" 'Unaffected changes' "no no-op notes"
assert_contains "$change" 'one sentence of disposition' "parent dispositions stay one sentence"
assert_contains "$change" '.prdkit/scripts/bash/check-delivery.sh --json' "remote checkpoint verified"

it "change tasks are outcome-only and leave the record in their delivering PR"
implementation="$(flat "$W/implementation.md")"
change_template="$(flat "$T/change-template.md")"
pr_template="$(cat "$T/pr-summary-template.md")"
task_example='- [ ] (P2.1) T003 <outcome; dependency; check name>'
drops='Drops: <change-id> T004, T005'
assert_contains "$change_template" "$task_example" "template shows an outcome-level task"
assert_contains "$spec" "$task_example" "part assignment uses the same format"
assert_not_contains "$spec" '- [x] (P' "part metadata does not teach checked-off tasks"
assert_contains "$change" 'no paths, line ranges or commands' "execution details stay out of the record"
assert_contains "$implementation" 'in the cache or the PR, not the record' "planning keeps execution details elsewhere"
assert_contains "$implementation" '- [ ] T001 <outcome; dependency; check name>' "execution uses unchecked outcome lines"
for workflow in "$change" "$implementation"; do
    assert_contains "$workflow" 'unique within the change; never reuse or renumber them' "task keys are local and permanent"
done
assert_contains "$change" 'The PR that delivers a task deletes its line' "delivery deletes the line"
assert_contains "$change" 'No `[x]`, delivered note or history entry for the task' "no task archive"
assert_contains "$implementation" 'Local verification is not delivery' "verified work is not yet delivered"
assert_contains "$review" 'For a single-PR change, deleting the record delivers its tasks' "single-PR tasks are delivered at close"
assert_eq 1 "$(grep -cxF "$drops" "$T/pr-summary-template.md" || true)" "standalone Drops line in the PR template"
assert_contains "$pr_template" 'uncomment only for tasks dropped rather than delivered' "Drops is optional"
for workflow in "$change" "$implementation" "$review" "$pr_template"; do
    assert_contains "$workflow" "$drops" "one Drops syntax"
    assert_not_contains "$workflow" 'Delivers:' "delivery needs no annotation"
done

it "dropped v4 rules stay dropped"
all="$(flat "$W"/*.md "$T"/*.md "$PK_ROOT"/commands/*.md)"
assert_not_contains "$all" 'kit version while a change is open' "no kit-version freeze"
assert_not_contains "$all" 'Only the owner writes HOLD' "agents record owner-decided holds"
assert_contains "$(flat "$T/records-template.md")" 'never invent one' "agents never invent holds"
assert_not_contains "$all" '(proposed)' "no proposed constraints"

it "compaction preserves current canon and keeps history off the default load path"
compact="$(flat "$W/compact.md")"
assert_contains "$compact" 'never by dropping items' "preserve current canon"
assert_contains "$compact" 'Log condensed through' "preserve numbering after log compaction"
assert_contains "$protocol" '`.prdkit/history/archive.md` only on demand' "the archive is read on demand"
assert_not_contains "$protocol" '`specs/archive/`' "no archive folder on the load table"

finish
