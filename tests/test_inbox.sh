#!/usr/bin/env bash
# Inbox identity, pending-answer projection and reconciliation diagnostics, through installed helpers.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PROJ="$(make_inited_project)"; track_tmp "$PROJ"
cd "$PROJ" || exit 1
mkdir -p specs
STATUS_SH="$PROJ/.prdkit/scripts/bash/status.sh"
DOCTOR="$PROJ/.prdkit/scripts/bash/doctor.sh"
export PRDKIT_TODAY=2026-10-31

it "format examples never become pending questions or answers"
cp .prdkit/templates/inbox-template.md specs/inbox.md
run bash "$STATUS_SH" --json
run jq -e '.inbox == []' <<< "$OUTPUT"
assert_eq 0 "$STATUS" "commented template is empty"

cat > specs/inbox.md <<'MD'
# Owner inbox

## Waiting for you

### Which punctuation?
*2026-10-29 · agent · open*

**ID**: IN-111111111111
**Revision**: 2
**Kind**: decision
**Tags**: copy,ux

1. **none — No punctuation (Recommended)**: keep the greeting short.
2. **period — Add a period**: use a complete sentence.

**Answer**:
**Answer date**:
**Answer source**:
**Answer revision**:

<!-- **Answer**: a sample, not an answer -->
```markdown
**Answer**: period
```

### Greeting wording
*2026-10-28 · agent · open*

**ID**: IN-222222222222
**Revision**: 3
**Kind**: decision
**Tags**: copy, ux

1. **keep — Keep Welcome**: leave the greeting alone.
2. **hello — Use Hello (Recommended)**: replace Welcome.

**Answer**:
> hello — "Hello", in English.
> Record it now, implement later.
**Answer date**: 2026-10-30
**Answer source**: owner-message-1
**Answer revision**: 3

### Legacy answer
*2026-10-27 · agent · open*

Owner answer, 2026-10-30, source: owner-message-2: "Keep the header."

## To incorporate

### Release hold
*2026-10-30 · owner · processing*

**ID**: IN-333333333333
**Revision**: 1
**Kind**: direction
**Tags**: release
**Answer**: Do not release until I lift this hold.
**Answer date**: 2026-10-30
**Answer source**: owner-message-3
**Answer revision**: 1

2026-10-30 owner "One more direction → still pending" → open
MD
before="$(git status --porcelain; cat specs/inbox.md)"

it "status separates recorded answers and direction from questions, with identity and tags"
run bash "$STATUS_SH" --json
json="$OUTPUT"
assert_eq 0 "$STATUS" "status succeeds"
run jq -e '.inbox | length == 5' <<< "$json"
assert_eq 0 "$STATUS" "all headed and appended legacy items survive"
run jq -e '[.inbox[] | select(.state == "open") | .id] == ["IN-111111111111"]' <<< "$json"
assert_eq 0 "$STATUS" "empty answer and sample fields stay unanswered"
run jq -e '[.inbox[] | select(.state == "processing")] | length == 4' <<< "$json"
assert_eq 0 "$STATUS" "answered-in-body, legacy and owner direction await processing"
run jq -e '.inbox[0] | .revision == "2" and .tags == "copy, ux" and .kind == "decision"' <<< "$json"
assert_eq 0 "$STATUS" "metadata is projected without deriving identity from title"
run jq -e '.inbox[1].answer == "hello — \"Hello\", in English. Record it now, implement later."' <<< "$json"
assert_eq 0 "$STATUS" "multiline quoted answer preserves qualifications and JSON escaping"
run jq -e '.longest_pole.item | contains("Which punctuation?")' <<< "$json"
assert_eq 0 "$STATUS" "the actual unanswered question is the owner blocker"
run bash "$STATUS_SH"
owner_queue="$(printf '%s\n' "$OUTPUT" | sed -n '/^Owner queue$/,/^Inbox awaiting agent processing$/p')"
assert_contains "$owner_queue" "Which punctuation?" "question is in owner queue"
assert_not_contains "$owner_queue" "Greeting wording" "answered question is not re-presented as owner work"
assert_contains "$OUTPUT" "Inbox awaiting agent processing" "processing is visible, not silently hidden"

it "doctor warns on processing and legacy metadata without claiming semantic incorporation"
run bash "$DOCTOR"
assert_contains "$OUTPUT" "Owner inbox: 4 item(s) awaiting agent processing" "processing backlog named"
assert_contains "$OUTPUT" "Owner inbox: 1 open item(s)" "only true unanswered metadata counted"
assert_contains "$OUTPUT" "missing ID" "legacy item receives migration guidance"
assert_not_contains "$OUTPUT" "duplicate" "distinct IDs and keys accepted"
assert_not_contains "$OUTPUT" "answer revision mismatch" "matching answer revisions accepted"
assert_eq 1 "$(printf '%s\n' "$OUTPUT" | grep -c 'missing or invalid Answer date')" "only the legacy answer lacks structured provenance"
assert_eq "$before" "$(git status --porcelain; cat specs/inbox.md)" "status and doctor never write"

