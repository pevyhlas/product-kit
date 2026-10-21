#!/usr/bin/env bash
set -euo pipefail
source "$PK_ROOT/tests/evals/fixture.sh"
fixture_project
fixture_change
git add -A && git commit -qm 'fixture: change opened for R-01'
# The owner then edits L0 in place: R-01 is withdrawn pending a wording review.
sed 's/^- \*\*R-01 Greeting\*\* (hypothesis):.*/- **R-01 Greeting** (hypothesis) retired: owner withdrew it on 2026-10-10 pending a wording review (D-01)./' \
    specs/product.md > specs/product.md.tmp
mv specs/product.md.tmp specs/product.md
git add -A && git commit -qm 'fixture: owner retired R-01 after the change opened'
