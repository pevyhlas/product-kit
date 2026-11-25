#!/usr/bin/env bash
# agent-tiers-lib.sh — resolve agent models from the project tier map and check projections.
#
# Sourced by render-agents.sh, doctor.sh and check-adoption.sh (install-lib.sh must be
# sourced first). Bash 3.2 + POSIX awk; no jq, no network, no kit source checkout.
#
# The optional tier map lives in .prdkit/memory/agents.md and uses a pinned, vendored
# shared baseline with explicit local tier mappings:
#
#     Tier baseline: agent-library tiers.json@<commit>
#     Baseline snapshot: .prdkit/agent-library/tiers.json        (optional; this is the default)
#     | Local tier | Library tier |        local tier name -> baseline tier name
#     | Scope | Harness | Model | Variant | Reason |            deviations, each with a reason
#     | Projection tier | Claude effort | OpenCode permissions | OpenCode preamble |  (optional)
#     Banned models: <id>, <id>        (optional; exact ids, so each harness's form is listed)
#     Hand-owned agents: <name>, <name>   (optional; projections kept without a neutral source)
#
# The kit names no models: every id comes from the project's tier map or its vendored
# baseline snapshot. Fenced code blocks and HTML comments in agents.md are never parsed, so
# documentation examples cannot become configuration.

AT_DEFAULT_SNAPSHOT=".prdkit/agent-library/tiers.json"
AT_HARNESSES="claude opencode"

# --- parsing ---------------------------------------------------------------------------