it "pending incorporation alone is never reported as waiting on the owner"
sed '/^### Which punctuation?$/,/^### Greeting wording$/ { /^### Greeting wording$/!d; }' specs/inbox.md > specs/next.md
mv specs/next.md specs/inbox.md
run bash "$STATUS_SH" --json
run jq -e '.longest_pole.waits_on == "the agent processing recorded direction"' <<< "$OUTPUT"
assert_eq 0 "$STATUS" "agent owns the pending answer"

it "stale answers, duplicate identities and reused option keys are actionable findings"
cat >> specs/inbox.md <<'MD'

### Conflicting identity
*2026-10-31 · agent · open*

**ID**: IN-222222222222
**Revision**: 4
**Kind**: decision
**Tags**: copy

1. **same — First**: one meaning.
2. **same — Second**: a different meaning.

**Answer**: 1
**Answer date**: 2026-10-30
**Answer source**: owner-message-4
**Answer revision**: 3
MD
run bash "$DOCTOR"
assert_eq 1 "$STATUS" "unsafe identity/selection fails diagnostics"
assert_contains "$OUTPUT" "duplicate ID IN-222222222222" "identity collision found"
assert_contains "$OUTPUT" "duplicate option key same" "option collision found"
assert_contains "$OUTPUT" "answer revision mismatch; clarify before incorporation" "stale positional answer is not silently accepted"

it "a known stale selection remains an owner clarification, not an incorporation task"
cat > specs/inbox.md <<'MD'
# Owner inbox

### Clarify the changed choice
*2026-10-31 · agent · processing*

**ID**: IN-555555555555
**Revision**: 2
**Kind**: decision
**Tags**: copy
1. **keep — Keep it (Recommended)**: retain the revised behavior.
2. **omit — Omit it**: remove it.
**Answer**: 1
**Answer date**: 2026-10-30
**Answer source**: original-selection
**Answer revision**: 1
MD
run bash "$STATUS_SH" --json
json="$OUTPUT"
run jq -e '.inbox[0] | .state == "open" and .answer == "1"' <<< "$json"
assert_eq 0 "$STATUS" "stale answer preserved while owner clarification stays visible"
run jq -e '.longest_pole.waits_on == "the owner"' <<< "$json"
assert_eq 0 "$STATUS" "stale choice waits on the owner even with old processing metadata"
run bash "$STATUS_SH"
owner_queue="$(printf '%s\n' "$OUTPUT" | sed -n '/^Owner queue$/,/^Inbox awaiting agent processing$/p')"
assert_contains "$owner_queue" "Clarify the changed choice" "owner view names the unresolved clarification"

it "an answer without a source stays processing and does not acquire invented provenance"
cat > specs/inbox.md <<'MD'
# Owner inbox

### Imported answer
*2026-10-31 · agent · open*

**ID**: IN-444444444444
**Revision**: 1
**Kind**: feedback
**Tags**: ux
**Answer**: It worked with enlarged text.
MD
run bash "$DOCTOR"
assert_contains "$OUTPUT" "missing Answer source" "source gap named"
assert_contains "$OUTPUT" "missing or invalid Answer date" "date gap named"
assert_contains "$OUTPUT" "missing or invalid Answer revision" "revision gap named"
assert_contains "$OUTPUT" "awaiting agent processing" "missing provenance does not become a fresh owner question"

it "legacy stable IDs survive migration and answer aliases cannot hide duplicate fields"
cat > specs/inbox.md <<'MD'
# Owner inbox

### Existing question identity
*2026-10-31 · agent · open*

**ID**: inbox-021
**Revision**: 1
**Kind**: feedback
**Tags**: ux
**Answer**: Readable.
**Owner answer**: Not readable.
**Answer date**: 2026-10-31
**Answer source**: imported-thread
**Answer revision**: 1
MD
run bash "$DOCTOR"
assert_contains "$OUTPUT" "duplicate field Answer" "alias conflict requires reconciliation"
assert_not_contains "$OUTPUT" "invalid ID" "legacy single-token identity is retained"
run bash "$STATUS_SH" --json
run jq -e '.inbox[0].id == "inbox-021"' <<< "$OUTPUT"
assert_eq 0 "$STATUS" "identity is not rewritten"

finish
