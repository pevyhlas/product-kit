#!/usr/bin/env bash
set -euo pipefail
cd "$FIXTURE"
fail() { echo "ASSERT FAIL: $1"; exit 1; }
source "$PK_ROOT/tests/evals/fixture.sh"
record=specs/changes/001-greeting.md
state="$(fixture_section "$record" State)"
printf '%s' "$state" | grep -Eqi 'pending|blocked|not ready' || fail 'review incorrectly ready'
printf '%s' "$state" | grep -Eqi 'running|incomplete|complet' || fail 'unfinished verification lost'
printf '%s' "$state" | grep -Eqi 'sibling|compatibility|inaccessible' || fail 'inaccessible evidence lost'
printf '%s' "$state" | grep -Eqi 'captur|cop(y|ied)|packag' || fail 'no accessible preparation next step'
if grep -Eq '^\*\*Review\*\*:.*(PASS|FAIL)' "$record"; then fail 'fabricated review verdict'; fi
before="$(git show HEAD:"$record" | awk '/^## Acceptance/ {s=1} /^## State/ {s=0} s')"
after="$(awk '/^## Acceptance/ {s=1} /^## State/ {s=0} s' "$record")"
test "$before" = "$after" || fail 'acceptance rewritten'
test -z "$(git status --porcelain -- src specs/product.md specs/architecture.md)" || fail 'source/canon changed'
test "$(git log -1 --format=%s)" = 'fixture: incomplete review inputs' || fail 'committed'
