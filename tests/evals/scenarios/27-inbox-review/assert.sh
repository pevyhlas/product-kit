#!/usr/bin/env bash
set -euo pipefail
cd "$FIXTURE"
fail() { echo "ASSERT FAIL: $1"; exit 1; }
test "$(cat src/greeting.txt)" = Welcome || fail 'implementation changed'
test "$(git log -1 --format=%s)" = 'fixture: filtered inbox with stale selection' || fail 'committed'
source "$PK_ROOT/tests/evals/fixture.sh"
req=specs/product/requirements.md
if grep -rq 'greeting Welcome on its own line' "${FIXTURE_CANON[@]}"; then fail 'governing requirement left contradictory'; fi
grep -q Hello "$req" || fail 'answer not incorporated into product intent'
grep -q 'planned: 001-greeting' "$req" || fail 'unbuilt intent appears built'
grep -q 'IN-aaaaaaaaaaaa' "$req" || fail 'question identity lost from canonical decision'
if grep -rEq '\[IN-aaaaaaaaaaaa\]\((\.\./)*inbox\.md([#][^)]*)?\)' "${FIXTURE_CANON[@]}"; then fail 'canonical provenance links back to the removed inbox item'; fi
grep -q 'owner-message-27' "$req" || fail 'answer source lost'
grep -q '2026-10-30' "$req" || fail 'answer date lost'
grep -q 'Record it now, implement later' "$req" || fail 'owner qualification lost'
if grep -q 'IN-aaaaaaaaaaaa' specs/inbox.md; then fail 'incorporated answer retained'; fi
if grep -q 'IN-cccccccccccc' specs/inbox.md; then fail 'agent-only work remains an owner question'; fi
grep -q 'IN-bbbbbbbbbbbb' specs/inbox.md || fail 'stale selection discarded'
grep -q 'owner-message-older' specs/inbox.md || fail 'stale answer provenance lost'
status_json="$(bash .prdkit/scripts/bash/status.sh --json)"
printf '%s' "$status_json" | jq -e '.inbox[] | select(.id == "IN-bbbbbbbbbbbb") | .state == "open"' >/dev/null || fail 'stale clarification is misreported as agent-only processing'
grep -q 'IN-bbbbbbbbbbbb' "$TRANSCRIPT" || fail 'next question does not identify the stale item'
grep -Eiq 'clarif|revision|changed|which' "$TRANSCRIPT" || fail 'stale choice not clarified'
original="$(git show HEAD:specs/inbox.md | sed -n '/^### Notification preference$/,$p')"
test "$original" = "$(sed -n '/^### Notification preference$/,$p' specs/inbox.md)" || fail 'out-of-scope topic changed'
test -z "$(git diff -- specs/records.md)" || fail 'execution hold changed'
grep -q '2/3' specs/changes/001-greeting.md || fail 'attempt history lost'
grep -q 'Hello' specs/changes/001-greeting.md || fail 'pending implementation not reconciled'
grep -q 'T002' specs/changes/001-greeting.md || fail 'verification obligation lost'
grep -q 'NOT_RUN' specs/changes/001-greeting.md || fail 'acceptance promoted'
test ! -e specs/inbox-archive.md || fail 'duplicate answer archive created'
