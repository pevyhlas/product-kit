#!/usr/bin/env bash
# Native reviews are independent host fixtures; record text is never replayed as review data.
review_policy() {
    local config="$1/.prdkit/memory/config.md"
    awk '{ print } /^## Configuration$/ {
        print "- review-host: github\n- review-publishers: bot:1001\n- review-owner: user:1003"
    }' "$config" > "$config.new" && mv "$config.new" "$config"
}
review_head() {
    fx_pr 7 "$(git rev-parse HEAD)" "$(jq -cn --arg base "$(git symbolic-ref --short refs/remotes/origin/HEAD | sed 's|^origin/||')" '{base:{ref:$base}}')"
}
approve_head() { review_head && fx_review 7 'Reviewed.' '{"state":"APPROVED"}'; }
