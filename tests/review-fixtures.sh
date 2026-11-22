#!/usr/bin/env bash
# Native reviews are independent host fixtures; record text is never replayed as review data.
review_policy() {
    cat >> "$1/.prdkit/memory/config.md" <<'EOF'

## Configuration
- review-host: github
- review-publishers: bot:1001
- review-owner: user:1003
EOF
}
review_head() {
    fx_pr 7 "$(git rev-parse HEAD)" "$(jq -cn --arg base "$(git symbolic-ref --short refs/remotes/origin/HEAD | sed 's|^origin/||')" '{base:{ref:$base}}')"
}
approve_head() { review_head && fx_review 7 'Reviewed.' '{"state":"APPROVED"}'; }
