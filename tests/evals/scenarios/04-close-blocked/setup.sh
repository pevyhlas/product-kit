#!/usr/bin/env bash
set -euo pipefail
source "$PK_ROOT/tests/evals/fixture.sh"
fixture_project
fixture_change
printf '# Log\n' > specs/log.md
sed -e 's/| 0 | NOT_RUN |/| 1 | FAIL (greeting missing) |/' -e '/^## State$/,$d' "$CHANGE_FILE" > "$CHANGE_FILE.tmp"
mv "$CHANGE_FILE.tmp" "$CHANGE_FILE"
cat >> "$CHANGE_FILE" <<'EOF'
## State

**Step**: review
**Waiting on**: independent review (PENDING, no reviewer); A1 FAIL
**Next**: fix the greeting, then rerun A1 and request review.
EOF
git add -A && git commit -qm 'fixture: failed closing prerequisites'
