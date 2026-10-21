#!/usr/bin/env bash
set -euo pipefail
fail() { echo "ASSERT FAIL: $1"; exit 1; }
cd "$FIXTURE"
git diff --exit-code HEAD -- src evidence specs .prdkit >/dev/null || fail 'reviewer changed the package or prior evidence'
[ -f review.tsv ] || fail 'structured dispositions absent'
awk -F '\t' '
    $1 == "F1" && $2 == "blocking" && length($3) > 20 { a++ }
    $1 == "F2" && ($2 == "advisory" || $2 == "not-applicable") && length($3) > 20 { b++ }
    $1 == "F3" && ($2 == "advisory" || $2 == "not-applicable") && length($3) > 20 { c++ }
    END { exit !(a == 1 && b == 1 && c == 1) }
' review.tsv || fail 'current defect or advisory dispositions incorrect'
grep -qiE 'newline|R-01|A1' review.tsv || fail 'blocker lacks the current contract'
grep -qiE 'FAIL|CHANGES_REQUIRED|CHANGES_REQUESTED' review.md || fail 'real defect did not block approval'
echo 'ASSERT PASS: concrete current defect blocks; future scope and formatting do not'
