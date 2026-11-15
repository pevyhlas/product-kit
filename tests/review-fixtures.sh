#!/usr/bin/env bash
# Coverage scenario recipes are test data, never gate evidence. Valid new recipes call the real
# publisher against the stub, then cache its immutable body for host-fixture replay across base
# updates. Deliberately malformed/ineligible recipes use fx_review to test gate-side rejection.
# shellcheck disable=SC2016,SC2034 # Literal jq variables; run outputs consumed by suites.
source "$PK_ROOT/scripts/common.sh"
source "$PK_ROOT/scripts/spec-lib.sh"
source "$PK_ROOT/scripts/review-policy-lib.sh"
source "$PK_ROOT/scripts/review-fingerprint-lib.sh"

receipt_policy() { # project; call before the fixture's baseline commit
    cat >> "$1/.prdkit/memory/config.md" <<'EOF'

## Configuration
- review-host: github
- review-publishers: bot:1001
- review-owner: user:1003
- review-publisher-isolation: required
EOF
}

receipt_host() { # root change head [base]; intentionally test-only legacy recipe decoding
    local project="$1" change="$2" head="$3" base="${4:-origin/HEAD}" at record text cache key body
    local line reviewer round from to verdict c h m l link from_token to_token since rhead base_at canonical serial=0
    local owner_commit="" candidate owner_key slice publisher_output publish_args policy_ref fixture_registry from_fp published publisher
    [ -n "${GH_STUB_DIR:-}" ] || use_gh_stub
    canonical="$(git -C "$project" rev-parse --symbolic-full-name "$base" 2>/dev/null || true)"
    case "$canonical" in refs/remotes/origin/*) ;; *) canonical="$(git -C "$project" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)" ;; esac
    base_at="$(git -C "$project" rev-parse --verify "$canonical^{commit}" 2>/dev/null || git -C "$project" rev-list --max-parents=0 "$head" | head -n 1)"
    fx_pr 7 "$head" "$(jq -cn --arg base "${canonical#refs/remotes/origin/}" '{base:{ref:$base}}')"
    printf '[]\n' > "$GH_STUB_DIR/reviews/7.json"
    printf '[]\n' > "$GH_STUB_DIR/activity.json"
    [ -n "$canonical" ] || return 0 # No trusted publishing baseline in this scenario yet.
    record="specs/changes/$change.md"; at="$head"
    if ! git -C "$project" cat-file -e "$head:$record" 2>/dev/null; then
        at="$(git -C "$project" log -1 --format=%H "$head" -- "$record")^"
    fi
    text="$(git -C "$project" show "$at:$record" 2>/dev/null || true)"
    cache="$(git -C "$project" rev-parse --absolute-git-dir)/receipt-fixtures"; mkdir -p "$cache"
    while IFS=$'\037' read -r line reviewer round from to verdict c h m l link; do
        [ -n "$line" ] || continue
        if [ "$reviewer" = owner ]; then
            [ "$verdict" = PASS ] || continue
            owner_key="$(printf '%s\n%s' "$change" "$line" | review_sha256)"
            if [ -f "$cache/owner-$owner_key" ]; then owner_commit="$(cat "$cache/owner-$owner_key")"
            elif [[ "$to" =~ ^[0-9a-f]{7,40}$ ]]; then
                owner_commit="$(git -C "$project" rev-parse --verify "$to^{commit}" 2>/dev/null || printf '%s' "$to")"
            elif review_is_fp "$to"; then
                owner_commit=""
                while IFS= read -r candidate; do
                    slice="$(review_fingerprint "$project" "$change" "$base_at" "$candidate" "${REVIEW_L01_PATHSPECS[@]}" 2>/dev/null)" || continue
                    if [ "$slice" = "$to" ]; then owner_commit="$candidate"; break; fi
                done < <(git -C "$project" rev-list "$head" --all --reflog)
            fi
            [ -z "$owner_commit" ] || printf '%s\n' "$owner_commit" > "$cache/owner-$owner_key"
            continue
        fi
        serial=$((serial+1))
        published=false
        key="$(printf '%s\n%s\n' "$change" "$line" | review_sha256)"
        if [ -f "$cache/$key" ]; then body="$(cat "$cache/$key")"
        else
            from_token="$from"; to_token="$to"; since=""; rhead=0000000000000000000000000000000000000000
            if [[ "$to" =~ ^[0-9a-f]{7,40}$ ]] && git -C "$project" rev-parse --verify "$to^{commit}" >/dev/null 2>&1; then
                rhead="$(git -C "$project" rev-parse "$to^{commit}")"
                to_token="$(review_fingerprint "$project" "$change" "$base_at" "$rhead")"
            fi
            if [[ "$from" =~ ^[0-9a-f]{7,40}$ ]] && git -C "$project" rev-parse --verify "$from^{commit}" >/dev/null 2>&1; then
                since="$(git -C "$project" rev-parse "$from^{commit}")"
                from_token="$(review_fingerprint "$project" "$change" "$base_at" "$since")"
                if [ "$from_token" = "$REVIEW_FP_EMPTY" ]; then from_token=start; since=""; fi
            elif [ "$from" != start ]; then since=0000000000000000000000000000000000000000; fi
            # A recipe whose full range became empty supplies no coverage receipt.
            # Real empty-content legacy clearance uses direct fixtures in its own suite.
            if [ "$from_token" = start ] && [ "$to_token" = "$REVIEW_FP_EMPTY" ] && [ "$verdict" = PASS ]; then continue; fi
            body="$(jq -cn --arg id "${key:0:32}" --arg change "$change" --arg reviewer "$reviewer" \
                --arg from "$from_token" --arg to "$to_token" --arg head "$rhead" --arg since "$since" \
                --arg base "$canonical" --arg base_at "$base_at" --arg verdict "$verdict" \
                --arg c "$c" --arg h "$h" --arg m "$m" --arg l "$l" --arg report "$link" '
                def count: try tonumber catch .;
                {schema:"prdkit.review.v3",id:$id,repo:"owner/repo",pr:7,change:$change,reviewer:$reviewer,
                 from:$from,to:$to,head:$head,since:$since,base:$base,base_at:$base_at,verdict:$verdict,
                 critical:($c|count),high:($h|count),medium:($m|count),low:($l|count),report:$report}')"
            body="$(printf '<!-- prdkit-review\n%s\n-->\n' "$body")"
            policy_ref="$(spec_trusted_refs "$project" | sed -n 1p)"
            fixture_registry="$( { git -C "$project" show "$policy_ref:.prdkit/memory/agents.md" 2>/dev/null || true; } | review_registry)"
            from_fp="$from_token"; [ "$from_fp" != start ] || from_fp="$REVIEW_FP_EMPTY"
            if [ "$rhead" != 0000000000000000000000000000000000000000 ] && [ "$from_fp" != "$to_token" ] &&
                [[ "$c,$h,$m,$l" =~ ^[0-9]+,[0-9]+,[0-9]+,[0-9]+$ ]] &&
                { [ "$verdict" = PASS ] || [ "$verdict" = FAIL ]; } &&
                [ "$(review_eligibility "$fixture_registry" "$reviewer")" = reviewer ] &&
                spec_trusted_refs "$project" | grep -xF -- "$canonical" >/dev/null; then
                publish_args=(); [ -z "$since" ] || publish_args=(--since "$since")
                publisher="$project/.prdkit/scripts/bash/publish-review.sh"
                # Minimal Git-only scenarios use the source helper with --repo, just as their
                # gate comes from another installed fixture. Never substitute a fake success.
                [ -f "$publisher" ] || publisher="$PK_ROOT/scripts/publish-review.sh"
                if ! publisher_output="$(bash "$publisher" "$change" --repo "$project" \
                    --pr https://github.com/owner/repo/pull/7 --reviewer "$reviewer" --verdict "$verdict" \
                    --counts "$c,$h,$m,$l" --report "$link" --head "$rhead" --base "$canonical" ${publish_args[@]+"${publish_args[@]}"} 2>&1)"; then
                    printf '%s\n' "$publisher_output" >&2; return 1
                fi
                body="$(jq -r .body "$GH_STUB_DIR/posted.json")"
                # The recipe's order, not whether this body was cached, sets fixture time.
                # POST/read-back has completed; align the replay metadata with fx_review.
                jq '.[-1].submittedAt="2026-01-02T00:00:00Z"' "$GH_STUB_DIR/reviews/7.json" > "$GH_STUB_DIR/reviews/7.next" &&
                    mv "$GH_STUB_DIR/reviews/7.next" "$GH_STUB_DIR/reviews/7.json" || return 1
                published=true
            fi
            printf '%s\n' "$body" > "$cache/$key"
        fi
        $published && continue
        fx_review 7 "$body" "$(jq -cn --argjson id "$((1000+serial))" '{fullDatabaseId:($id|tostring)}')"
    done < <(printf '%s\n' "$text" | awk "$SPEC_SKIP_AWK"'
        { if (spec_skip($0)) next }
        function trim(s) { gsub(/`/, "", s); gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
        function count(s,k, v) { if (!match(s,"[0-9]+ " k)) return "?"; v=substr(s,RSTART,RLENGTH); sub(/ .*/,"",v); return v }
        /^## / { section=$0; next }
        section=="## State" && /^\*\*(Review|Receipt fixture)\*\*:/ {
            original=$0; sub(/^\*\*(Review|Receipt fixture)\*\*:[[:space:]]*/,""); n=split($0,f," · ")
            range=trim(f[2]); cut=index(range,"..."); width=3; if (!cut) { cut=index(range,".."); width=2 }
            print original "\037" trim(f[3]) "\037" trim(f[1]) "\037" (cut?substr(range,1,cut-1):"") "\037" (cut?substr(range,cut+width):"") "\037" trim(f[4]) "\037" count(f[5],"critical") "\037" count(f[5],"high") "\037" count(f[5],"medium") "\037" count(f[5],"low") "\037" trim(f[n])
        }')
    if [ -n "$owner_commit" ]; then
        fx_owner_review 7 APPROVED "$owner_commit"
        fx_activity 0000000000000000000000000000000000000000 "$owner_commit" '{"activity_type":"branch_creation","timestamp":"2026-01-01T23:00:00Z"}'
        if [ "$owner_commit" != "$head" ]; then fx_activity "$owner_commit" "$head" '{"timestamp":"2026-01-02T01:00:00Z"}'; fi
    fi
}