# Tier map -> unit-separated records (one per line):
#   baseline <ref> <line> | baselinebad <text> <line> | snapshot <path> <line>
#   banned <id> <line> | handowned <agent> <line> | map <local> <library> <line>
#   override <scope> <harness> <model> <variant> <reason> <line> <has-reason-column>
#   literal <tier> <claude-model> <opencode-model> <opencode-variant> <line>
#   projection <tier> <effort> <permissions> <preamble> <line> | projectionbad <line> <reason>
at_tier_map_records() { # file [awk skip_fence(line) function]
    [ -f "$1" ] || return 0
    local expected skipper="${2:-}"
    expected="$(wc -l < "$1")" || return 1
    if [ -z "$skipper" ]; then
        skipper='function skip_fence(line) {
            if (infence) { if (line ~ /^[ \t]*(```|~~~)/) infence = 0; return 1 }
            if (line ~ /^[ \t]*(```|~~~)/) { infence = 1; return 1 }
            return 0
        }'
    fi
    awk -v expected="$expected" "$skipper"'
        function trim(s) { sub(/^[ \t\r]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
        function clean(s) {
            gsub(/`/, "", s); gsub(/\*\*/, "", s); s = trim(s)
            if (s == "-" || s == "—" || s == "–" || tolower(s) == "none" || tolower(s) == "n/a") s = ""
            return s
        }
        function after_colon(s) { sub(/^[^:]*:/, "", s); return trim(s) }
        function permission_actions(value,   actions, seen, count, j, action, out) {
            if (value == "" || value == "deny") return value
            count = split(value, actions, ",")
            for (j = 1; j <= count; j++) {
                action = trim(actions[j])
                if (action !~ /^[a-z][a-z0-9_]*$/ ||
                    action ~ /^(deny|none|null|nil|na)$/ || action in seen) return "!"
                seen[action] = 1
                out = out (j == 1 ? "" : " ") action
            }
            return out
        }
        function projection_row(   tier, effort, permissions, preamble) {
            if (nc != 4) { print "projectionbad", NR, "expected four Projection tier cells"; return }
            tier = tolower(cell[1]); effort = trim(raw[3]); permissions = permission_actions(trim(raw[4]))
            preamble = trim(raw[5])
            if (tier != "*" && tier !~ /^[a-z0-9][a-z0-9_-]*$/)
                print "projectionbad", NR, "expected a local Projection tier name or *"
            else if (tier in projection_seen)
                print "projectionbad", NR, "duplicate Projection tier " tier
            else if (effort != "" && effort !~ /^(low|medium|high|xhigh|max)$/)
                print "projectionbad", NR, "Claude effort must be low, medium, high, xhigh or max"
            else if (permissions == "!")
                print "projectionbad", NR, "OpenCode permissions must be deny or a comma-separated list of distinct action names (no wildcards or placeholders)"
            else if (tier == "*" && (effort != "" || permissions != ""))
                print "projectionbad", NR, "the * Projection tier row only sets a global OpenCode preamble"
            else if (preamble ~ /[[:cntrl:]]/)
                print "projectionbad", NR, "OpenCode preamble must be a single line without control characters"
            else if (effort == "" && permissions == "" && preamble == "")
                print "projectionbad", NR, "Projection tier row sets no options"
            else {
                projection_seen[tier] = 1
                print "projection", tier, effort, permissions, preamble, NR
            }
        }
        BEGIN { OFS = "\037"; incomment = 0; infence = 0; intable = 0; kind = "" }
        {
            line = $0; sub(/\r$/, "", line)
            if (!incomment && skip_fence(line)) { intable = 0; next }
            if (incomment) {
                p = index(line, "-->"); if (!p) next
                line = substr(line, p + 3); incomment = 0
            }
            if (intable && kind == "projection" && line ~ /^[ \t]*\|/ && line ~ /<!--|-->/) {
                print "projectionbad", NR, "HTML comments are not allowed in Projection tier rows"
                next
            }
            while ((p = index(line, "<!--")) > 0) {
                rest = substr(line, p + 4); q = index(rest, "-->")
                if (q) line = substr(line, 1, p - 1) substr(rest, q + 3)
                else { line = substr(line, 1, p - 1); incomment = 1 }
            }
            if (line ~ /^[ \t]*\|/) {
                if (line ~ /^[ \t]*\|[ \t:|-]+$/ && (kind != "projection" || !projection_separator)) {
                    projection_separator = 1; next             # separator row
                }
                n = split(line, raw, "|"); nc = 0
                for (i = 2; i <= n; i++) {
                    if (i == n && trim(raw[i]) == "") break
                    nc++; cell[nc] = clean(raw[i])
                }
                if (!intable) {
                    intable = 1; kind = ""
                    if (tolower(cell[1]) == "projection tier" && nc > 0) {
                        if (nc == 4 && tolower(cell[2]) == "claude effort" &&
                            tolower(cell[3]) == "opencode permissions" && tolower(cell[4]) == "opencode preamble") {
                            kind = "projection"; projection_separator = 0
                        } else print "projectionbad", NR, "expected Projection tier | Claude effort | OpenCode permissions | OpenCode preamble"
                        next
                    }
                    lt = lb = sc = hc = mc = vc = rc = cm = om = ov = oe = 0
                    for (i = 1; i <= nc; i++) {
                        h = tolower(cell[i])
                        if (h == "local tier") lt = i
                        if (h == "library tier" || h == "baseline tier") lb = i
                        if (h == "scope") sc = i
                        if (h == "harness") hc = i
                        if (h == "model") mc = i
                        if (h ~ /variant/ && h !~ /claude|opencode/) vc = i
                        if (h == "reason") rc = i
                        if (h ~ /claude/ && h ~ /model/) cm = i
                        if (h ~ /opencode/ && h ~ /model/) om = i
                        if (h ~ /opencode/ && h ~ /variant/) ov = i
                        if (h ~ /opencode/ && h ~ /effort/) oe = i
                    }
                    if (!ov) ov = oe
                    if (lt && lb) kind = "map"
                    else if (sc && mc) kind = "override"
                    else if (tolower(cell[1]) == "tier" && (cm || om)) kind = "literal"
                    next
                }
                if (kind == "projection") { projection_separator = 1; projection_row() }
                else if (kind == "map" && cell[lt] != "") print "map", tolower(cell[lt]), tolower(cell[lb]), NR
                else if (kind == "override" && (cell[sc] != "" || cell[mc] != "")) {
                    print "override", cell[sc], (hc ? tolower(cell[hc]) : ""), cell[mc], (vc ? cell[vc] : ""), (rc ? cell[rc] : ""), NR, (rc ? 1 : 0)
                } else if (kind == "literal" && cell[1] != "") {
                    print "literal", tolower(cell[1]), (cm ? cell[cm] : ""), (om ? cell[om] : ""), (ov ? cell[ov] : ""), NR
                }
                next
            }
            intable = 0; kind = ""
            plain = line; gsub(/`/, "", plain); gsub(/\*\*/, "", plain)
            sub(/^[ \t]*([-*][ \t]+)?/, "", plain)
            low = tolower(plain)
            if (low ~ /^tier baseline[ \t]*:/) {
                value = after_colon(plain)
                if (match(value, /agent-library[ \t]+tiers\.json@[0-9a-f]+/)) {
                    ref = substr(value, RSTART, RLENGTH); sub(/.*@/, "", ref)
                    if (length(ref) >= 7 && length(ref) <= 40) { print "baseline", ref, NR; next }
                }
                print "baselinebad", value, NR
            } else if (low ~ /^baseline snapshot[ \t]*:/) {
                value = after_colon(plain); sub(/[ \t].*$/, "", value)
                if (value != "") print "snapshot", value, NR
            } else if (low ~ /^banned models[ \t]*:/) {
                value = after_colon(plain); n = split(value, ids, ",")
                for (i = 1; i <= n; i++) { id = trim(ids[i]); if (id != "") print "banned", id, NR }
            } else if (low ~ /^hand-owned agents[ \t]*:/) {
                value = after_colon(plain); n = split(value, ids, ",")
                for (i = 1; i <= n; i++) { id = trim(ids[i]); if (id != "") print "handowned", id, NR }
            }
        }
        END { if (NR != expected) exit 1 }
    ' "$1"
}

# Shared tiers.json snapshot -> "tier <library-tier> <harness> <key> <value>" records, or a
# single "error <message>" record. Accepts objects, strings and string arrays/scalars (which
# are ignored); anything malformed fails closed.
at_tiers_json_records() {
    [ -f "$1" ] || { printf 'error\037file not found\n'; return 0; }
    LC_ALL=C awk '
        function fail(msg) { if (err == "") err = msg " at offset " pos; return 0 }
        function ws() { while (pos <= len && index(" \t\r\n", substr(doc, pos, 1)) > 0) pos++ }
        function str(   c, out) {
            if (substr(doc, pos, 1) != "\"") return fail("expected string")
            pos++; out = ""
            while (pos <= len) {
                c = substr(doc, pos, 1)
                if (c == "\\") {
                    c = substr(doc, pos + 1, 1)
                    if (c == "\"" || c == "\\" || c == "/") { out = out c; pos += 2; continue }
                    return fail("unsupported string escape")
                }
                if (c == "\"") { pos++; S = out; return 1 }
                if (c == "\t" || c == "\n" || c == "\r") return fail("control character in string")
                out = out c; pos++
            }
            return fail("unterminated string")
        }
        function scalar(   start) {
            start = pos
            while (pos <= len && index("-+.0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ", substr(doc, pos, 1))) pos++
            if (pos == start) return fail("unexpected character")
            return 1
        }
        function array(   c) {
            pos++; ws()
            if (substr(doc, pos, 1) == "]") { pos++; return 1 }
            while (1) {
                ws(); c = substr(doc, pos, 1)
                if (c == "\"") { if (!str()) return 0 }
                else if (!scalar()) return 0
                ws(); c = substr(doc, pos, 1)
                if (c == ",") { pos++; continue }
                if (c == "]") { pos++; return 1 }
                return fail("expected , or ]")
            }
        }
        function object(depth, path,   key, c) {
            ws()
            if (substr(doc, pos, 1) != "{") return fail("expected object")
            pos++; ws()
            if (substr(doc, pos, 1) == "}") { pos++; return 1 }
            while (1) {
                ws(); if (!str()) return 0
                key = S
                if (index(key, " ") || index(key, "\t")) return fail("key contains whitespace")
                ws()
                if (substr(doc, pos, 1) != ":") return fail("expected :")
                pos++; ws(); c = substr(doc, pos, 1)
                if (c == "{") {
                    if (depth >= 3) return fail("nesting deeper than tier/harness/key")
                    if (!object(depth + 1, (path == "" ? key : path "\037" key))) return 0
                } else if (c == "\"") {
                    if (!str()) return 0
                    if (depth == 3) out[++nout] = "tier\037" path "\037" key "\037" S
                } else if (c == "[") { if (!array()) return 0 }
                else if (!scalar()) return 0
                ws(); c = substr(doc, pos, 1)
                if (c == ",") { pos++; continue }
                if (c == "}") { pos++; return 1 }
                return fail("expected , or }")
            }
        }
        { doc = doc $0 "\n" }
        END {
            len = length(doc); pos = 1; err = ""; nout = 0
            if (object(1, "")) { ws(); if (pos <= len) fail("trailing content") }
            if (err != "") { print "error\037" err; exit }
            for (i = 1; i <= nout; i++) print out[i]
        }
    ' "$1"
}

at_hash_file() { install_hash_stream < "$1"; }

# Frontmatter value of a top-level key (quotes and trailing comments removed).
at_fm_value() { # file key
    awk -v key="$2" '
        NR == 1 { if ($0 != "---") exit; next }
        $0 == "---" { exit }
        index($0, key ":") == 1 {
            v = substr($0, length(key) + 2); sub(/^[ \t]+/, "", v); sub(/[ \t\r]+$/, "", v)
            if (v ~ /^".*"$/ || v ~ /^\047.*\047$/) v = substr(v, 2, length(v) - 2)
            else sub(/[ \t]+#.*$/, "", v)
            print v; exit
        }
    ' "$1"
}

at_fm_line() { # file key -> the raw frontmatter line
    awk -v key="$2" 'NR == 1 { if ($0 != "---") exit; next } $0 == "---" { exit } index($0, key ":") == 1 { print; exit }' "$1"
}

# Body after the frontmatter, with leading blank/generated-marker lines and trailing blank
# lines removed: the comparable prompt content.
at_body_norm() { # file
    awk '
        NR == 1 && $0 == "---" { infm = 1; next }
        infm { if ($0 == "---") infm = 0; next }
        { sub(/\r$/, "") }
        !started && ($0 ~ /^[ \t]*$/ || $0 ~ /^[ \t]*<!--.*([Gg]enerated|rendered from).*-->[ \t]*$/) { next }
        { started = 1; lines[++n] = $0 }
        END { while (n > 0 && lines[n] ~ /^[ \t]*$/) n--; for (i = 1; i <= n; i++) print lines[i] }
    ' "$1"
}

# Leading generated-marker comment lines of a projection body (kept across a re-render).
at_body_markers() { # file
    awk '
        NR == 1 && $0 == "---" { infm = 1; next }
        infm { if ($0 == "---") infm = 0; next }
        $0 ~ /^[ \t]*$/ { next }
        $0 ~ /^[ \t]*<!--.*([Gg]enerated|rendered from).*-->[ \t]*$/ { print; next }
        { exit }
    ' "$1"
}

# --- state ------------------------------------------------------------------------------

# Why a `Baseline snapshot:` path is unsafe, or nothing. The path must be relative, have no
# `..` segment, resolve (through symlinked directories) inside the repository root, and the
# snapshot and its .ref must not themselves be symlinks: --refresh-baseline writes there.
at_snapshot_path_problem() { # root rel
    local root="$1" rel="$2" dir real_root real_dir
    case "$rel" in
        /*) printf 'is absolute'; return 0 ;;
    esac
    case "/$rel/" in
        */../*) printf "has a '..' segment"; return 0 ;;
    esac
    real_root="$(CDPATH="" cd -P "$root" 2>/dev/null && pwd)" || { printf 'has an unreadable repository root'; return 0; }
    dir="$(dirname "$root/$rel")"
    while [ ! -d "$dir" ]; do dir="$(dirname "$dir")"; done
    real_dir="$(CDPATH="" cd -P "$dir" 2>/dev/null && pwd)" || { printf 'has an unreadable directory'; return 0; }
    case "$real_dir/" in
        "$real_root"/*) ;;
        *) printf 'resolves outside the repository'; return 0 ;;
    esac
    if [ -L "$root/$rel" ] || [ -L "$root/$rel.ref" ]; then printf 'is a symlink'; fi
    return 0
}

# Load the tier map + snapshot for a project root into AT_* globals.
at_load() { # root [awk skip_fence(line) function]
    local root="$1" rec
    AT_ROOT="$root"; AT_TIERMAP="$root/.prdkit/memory/agents.md"
    AT_MAP="$(at_tier_map_records "$AT_TIERMAP" "${2:-}")" || return 1
    AT_HAS_PROJECTION=false
    case $'\n'"$AT_MAP" in *$'\nprojection\037'*) AT_HAS_PROJECTION=true ;; esac
    AT_BASELINE="$(printf '%s\n' "$AT_MAP" | awk -F '\037' '!d && $1 == "baseline" { print $2; d = 1 }')" || return 1
    AT_BASELINE_BAD="$(printf '%s\n' "$AT_MAP" | awk -F '\037' '!d && $1 == "baselinebad" { print "line " $3 ": " $2; d = 1 }')" || return 1
    rec="$(printf '%s\n' "$AT_MAP" | awk -F '\037' '!d && $1 == "snapshot" { print $2 "\037" $3; d = 1 }')" || return 1
    AT_SNAPSHOT_REL=""; AT_SNAPSHOT_LINE=""
    if [ -n "$rec" ]; then
        IFS=$'\037' read -r AT_SNAPSHOT_REL AT_SNAPSHOT_LINE <<EOF
$rec
EOF
    fi
    AT_SNAPSHOT_REL="${AT_SNAPSHOT_REL:-$AT_DEFAULT_SNAPSHOT}"
    AT_SNAPSHOT="$root/$AT_SNAPSHOT_REL"
    AT_SNAP=""; AT_SNAP_ERR=""
    # A snapshot path outside the checkout is never read or written (refresh writes there).
    AT_SNAPSHOT_BAD="$(at_snapshot_path_problem "$root" "$AT_SNAPSHOT_REL")" || return 1
    if [ -n "$AT_SNAPSHOT_BAD" ]; then
        AT_SNAPSHOT=""
        if [ -n "$AT_BASELINE" ] || [ -n "$AT_BASELINE_BAD" ]; then AT_SNAP_ERR="unsafe"; fi
    elif [ -n "$AT_BASELINE" ] || [ -n "$AT_BASELINE_BAD" ]; then
        if [ -f "$AT_SNAPSHOT" ]; then
            AT_SNAP="$(at_tiers_json_records "$AT_SNAPSHOT")" || return 1
            AT_SNAP_ERR="$(printf '%s\n' "$AT_SNAP" | awk -F '\037' '!d && $1 == "error" { print $2; d = 1 }')" || return 1
            [ -z "$AT_SNAP_ERR" ] || AT_SNAP=""
        else
            AT_SNAP_ERR="missing"
        fi
    fi
}

# Shared input contract for the renderer and its verifier (also used by doctor/adoption).
at_load_checked() { # root
    local map="$1/.prdkit/memory/agents.md"
    AT_LOAD_ERR=""
    if [ -f "$map" ] && ! verify_lf_file "$map"; then
        AT_LOAD_ERR="Invalid tier map: expected non-empty LF-terminated text"
        return 1
    fi
    at_load "$1"
}

at_snap_value() { # library-tier harness key
    printf '%s\n' "$AT_SNAP" | awk -F '\037' -v t="$1" -v h="$2" -v k="$3" '!d && $1 == "tier" && $2 == t && $3 == h && $4 == k { print $5; d = 1 }'
}
at_snap_has_tier() { printf '%s\n' "$AT_SNAP" | awk -F '\037' -v t="$1" '$1 == "tier" && $2 == t { found = 1 } END { exit !found }'; }

# Opt-in settings for one local tier and harness. The global preamble is only a fallback.
at_projection_options() { # tier harness -> AT_P_EFFORT AT_P_PERMISSIONS AT_P_PREAMBLE
    local options
    AT_P_EFFORT="" AT_P_PERMISSIONS="" AT_P_PREAMBLE=""
    "$AT_HAS_PROJECTION" || return 0
    options="$(printf '%s\n' "$AT_MAP" | AT_P_TIER="$1" awk -F '\037' -v h="$2" '
        $1 == "projection" && $2 == "*" { global = $5; next }
        $1 == "projection" && $2 == ENVIRON["AT_P_TIER"] { effort = $3; permissions = $4; preamble = $5 }
        END {
            if (h == "claude") print effort "\037\037"
            else print "\037" permissions "\037" (preamble != "" ? preamble : global)
        }
    ')" || return 1
    IFS=$'\037' read -r AT_P_EFFORT AT_P_PERMISSIONS AT_P_PREAMBLE <<EOF
$options
EOF
}

at_projected_model() { # model variant permissions
    if [ -n "$3" ] && [ -n "$2" ]; then printf '%s#%s' "$1" "$2"
    else printf '%s' "$1"; fi
}

at_projected_body() { # def preamble
    local body
    if [ -z "$2" ]; then at_body_norm "$1"; return; fi
    body="$(at_body_norm "$1")" || return 1
    printf '%s\n' "$2"
    [ -z "$body" ] || printf '\n%s\n' "$body"
}

# The deny rule is first; OpenCode V2 applies the last matching rule. A non-empty
# action list grants those named actions only, for all resources.
at_native_fields() { # effort permissions
    local action
    if [ -n "$1" ]; then
        printf 'effort: %s\n' "$1"
    elif [ -n "$2" ]; then
        printf 'permissions:\n  - action: "*"\n    resource: "*"\n    effect: deny\n'
        if [ "$2" != deny ]; then
            # Word splitting is intentional: the parser produces space-separated identifiers.
            for action in $2; do
                printf '  - action: "%s"\n    resource: "*"\n    effect: allow\n' "$action"
            done
        fi
    fi
}

at_frontmatter() { # file, including delimiters (requires a complete header)
    awk 'NR == 1 && $0 != "---" { exit } { print } NR > 1 && $0 == "---" { closed = 1; exit }
         END { if (!closed) exit 1 }' "$1"
}

# A lexical scan, not YAML evaluation. Track node starts, flow collections and
# quoted/block scalar continuations. Compare bytes only to ASCII syntax; a byte
# from a UTF-8 scalar must never be passed to an awk regex as a character.
AT_YAML_SCAN_AWK='
    function indent(s) { match(s, /^ */); return RLENGTH }
    function yaml_blank(c) { return c == " " || c == "\t" }
    function flow_delimiter(c) { return c != "" && index("[]{},", c) > 0 }
    function scan_yaml(s,   n,i,c,nextc,prev,r,owner,start) {
        n = indent(s)
        if (quote == "" && !flow) {
            if (s ~ /^[ \t]*(#|$)/ || (block && n > block_indent)) return
            block = 0
            if (plain && n > plain_indent) return
            plain = 0; node = 1; done = 0
        }
        owner = n; start = n + 1
        for (i = start; i <= length(s); i++) {
            c = substr(s,i,1); nextc = substr(s,i+1,1); prev = substr(s,i-1,1)
            if (quote != "") {
                if ((quote == "\"" && c == "\\") || (quote == "\047" && c == quote && nextc == quote)) i++
                else if (c == quote) { quote = ""; done = 1 }
                continue
            }
            if (c == "#" && (node || i == start || yaml_blank(prev))) break
            if (yaml_blank(c)) continue
            if (flow && (c == "," || c == "]" || c == "}")) {
                node = (c == ","); done = !node; plain = 0
                if (!node) flow--
                continue
            }
            if (c == ":" && (nextc == "" || yaml_blank(nextc) ||
                    (flow && (done || flow_delimiter(nextc))))) {
                owner = key_indent; node = 1; done = plain = 0; continue
            }
            if (!node) continue
            r = substr(s,i)
            if (c == "!") {
                if (match(r, /^!<[^>]*>/) || match(r, /^![^][{}, \t]*/)) i += RLENGTH - 1
                continue
            }
            if ((c == "&" || c == "*") && nextc != "" && !flow_delimiter(nextc) && !yaml_blank(nextc)) {
                references = 1
                match(r, /^[^][{}, \t]+/); i += RLENGTH - 1
                if (c == "*") { node = 0; done = 1 }
                continue
            }
            key_indent = i - 1
            if ((c == "?" || (!flow && c == "-")) && (nextc == "" || yaml_blank(nextc))) {
                owner = key_indent; continue
            }
            if (!flow && match(r, /^[|>]([1-9][+-]?|[+-][1-9]?)?([ \t]+#.*|[ \t]*)$/)) {
                block = 1; block_indent = owner; return
            }
            if (c == "[" || c == "{") { flow++; done = plain = 0; continue }
            node = done = 0
            if (c == "\"" || c == "\047") quote = c
            else { plain = 1; plain_indent = owner }
        }
    }
'

# The line-oriented rewriter cannot migrate project-owned V1 fields or preserve YAML
# references across replaced entries. Report blockers in preflight, not during writes.
at_native_projection_findings() { # existing file permissions
    local proj="$1" findings
    if ! findings="$(LC_ALL=C awk -v opencode="$2" "$AT_YAML_SCAN_AWK"'
        NR == 1 {
            if ($0 == "---\r") { unsupported = 1; exit }
            if ($0 != "---") exit
            header = 1; next
        }
        $0 == "---" { closed = 1; exit }
        !quote && !flow && /^[ \t]*(#|$)/ { next }
        {
            scan_yaml($0)
            if ((!content && /^[ \t]/) || /^[{?!%]/ || /^\[/ || /^["\047][^:]*\\/) unsupported = 1
            content = 1
            if (opencode != "" && match($0, /^([A-Za-z_]+|"[A-Za-z_]+"|\047[A-Za-z_]+\047)[ \t]*:/)) {
                k = substr($0, 1, RLENGTH - 1); gsub(/["\047 \t]/, "", k)
                if (k ~ /^(name|tools|prompt|disable|maxSteps|temperature|top_p|options)$/ && !seen[k]++)
                    keys = keys (keys == "" ? "" : ", ") k
            }
        }
        END {
            if (header && !closed) print "has incomplete frontmatter; close it before opting in"
            if (unsupported) print "needs an LF-terminated, simple block mapping in frontmatter before opting in"
            if (references) print "may use YAML anchors or aliases in frontmatter; replace them with explicit values before opting in"
            if (keys != "") print "has OpenCode V1-only frontmatter keys: " keys "; migrate them manually before opting into V2 permissions"
        }
    ' "$proj")"; then
        findings="could not inspect frontmatter; verify the file is readable"
    fi
    local line
    while IFS= read -r line; do
        [ -z "$line" ] || printf 'Agent projection %s %s\n' "${proj#"$AT_ROOT"/}" "$line"
    done <<EOF
$findings
EOF
}

# Read just a model reference from a simple, unindented frontmatter mapping.
# Output a token, nothing (no model), or !<line> (the model cannot be verified).
at_opencode_model() { # projection
    LC_ALL=C awk "$AT_YAML_SCAN_AWK"'
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
        function invalid(ln) { bad = ln; exit }
        function finish_model() {
            if (model_line && model !~ /^[A-Za-z0-9_.+:\/@~%-]+(#[A-Za-z0-9_.+~-]+)?$/)
                invalid(model_line)
        }
        { sub(/\r$/, "") }
        NR == 1 {
            if ($0 != "---") {
                if ($0 ~ /^(\357\273\277)?[ \t]*---[ \t]*$/) invalid(NR)
                exit
            }
            header = 1; next
        }
        $0 == "---" { closed = 1; finish_model(); exit }
        /^[ \t]*$/ { if (model_block && model == "") leading_blank = 1; next }
        model_block && /^ / {
            if (model != "" && indent($0) < model_indent && /^[ ]+#/) next
            # Two nonempty content lines cannot fold to a single model token.
            if (model != "" || leading_blank) invalid(model_line)
            model = trim($0); model_indent = indent($0); next
        }
        !quote && !flow && /^[ \t]*#/ { next }
        /^[ \t]|^-[ \t]/ {
            if (!mapping) invalid(NR)
            if (!model_block && model_line == key_line) invalid(model_line)
            scan_yaml($0); next
        }
        {
            if (quote || flow) invalid(NR)
            if (!match($0, /^([A-Za-z0-9_.-]+|"[A-Za-z0-9_.-]+"|\047[A-Za-z0-9_.-]+\047)[ \t]*:([ \t]|$)/))
                invalid(NR)
            key = substr($0,1,RLENGTH); value = trim(substr($0,RLENGTH+1))
            gsub(/["\047: \t]/, "", key)
            mapping = 1; key_line = NR; model_block = 0
            if (key != "model") { scan_yaml($0); next }
            if (model_line) invalid(NR)
            model_line = NR
            if (value ~ /^[|>]([+-])?([ \t]+#.*|[ \t]*)$/) { model_block = 1; next }
            if (value ~ /^["\047]/) {
                if (!match(value, /^("[^"\\]*"|\047[^\047]*\047)([ \t]+#.*|[ \t]*)$/)) invalid(NR)
                sub(/[ \t]+#.*$/, "", value)
                model = substr(value,2,length(value)-2)
            } else { sub(/[ \t]+#.*$/, "", value); model = value }
            finish_model()
        }
        END {
            if (bad) print "!" bad
            else if (header && !closed) print "!" NR
            else if (model != "") print model
        }
    ' "$1"
}

# Filter only opted-in keys before the normal update. Remove the entire value, including
# nested entries, indentless YAML sequence items and multiline flow closing delimiters.
# Keep neighboring keys, top-level comments and the blank lines that separate entries.
at_native_frontmatter() { # existing file effort permissions projected-model
    local fields
    fields="$(at_native_fields "$2" "$3")" || return 1
    AT_NATIVE_FIELDS="$fields" awk -v effort="$2" -v permissions="$3" -v model="$4" '
        function key(s) {
            if (!match(s, /^([a-z]+|"[a-z]+"|\047[a-z]+\047)[ \t]*:/)) return ""
            s = substr(s, 1, RLENGTH - 1); gsub(/["\047 \t]/, "", s); return s
        }
        NR == 1 { if ($0 != "---") exit; print; next }
        skipping && /^[ \t]*$/ { blanks = blanks $0 "\n"; next }
        skipping && (/^[ \t]+[^ \t]/ || /^-[ \t]/ || /^[}\]]/) { blanks = ""; next }
        skipping { printf "%s", blanks; blanks = ""; if (!/^#/) skipping = 0 }
        {
            k = key($0)
            if (permissions != "" && k == "model") {
                if (!wrote_model) print "model: " model
                wrote_model = skipping = 1; next
            }
            if ((effort != "" && k == "effort") ||
                (permissions != "" && (k == "permission" || k == "permissions" || k == "variant"))) {
                if (!wrote && k != "variant") { print ENVIRON["AT_NATIVE_FIELDS"]; wrote = 1 }
                skipping = 1; next
            }
        }
        $0 == "---" {
            if (permissions != "" && !wrote_model) print "model: " model
            if (!wrote) print ENVIRON["AT_NATIVE_FIELDS"]
            print; closed = 1; exit
        }
        { print }
        END { if (!closed) exit 1 }
    ' "$1"
}

# Neutral-definition / provenance keys that never belong in a projection's frontmatter:
# OpenCode turns unknown frontmatter keys into model options, so provenance lives in YAML
# comments only.
AT_NEUTRAL_ONLY_KEYS="tier domain harnesses source library-ref library-agent"

at_norm_harness() { # override harness cell -> claude | opencode | * | invalid
    case "$1" in
        ''|'*'|all|any) printf '*' ;;
        claude|'claude code') printf 'claude' ;;
        opencode) printf 'opencode' ;;
        *) printf 'invalid' ;;
    esac
}

# Overrides that apply to (scope, harness): prints "model<TAB>variant" lines in ascending
# precedence (wildcard harness first, then the specific harness).
at_override_for() { # scope harness
    local rec h want scope harness model variant
    for want in '*' "$2"; do
        while IFS= read -r rec; do
            [ -n "$rec" ] || continue
            IFS=$'\037' read -r _ scope harness model variant _ <<EOF
$rec
EOF
            [ "$scope" = "$1" ] || continue
            h="$(at_norm_harness "$harness")"
            [ "$h" = "$want" ] || continue
            printf '%s\037%s\n' "$model" "$variant"
        done <<EOF
$(printf '%s\n' "$AT_MAP" | awk -F '\037' '$1 == "override"')
EOF
        [ "$want" = "$2" ] && break
    done
}

# Resolve (agent, tier, harness) -> AT_R_MODEL, AT_R_VARIANT, AT_R_SOURCE; AT_R_ERR on failure.
at_resolve() { # agent tier harness
    local agent="$1" tier="$2" harness="$3" lib="" model="" variant="" src="" scope m v
    AT_R_MODEL=""; AT_R_VARIANT=""; AT_R_SOURCE=""; AT_R_ERR=""
    if [ -z "$AT_BASELINE" ]; then
        AT_R_ERR="expected a Tier baseline: agent-library tiers.json@<commit> and reasoned overrides"
        return 1
    else
        lib="$(printf '%s\n' "$AT_MAP" | awk -F '\037' -v t="$tier" '!d && $1 == "map" && $2 == t { print $3; d = 1 }')"
        if [ -z "$lib" ] && at_snap_has_tier "$tier"; then lib="$tier"; fi
        if [ -n "$lib" ]; then
            model="$(at_snap_value "$lib" "$harness" model)"
            variant="$(at_snap_value "$lib" "$harness" variant)"
            [ -z "$model" ] || src="baseline $lib"
        fi
    fi
    for scope in "tier:$tier" "agent:$agent"; do
        while IFS=$'\037' read -r m v; do
            [ -n "$m$v" ] || continue
            [ -z "$m" ] || model="$m"
            [ -z "$v" ] || variant="$v"
            src="override $scope"
        done <<EOF
$(at_override_for "$scope" "$harness")
EOF
    done
    [ "$harness" = opencode ] || variant=""
    if [ -z "$model" ]; then
        if [ -n "$AT_BASELINE" ] && [ -z "$lib" ]; then
            AT_R_ERR="tier '$tier' has no Local tier -> Library tier mapping"
        elif [ -n "$AT_BASELINE" ]; then
            AT_R_ERR="baseline tier '$lib' has no $harness model"
        else
            AT_R_ERR="tier '$tier' has no $harness model in the tier map"
        fi
        return 1
    fi
    AT_R_MODEL="$model"; AT_R_VARIANT="$variant"; AT_R_SOURCE="$src"
}

at_is_banned() { # model
    [ -n "$1" ] || return 1
    printf '%s\n' "$AT_MAP" | awk -F '\037' -v m="$1" '$1 == "banned" && $2 == m { found = 1 } END { exit !found }'
}

at_known_projection_tier() { # local tier
    local def
    if at_snap_has_tier "$1" || printf '%s\n' "$AT_MAP" | awk -F '\037' -v t="$1" '
        ($1 == "map" && $2 == t) || ($1 == "override" && $2 == "tier:" t) { found = 1 }
        END { exit !found }
    '; then return 0; fi
    for def in "$AT_ROOT"/.prdkit/agents/*.md; do
        [ -f "$def" ] || continue
        [ "$(at_fm_value "$def" tier)" != "$1" ] || return 0
    done
    return 1
}

# A neutral definition's optional `harnesses:` frontmatter -> AT_DH_SET (true when the line is
# present), AT_DH_LIST (space-separated known names) and AT_DH_ERR (why it is malformed). Only
# a bracketed, non-empty list of projection harnesses is valid; anything else is a finding,
# never silently read as "every harness".
at_def_harnesses() { # def
    local line value inner name out=""
    local -a names
    AT_DH_SET=false; AT_DH_LIST=""; AT_DH_ERR=""
    line="$(at_fm_line "$1" harnesses)"
    [ -n "$line" ] || return 0
    AT_DH_SET=true
    value="$(printf '%s' "${line#harnesses:}" | tr -d '\r' | sed -e 's/[[:space:]][[:space:]]*#.*$//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    case "$value" in
        \[*\]) ;;
        *) AT_DH_ERR="'harnesses:' must be a bracketed list such as [opencode] or [claude, opencode], not '$value'"; return 0 ;;
    esac
    inner="${value#[}"; inner="${inner%]}"
    IFS=', ' read -r -a names <<EOF
$inner
EOF
    for name in ${names[@]+"${names[@]}"}; do
        name="$(printf '%s' "$name" | tr -d "\"'")"
        [ -n "$name" ] || continue
        case " $AT_HARNESSES " in
            *" $name "*) out="$out $name" ;;
            *) AT_DH_ERR="'harnesses:' names unknown harness '$name' (agent projections exist for: $(printf '%s' "$AT_HARNESSES" | sed 's/ /, /g'))"; return 0 ;;
        esac
    done
    [ -n "$out" ] || { AT_DH_ERR="'harnesses:' is an empty list; omit the line to project into every configured harness"; return 0; }
    AT_DH_LIST="${out# }"
}

# Harnesses a neutral definition projects into: configured in the manifest or with an
# existing agents directory, filtered by the definition's optional `harnesses:` list. A
# malformed list targets nothing (at_lint_definitions reports it; the render refuses).
at_targets() { # root def
    local root="$1" def="$2" configured harness out=""
    at_def_harnesses "$def"
    [ -z "$AT_DH_ERR" ] || return 0
    configured="$(install_manifest_value "$root/.prdkit/.manifest" harnesses 2>/dev/null || true)"
    for harness in $AT_HARNESSES; do
        case " $(printf '%s' "$configured" | tr ',' ' ') " in
            *" $harness "*) ;;
            *) [ -d "$root/.$harness/agents" ] || continue ;;
        esac
        if $AT_DH_SET; then
            case " $AT_DH_LIST " in *" $harness "*) ;; *) continue ;; esac
        fi
        out="$out $harness"
    done
    printf '%s' "${out# }"
}

at_is_hand_owned() { # agent
    printf '%s\n' "$AT_MAP" | awk -F '\037' -v a="$1" '$1 == "handowned" && $2 == a { found = 1 } END { exit !found }'
}

# A neutral definition's description value when the renderer owns it: a single-line scalar.
# Block scalars (`>`/`|`) stay project-owned in each projection and are not compared.
at_owned_description() { # def
    local value
    value="$(at_fm_value "$1" description)"
    case "$value" in '>'*|'|'*) return 0 ;; esac
    printf '%s' "$value"
}

# --- findings ---------------------------------------------------------------------------

# Static tier-map findings. Projects without an agent-tier map need no baseline.
at_lint() { at_lint_map && at_lint_definitions && at_lint_projection_bans; }

# Neutral-definition findings that make the render target set ambiguous: a `harnesses:` line
# that is not a bracketed list of known projection harnesses.
at_lint_definitions() {
    local def name
    for def in "$AT_ROOT"/.prdkit/agents/*.md; do
        [ -f "$def" ] || continue
        name="$(basename "$def" .md)"
        [ -n "$AT_BASELINE" ] || printf "Agent '%s': expected a Tier baseline: agent-library tiers.json@<commit> and reasoned overrides\n" "$name"
        at_def_harnesses "$def"
        [ -z "$AT_DH_ERR" ] || printf "Agent '%s': .prdkit/agents/%s.md %s\n" "$name" "$name" "$AT_DH_ERR"
    done
}

# Once a shared baseline is declared every projection must be rendered from a neutral
# definition or explicitly hand-owned: an unowned file in .claude/agents or .opencode/agents
# (no definition, or one whose harnesses: list excludes that harness) would otherwise keep
# its model and body with nothing checking either.
at_ownership_findings() {
    local harness proj name def why
    for harness in $AT_HARNESSES; do
        for proj in "$AT_ROOT/.$harness/agents"/*.md; do
            [ -f "$proj" ] || continue
            name="$(basename "$proj" .md)"
            def="$AT_ROOT/.prdkit/agents/$name.md"
            if [ -f "$def" ]; then
                case " $(at_targets "$AT_ROOT" "$def") " in *" $harness "*) continue ;; esac
                at_def_harnesses "$def"
                [ -z "$AT_DH_ERR" ] || continue   # reported by at_lint_definitions
                why="its neutral definition's harnesses: list excludes $harness"
            else
                why="no neutral definition .prdkit/agents/$name.md"
            fi
            at_is_hand_owned "$name" && continue
            printf "Agent projection .%s/agents/%s.md is unowned (%s), so nothing checks its model or body; add the definition and run render-agents.sh, remove the file, or list '%s' under 'Hand-owned agents:' in .prdkit/memory/agents.md\n" "$harness" "$name" "$why" "$name"
        done
    done
}

# Projections whose current model is banned. Kept apart from at_lint_map: render-agents.sh
# repairs these (it rewrites the model) once the map itself is clean, so they must not block
# the render that would fix them; --check, doctor and the adoption gate still report them.
at_lint_projection_bans() { # [--unverifiable-only]
    local proj model base only="${1:-}"
    printf '%s\n' "$AT_MAP" | awk -F '\037' '$1 == "banned" { f = 1 } END { exit !f }' || return 0
    for proj in "$AT_ROOT"/.claude/agents/*.md "$AT_ROOT"/.opencode/agents/*.md; do
        [ -f "$proj" ] || continue
        # Native V2 embeds the variant; a banned base id still applies to every variant.
        case "$proj" in
            "$AT_ROOT"/.opencode/agents/*.md)
                model="$(at_opencode_model "$proj")" || return 1
                if [[ "$model" == '!'* ]]; then
                    printf 'Agent projection %s line %s: model reference could not be verified; use a simple top-level model scalar\n' \
                        "${proj#"$AT_ROOT"/}" "${model#!}"
                    continue
                fi
                base="${model%%#*}"
                if [ "$base" != "$model" ] && at_is_banned "$base"; then model="$base"; fi ;;
            *) [ -z "$only" ] || continue
               model="$(at_fm_value "$proj" model)" || return 1 ;;
        esac
        [ -n "$only" ] || ! at_is_banned "$model" || printf "Agent projection %s uses banned model '%s'\n" "${proj#"$AT_ROOT"/}" "$model"
    done
}

# Tier map, override and snapshot findings (everything except projection content).
at_lint_map() {
    local rec kind a b c d e f model h snap_ref snap_sha actual
    # Only an opted-in map (a baseline line, valid or not, or an explicit snapshot line) reads
    # the snapshot, so only then is an unsafe path a finding; --refresh-baseline refuses it always.
    if [ -n "$AT_SNAPSHOT_BAD" ] && { [ -n "$AT_BASELINE" ] || [ -n "$AT_BASELINE_BAD" ] || [ -n "$AT_SNAPSHOT_LINE" ]; }; then
        if [ -n "$AT_SNAPSHOT_LINE" ]; then
            printf "Tier map line %s: 'Baseline snapshot:' path '%s' %s; it must be a relative path inside the repository\n" "$AT_SNAPSHOT_LINE" "$AT_SNAPSHOT_REL" "$AT_SNAPSHOT_BAD"
        else
            printf "Tier map: default baseline snapshot path '%s' %s; it must be a relative path inside the repository\n" "$AT_SNAPSHOT_REL" "$AT_SNAPSHOT_BAD"
        fi
    fi
    [ -z "$AT_BASELINE_BAD" ] || printf "Tier map: 'Tier baseline:' must read 'agent-library tiers.json@<7-40 hex commit>' (%s)\n" "$AT_BASELINE_BAD"
    if [ -n "$AT_BASELINE" ] && [ "$AT_SNAP_ERR" != unsafe ]; then
        if [ "$AT_SNAP_ERR" = missing ]; then
            printf 'Tier map: baseline snapshot %s is missing (vendor it: render-agents.sh --refresh-baseline <agent-library checkout>)\n' "$AT_SNAPSHOT_REL"
        elif [ -n "$AT_SNAP_ERR" ]; then
            printf 'Tier map: baseline snapshot %s is not valid tiers JSON (%s)\n' "$AT_SNAPSHOT_REL" "$AT_SNAP_ERR"
        elif [ ! -f "$AT_SNAPSHOT.ref" ]; then
            printf 'Tier map: baseline snapshot %s has no provenance file %s.ref (re-vendor with render-agents.sh --refresh-baseline)\n' "$AT_SNAPSHOT_REL" "$AT_SNAPSHOT_REL"
        else
            snap_ref="$(sed -n 's/^library-ref:[[:space:]]*//p' "$AT_SNAPSHOT.ref" | head -n1 | tr -d '[:space:]')"
            snap_sha="$(sed -n 's/^sha256:[[:space:]]*//p' "$AT_SNAPSHOT.ref" | head -n1 | tr -d '[:space:]')"
            case "$snap_ref" in
                "$AT_BASELINE"*) ;;
                *) printf 'Tier map: baseline names tiers.json@%s but the vendored snapshot is from %s (refresh the snapshot or the baseline line)\n' "$AT_BASELINE" "${snap_ref:-an unknown commit}" ;;
            esac
            actual="$(at_hash_file "$AT_SNAPSHOT")"
            [ "$actual" = "$snap_sha" ] || printf 'Tier map: vendored snapshot %s was edited after vendoring (sha256 mismatch); put deviations in the overrides table instead\n' "$AT_SNAPSHOT_REL"
        fi
    fi
    while IFS= read -r rec; do
        [ -n "$rec" ] || continue
        IFS=$'\037' read -r kind a b c d e f _ <<EOF
$rec
EOF
        case "$kind" in
            projectionbad)
                printf 'Tier map line %s: %s\n' "$a" "$b" ;;
            projection)
                if [ -z "$AT_BASELINE" ]; then
                    printf 'Tier map line %s: Projection tier options need a Tier baseline line\n' "$e"
                elif [ "$a" != '*' ] && [ -n "$AT_SNAP" ] && ! at_known_projection_tier "$a"; then
                    printf "Tier map line %s: unknown Projection tier '%s'; use a local tier name\n" "$e" "$a"
                fi ;;
            literal)
                printf "Tier map line %s: unsupported literal table for '%s'; expected a Tier baseline and overrides with a Reason\n" "$e" "$a" ;;
            map)
                [ -n "$AT_BASELINE" ] || printf 'Tier map line %s: a Local tier -> Library tier mapping needs a Tier baseline line\n' "$c"
                if [ -n "$AT_BASELINE" ] && [ -n "$AT_SNAP" ] && ! at_snap_has_tier "$b"; then
                    printf "Tier map line %s: library tier '%s' is not in the baseline snapshot\n" "$c" "$b"
                fi ;;
            override)
                h="$(at_norm_harness "$b")"
                case "$a" in
                    tier:?*|agent:?*) ;;
                    *) printf "Tier map line %s: override scope '%s' must be tier:<local tier> or agent:<agent name>\n" "$f" "$a" ;;
                esac
                [ "$h" != invalid ] || printf "Tier map line %s: override harness '%s' must be claude, opencode or *\n" "$f" "$b"
                [ -n "$c$d" ] || printf 'Tier map line %s: override names neither a model nor a variant\n' "$f"
                [ -n "$e" ] || printf "Tier map line %s: override for '%s' has no Reason; every deviation from the shared map records why\n" "$f" "$a"
                case "$a" in
                    agent:?*) [ -f "$AT_ROOT/.prdkit/agents/${a#agent:}.md" ] || printf "Tier map line %s: override names unknown agent '%s'\n" "$f" "${a#agent:}" ;;
                esac
                ! at_is_banned "$c" || printf "Tier map line %s: banned model '%s'\n" "$f" "$c" ;;
        esac
    done <<EOF
$AT_MAP
EOF
    if [ -n "$AT_SNAP" ]; then
        while IFS=$'\037' read -r _ a b c d; do
            [ "$c" = model ] || continue
            ! at_is_banned "$d" || printf "Tier map: baseline tier '%s' resolves %s to banned model '%s'; override it with a Reason\n" "$a" "$b" "$d"
        done <<EOF
$(printf '%s\n' "$AT_SNAP" | awk -F '\037' '$1 == "tier"')
EOF
    fi
}

# The new format expects separate model and variant tokens as input, not an already
# joined reference. Do not interpret whitespace, YAML punctuation or a second # as a model.
at_native_model_valid() { # model variant
    local model_pattern='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.+:/@~-]+$' variant_pattern='^[A-Za-z0-9_.+~-]+$'
    [[ "$1" =~ $model_pattern && "$1" != *: ]] && { [ -z "$2" ] || [[ "$2" =~ $variant_pattern ]]; }
}

# Projection findings for every neutral definition and target harness.
#   include_missing  report absent projections (doctor reports those itself)
at_projection_findings() { # include_missing
    local include_missing="$1" def name tier harness proj current model variant key desc targets actual body native blockers
    for def in "$AT_ROOT"/.prdkit/agents/*.md; do
        [ -f "$def" ] || continue
        name="$(basename "$def" .md)"
        tier="$(at_fm_value "$def" tier)" || return 1
        targets="$(at_targets "$AT_ROOT" "$def")" || return 1
        for harness in $targets; do
            proj="$AT_ROOT/.$harness/agents/$name.md"
            if ! at_resolve "$name" "$tier" "$harness"; then
                printf "Agent '%s': no %s model resolves (%s)\n" "$name" "$harness" "$AT_R_ERR"
                continue
            fi
            at_projection_options "$tier" "$harness" || return 1
            if [ -n "$AT_P_PERMISSIONS" ] && ! at_native_model_valid "$AT_R_MODEL" "$AT_R_VARIANT"; then
                printf "Agent '%s': OpenCode V2 projection requires a provider/model id and an optional separate variant token\n" "$name"
                continue
            fi
            if [ ! -f "$proj" ]; then
                [ "$include_missing" != true ] || printf "Agent '%s': no projection in .%s/agents/ (run render-agents.sh)\n" "$name" "$harness"
                continue
            fi
            if [ -n "$AT_P_EFFORT$AT_P_PERMISSIONS" ]; then
                blockers="$(at_native_projection_findings "$proj" "$AT_P_PERMISSIONS")" || return 1
                if [ -n "$blockers" ]; then printf '%s\n' "$blockers"; continue; fi
            fi
            model="$(at_projected_model "$AT_R_MODEL" "$AT_R_VARIANT" "$AT_P_PERMISSIONS")"
            current="$(at_fm_value "$proj" model)" || return 1
            [ "$current" = "$model" ] ||
                printf "Agent '%s': .%s/agents/%s.md model '%s' differs from resolved '%s' (%s); run render-agents.sh\n" "$name" "$harness" "$name" "${current:-<none>}" "$model" "$AT_R_SOURCE"
            if [ "$harness" = opencode ]; then
                for key in $AT_NEUTRAL_ONLY_KEYS; do
                    actual="$(at_fm_line "$proj" "$key")" || return 1
                    [ -z "$actual" ] ||
                        printf "Agent '%s': .opencode/agents/%s.md carries neutral/provenance key '%s:' as a field (OpenCode passes unknown keys to the model as options); keep provenance in YAML comments\n" "$name" "$name" "$key"
                done
                if [ -z "$AT_P_PERMISSIONS" ]; then
                    variant="$(at_fm_value "$proj" variant)" || return 1
                    [ "$variant" = "$AT_R_VARIANT" ] ||
                        printf "Agent '%s': .%s/agents/%s.md variant '%s' differs from resolved '%s' (%s); run render-agents.sh\n" "$name" "$harness" "$name" "${variant:-<none>}" "${AT_R_VARIANT:-<none>}" "$AT_R_SOURCE"
                fi
            fi
            if [ -n "$AT_P_EFFORT$AT_P_PERMISSIONS" ]; then
                if ! actual="$(at_frontmatter "$proj")" ||
                    ! native="$(at_native_frontmatter "$proj" "$AT_P_EFFORT" "$AT_P_PERMISSIONS" "$model")" || [ "$actual" != "$native" ]; then
                    key=effort
                    [ -z "$AT_P_PERMISSIONS" ] || key='native model/permissions frontmatter or legacy variant'
                    printf "Agent '%s': .%s/agents/%s.md %s differs from the Projection tier settings; run render-agents.sh\n" "$name" "$harness" "$name" "$key"
                fi
            fi
            desc="$(at_owned_description "$def")" || return 1
            if [ -n "$desc" ]; then
                actual="$(at_fm_value "$proj" description)" || return 1
                [ "$actual" = "$desc" ] ||
                    printf "Agent '%s': .%s/agents/%s.md description differs from the neutral definition; run render-agents.sh\n" "$name" "$harness" "$name"
            fi
            actual="$(at_body_norm "$proj")" || return 1
            body="$(at_projected_body "$def" "$AT_P_PREAMBLE")" || return 1
            [ "$actual" = "$body" ] ||
                printf "Agent '%s': .%s/agents/%s.md prompt body differs from the neutral definition; run render-agents.sh\n" "$name" "$harness" "$name"
        done
    done
}

# Entry point for doctor/adoption/render --check.
#   agent_tier_findings <root> [--include-missing] [--always-projections]
# Projection checks run when the tier map declares a shared baseline (the opt-in), or always
# with --always-projections (render-agents.sh --check).
agent_tier_findings() {
    local root="$1" include_missing=false always=false
    shift
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --include-missing) include_missing=true ;;
            --always-projections) always=true ;;
        esac
        shift
    done
    if ! at_load_checked "$root"; then
        [ -n "$AT_LOAD_ERR" ] || return 1
        printf '%s\n' "$AT_LOAD_ERR"; return
    fi
    at_lint || return 1
    if $always || [ -n "$AT_BASELINE" ]; then
        if [ -z "$AT_BASELINE" ] || [ -n "$AT_SNAP" ]; then
            at_projection_findings "$include_missing" || return 1
        fi
    fi
    [ -z "$AT_BASELINE" ] || at_ownership_findings
}
