#!/usr/bin/env bash
# Test-local, failure-only observations. Never print fixture data, paths or raw tool output.

tiers_diag_original_failure() { # literal-relative-item file|manifest actual-exit
    [ "${TIERS_DIAG_CAPTURE:-false}" = true ] || return 0
    case "$1" in
        .prdkit/scripts/bash/render-agents.sh) TIERS_DIAG_ORIGINAL_ITEM=renderer ;;
        .prdkit/templates/agent-definition-template.md) TIERS_DIAG_ORIGINAL_ITEM=template ;;
        *) TIERS_DIAG_ORIGINAL_ITEM=unavailable ;;
    esac
    TIERS_DIAG_ORIGINAL_CHECK="$2"
    TIERS_DIAG_ORIGINAL_STATUS="$3"
}

_tiers_diag_code() {
    case "$1" in ''|*[!0-9]*) printf unavailable; return ;; esac
    if [ "${#1}" -le 3 ] && [ "$1" -le 255 ]; then printf '%s' "$1"
    else printf unavailable; fi
}

_tiers_diag_count() {
    case "$1" in ''|*[!0-9]*) printf unavailable; return ;; esac
    if [ "${#1}" -le 9 ]; then printf '%s' "$1"; else printf unavailable; fi
}

_tiers_diag_hash() {
    local value
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        value="$(sha256sum < "$1")" || return
    elif command -v shasum >/dev/null 2>&1; then
        value="$(shasum -a 256 < "$1")" || return
    else return 127; fi
    value="${value%% *}"
    [ "${#value}" -eq 64 ] || return 1
    case "$value" in *[!0-9a-f]*) return 1 ;; esac
    printf '%s' "$value"
}

_tiers_diag_manifest() (
    # Refuse unreadable/NUL-bearing input before a text utility can change its bytes.
    set -o pipefail
    local bytes text
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    bytes="$(wc -c < "$1")" || return
    text="$(LC_ALL=C tr -d '\000' < "$1" | wc -c)" || return
    [ "${bytes//[[:space:]]/}" = "${text//[[:space:]]/}" ] || return 1
    LC_ALL=C awk '
        substr($0,65,2) == "  " && substr($0,1,64) ~ /^[0-9a-f]+$/ {
            if(substr($0,67) == ".prdkit/scripts/bash/render-agents.sh") renderer++
            if(substr($0,67) == ".prdkit/templates/agent-definition-template.md") template++
        }
        /^options: / {
            options++
            value = "invalid"
            if($0 == "options: none") value = "none"
            if($0 == "options: agent-tiers") value = "agent-tiers"
        }
        END { print renderer+0, template+0, (options == 1 ? value : "unavailable") }
    ' "$1"
)

tiers_diag_emit() ( # synthetic project; isolate all recheck state from the test
    local root="$1" data measured retained=0 rows_r=unavailable rows_t=unavailable options=unavailable
    local item rel src rows exists file link readable executable kind grep_status
    local source_hash source_status installed_hash installed_status manifest_hash manifest_status
    local original_item="${TIERS_DIAG_ORIGINAL_ITEM:-unavailable}"
    local original_check="${TIERS_DIAG_ORIGINAL_CHECK:-unavailable}"
    case "$original_item" in renderer|template) ;; *) original_item=unavailable ;; esac
    case "$original_check" in file|manifest) ;; *) original_check=unavailable ;; esac
    [ "${TIERS_DIAG_FIRST_OUTPUT+x}" != x ] || retained=1
    printf 'optional-diag v=1 observed=original item=%s check=%s status=%s predicate_status=1 upgrade_status=%s output_retained=%s\n' \
        "$original_item" "$original_check" "$(_tiers_diag_code "${TIERS_DIAG_ORIGINAL_STATUS:-}")" \
        "$(_tiers_diag_code "${TIERS_DIAG_FIRST_STATUS:-}")" "$retained"
    if data="$(_tiers_diag_manifest "$root/.prdkit/.manifest" 2>/dev/null)"; then
        measured=0
        IFS=' ' read -r rows_r rows_t options <<< "$data"
        rows_r="$(_tiers_diag_count "$rows_r")"; rows_t="$(_tiers_diag_count "$rows_t")"
        case "$options" in none|agent-tiers|invalid|unavailable) ;; *) options=unavailable ;; esac
    else measured=$?; fi
    if manifest_hash="$(_tiers_diag_hash "$root/.prdkit/.manifest" 2>/dev/null)"; then manifest_status=0
    else manifest_status=$?; manifest_hash=unavailable; fi
    printf 'optional-diag observed=recheck item=manifest measure_status=%s options=%s sha256=%s hash_status=%s\n' \
        "$measured" "$options" "$manifest_hash" "$manifest_status"
    for item in renderer template; do
        case "$item" in
            renderer) rel=.prdkit/scripts/bash/render-agents.sh; src=scripts/render-agents.sh; rows="$rows_r" ;;
            template) rel=.prdkit/templates/agent-definition-template.md; src=templates/agent-definition-template.md; rows="$rows_t" ;;
        esac
        exists=0; file=0; link=0; readable=0; executable=0; kind=not-observed
        [ ! -e "$root/$rel" ] || exists=1
        [ ! -f "$root/$rel" ] || file=1
        [ ! -L "$root/$rel" ] || link=1
        [ ! -r "$root/$rel" ] || readable=1
        [ ! -x "$root/$rel" ] || executable=1
        if [ "$link" -eq 1 ]; then kind=symlink
        elif [ "$file" -eq 1 ]; then kind=regular
        elif [ -d "$root/$rel" ]; then kind=directory
        elif [ "$exists" -eq 1 ]; then kind=other; fi
        if grep -qF "  $rel" "$root/.prdkit/.manifest" >/dev/null 2>&1; then grep_status=0
        else grep_status=$?; fi
        if source_hash="$(_tiers_diag_hash "$root/.product-kit/$src" 2>/dev/null)"; then source_status=0
        else source_status=$?; source_hash=unavailable; fi
        if installed_hash="$(_tiers_diag_hash "$root/$rel" 2>/dev/null)"; then installed_status=0
        else installed_status=$?; installed_hash=unavailable; fi
        printf 'optional-diag observed=recheck item=%s exists=%s file=%s link=%s readable=%s executable=%s type=%s grep_status=%s exact_rows=%s source_sha256=%s source_hash_status=%s installed_sha256=%s installed_hash_status=%s\n' \
            "$item" "$exists" "$file" "$link" "$readable" "$executable" "$kind" "$grep_status" "$rows" \
            "$source_hash" "$source_status" "$installed_hash" "$installed_status"
    done
)