receipt_run() { # real script [arguments]; use the real gate/close helper with the fixture host
    local script="$1"; shift
    local project=. head=HEAD base=origin/HEAD change="" arg previous=""
    for arg in "$@"; do
        case "$previous" in
            --repo) project="$arg"; previous=""; continue ;;
            --head) head="$arg"; previous=""; continue ;;
            --base) base="$arg"; previous=""; continue ;;
            --date|-m|--message|--pr|--receipts|--save-receipts) previous=""; continue ;;
        esac
        if [ -z "$change" ] && is_change_id "$arg"; then change="$arg"; fi
        previous="$arg"
    done
    [ -n "$change" ] || change="$(git -C "$project" branch --show-current)"
    head="$(git -C "$project" rev-parse "$head^{commit}")"
    if ! receipt_host "$project" "$change" "$head" "$base"; then OUTPUT='receipt fixture publication failed'; STATUS=1; return; fi
    receipt_raw_run ${receipt_env[@]+"${receipt_env[@]}"} bash "$script" --pr https://github.com/owner/repo/pull/7 "$@"
}

# Opt-in for suites whose existing scenarios are the fixture recipes above. Preparation happens
# outside the subprocess, so restricted-PATH tests still exercise the real script's dependencies.
receipt_raw_run() {
    if OUTPUT="$("$@" 2>&1)"; then STATUS=0; else STATUS=$?; fi
    return 0
}
run() {
    local receipt_env=() script
    local original=("$@")
    if [ "${1:-}" = env ]; then
        receipt_env+=(env); shift
        while [ "$#" -gt 0 ] && [ "$1" != bash ]; do receipt_env+=("$1"); shift; done
    fi
    if [ "${1:-}" = bash ]; then
        script="${2:-}"
        case "${script##*/}" in
            check-review.sh|close-change.sh) shift 2; receipt_run "$script" "$@"; return ;;
        esac
    fi
    receipt_raw_run "${original[@]}"
}
