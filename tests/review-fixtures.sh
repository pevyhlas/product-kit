#!/usr/bin/env bash
# Phase-A bridge for the existing coverage scenarios: their record text is a *test recipe*,
# never gate evidence. Translate the recipe into publisher-authored v3 host fixtures before
# invoking the real gate. Cache publication tokens/base_at so later base updates cannot rewrite
# what the fixture publisher reviewed. New authority tests use fx_review directly instead.
# shellcheck disable=SC2016,SC2034 # Literal jq variables; run outputs consumed by suites.
source "$PK_ROOT/scripts/common.sh"
source "$PK_ROOT/scripts/spec-lib.sh"
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
    [ -n "${GH_STUB_DIR:-}" ] || use_gh_stub
    canonical="$(git -C "$project" rev-parse --symbolic-full-name "$base" 2>/dev/null || true)"
    case "$canonical" in refs/remotes/origin/*) ;; *) canonical="$(git -C "$project" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null || true)" ;; esac
    base_at="$(git -C "$project" rev-parse --verify "$canonical^{commit}" 2>/dev/null || git -C "$project" rev-list --max-parents=0 "$head" | head -n 1)"
    fx_pr 7 "$head" "$(jq -cn --arg base "${canonical#refs/remotes/origin/}" '{base:{ref:$base}}')"
    printf '[]\n' > "$GH_STUB_DIR/reviews/7.json"
    [ -n "$canonical" ] || return 0 # No trusted publishing baseline in this scenario yet.
    record="specs/changes/$change.md"; at="$head"
    if ! git -C "$project" cat-file -e "$head:$record" 2>/dev/null; then
        at="$(git -C "$project" log -1 --format=%H "$head" -- "$record")^"
    fi
    text="$(git -C "$project" show "$at:$record" 2>/dev/null || true)"
    cache="$(git -C "$project" rev-parse --absolute-git-dir)/receipt-fixtures"; mkdir -p "$cache"
    while IFS=$'\037' read -r line reviewer round from to verdict c h m l link; do
        [ -n "$line" ] && [ "$reviewer" != owner ] || continue
        serial=$((serial+1))
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
            body="$(jq -cn --arg id "${key:0:32}" --arg change "$change" --arg reviewer "$reviewer" \
                --arg from "$from_token" --arg to "$to_token" --arg head "$rhead" --arg since "$since" \
                --arg base "$canonical" --arg base_at "$base_at" --arg verdict "$verdict" \
                --arg c "$c" --arg h "$h" --arg m "$m" --arg l "$l" --arg report "$link" '
                def count: try tonumber catch .;
                {schema:"prdkit.review.v3",id:$id,repo:"owner/repo",pr:7,change:$change,reviewer:$reviewer,
                 from:$from,to:$to,head:$head,since:$since,base:$base,base_at:$base_at,verdict:$verdict,
                 critical:($c|count),high:($h|count),medium:($m|count),low:($l|count),report:$report}')"
            body="$(printf '<!-- prdkit-review\n%s\n-->\n' "$body")"
            printf '%s\n' "$body" > "$cache/$key"
        fi
        fx_review 7 "$body" "$(jq -cn --argjson id "$((1000+serial))" '{fullDatabaseId:($id|tostring)}')"
    done < <(printf '%s\n' "$text" | awk "$SPEC_SKIP_AWK"'
        { if (spec_skip($0)) next }
        function trim(s) { gsub(/`/, "", s); gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
        function count(s,k, v) { if (!match(s,"[0-9]+ " k)) return "?"; v=substr(s,RSTART,RLENGTH); sub(/ .*/,"",v); return v }
        /^## / { section=$0; next }
        section=="## State" && /^\*\*Review\*\*:/ {
            original=$0; sub(/^\*\*Review\*\*:[[:space:]]*/,""); n=split($0,f," · ")
            range=trim(f[2]); cut=index(range,"..."); width=3; if (!cut) { cut=index(range,".."); width=2 }
            print original "\037" trim(f[3]) "\037" trim(f[1]) "\037" (cut?substr(range,1,cut-1):"") "\037" (cut?substr(range,cut+width):"") "\037" trim(f[4]) "\037" count(f[5],"critical") "\037" count(f[5],"high") "\037" count(f[5],"medium") "\037" count(f[5],"low") "\037" trim(f[n])
        }')
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
    receipt_host "$project" "$change" "$head" "$base"
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
