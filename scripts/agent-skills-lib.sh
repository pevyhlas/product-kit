#!/usr/bin/env bash
# Sourced by agent-tiers-lib.sh. Parse only the YAML subset used by skill projection.
# AT_ROOT and AT_MAP come from the tier library; callers consume the AS_* plan.
# shellcheck disable=SC2153,SC2034

# Output unit-separated records. Keep arbitrary input out of shell syntax and record
# separators; diagnostic labels are display-only. Use the tier library's lexical scan
# to distinguish top-level keys from unrelated multiline values. Use the C locale
# so the scanner can walk bytes; only split text at ASCII syntax boundaries.
as_records() { # neutral|metadata|claude file
    LC_ALL=C awk -v mode="$1" "$AT_DELIMITER_AWK$AT_YAML_SCAN_AWK"'
        BEGIN { OFS = "\037" }
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
        function report(ln, label, msg) {
            gsub(/[[:cntrl:]]/, "?", label); print "error", ln, label, msg
        }
        function unreadable(ln) {
            if (mode == "metadata") report(ln, "", "unreadable metadata; use a simple map of single-line values")
            else if (mode == "claude") report(ln, "", "unreadable Claude tools/frontmatter; use a simple mapping and a list of tool names")
            else report(ln, "", "unreadable skills: declaration; use a single-line bracketed list")
        }
        # Read a simple key and its value. Escaped, explicit and merge keys are not
        # supported, since they can hide a second metadata, needs or tools field.
        function pair(s) {
            # Use octal for the slash: BusyBox treats \/ in a bracket as backslash or slash.
            if (!match(s, /^([-A-Za-z0-9_.\057]+|"[-A-Za-z0-9_.\057]+"|\047[-A-Za-z0-9_.\057]+\047)[ \t]*:([ \t]|$)/)) return 0
            key = substr(s, 1, RLENGTH); value = trim(substr(s, RLENGTH + 1)) # awk-bytes-ok: split at the matched ASCII colon and spaces
            sub(/[ \t]*:[ \t]*$/, "", key); gsub(/["\047]/, "", key)
            return 1
        }
        # Split a single-line flow collection or strip a trailing comment. Commas
        # and comments inside quoted strings are data. No nesting or double-quote escapes.
        function cells(s, sep, out,   i,c,q,start,n) {
            for (i in out) delete out[i]
            start = 1; n = 0; comment = ""
            for (i = 1; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (q != "") {
                    if (q == "\"" && c == "\\") return -1
                    if (q == c) {
                        if (q == "\047" && substr(s, i+1, 1) == q) i++
                        else q = ""
                    }
                } else if (c == "#" && (i == 1 || yaml_blank(substr(s, i-1, 1)))) {
                    comment = substr(s, i); s = substr(s, 1, i-1); break # awk-bytes-ok: split at an ASCII comment marker
                } else if (c == "\"" || c == "\047") q = c
                else if (c == sep) { out[++n] = trim(substr(s, start, i-start)); start = i+1 } # awk-bytes-ok: both ends are ASCII separators or string boundaries
            }
            if (q != "") return -1
            out[++n] = trim(substr(s, start)) # awk-bytes-ok: start is the string boundary or directly after an ASCII separator
            return n
        }
        function scalar(s,   q) {
            token = s; q = substr(s, 1, 1)
            if (q == "\"" || q == "\047") {
                if (s !~ /^("[^"\\]*"|\047([^\047]|\047\047)*\047)$/) return 0
                token = substr(s, 2, length(s)-2) # awk-bytes-ok: remove the verified ASCII quote at each end
                if (q == "\047") gsub(/\047\047/, "\047", token)
            } else if ((q != "" && index("!&*?@`|>%,{}[]", q)) || s ~ /^-([ \t]|$)|:[ \t]|:$/) return 0
            return token !~ /[\001-\010\013-\037\177]/
        }
        function skill(s, ln) {
            if (!scalar(s)) token = s
            if (length(token) > 64 || token !~ /^[a-z0-9]+(-[a-z0-9]+)*$/)
                report(ln, (token == "" ? "<empty>" : token), "invalid skill id (expected lowercase kebab-case, 1–64 characters)")
            else if (ids[token]++) report(ln, token, "duplicate skill id")
            else print "skill", ln, token
        }
        function tool_name(s, ln) {
            if (s !~ /^[A-Za-z][A-Za-z0-9_.-]*$/) { unreadable(ln); return }
            if (s == "Bash") bash_tool = 1
            if (s == "Skill") skill_tool = 1
        }
        function tool(s, ln) {
            if (!scalar(s) || tolower(s) ~ /^(true|false|null)$/) unreadable(ln)
            else tool_name(token, ln)
        }
        function tools(s, ln,   i,n,a,q,clean,suffix) {
            n = cells(s, "", a)
            if (n < 0) { unreadable(ln); return }
            clean = a[1]; suffix = (comment == "" ? "" : " " comment)
            if (clean == "") { block_tools = 1; return }
            if (clean ~ /^\[.*\]$/) {
                s = trim(substr(clean, 2, length(clean)-2)); n = cells(s, ",", a) # awk-bytes-ok: remove the verified ASCII brackets
                if (n < 0) { unreadable(ln); return }
                if (n && a[n] == "") n--
                for (i = 1; i <= n; i++) tool(a[i], ln)
                sub(/,[ \t]*$/, "", s)
                tool_edit = "tools: [" s (n ? ", " : "") "Skill]" suffix
            } else {
                if (!scalar(clean) || trim(token) == "" || tolower(clean) ~ /^(true|false|null)$/) { unreadable(ln); return }
                q = substr(clean, 1, 1); if (q != "\"" && q != "\047") q = ""
                s = trim(token); n = split(s, a, ",")
                for (i = 1; i <= n; i++) tool_name(trim(a[i]), ln)
                tool_edit = "tools: " q s ", Skill" q suffix
            }
        }
        function metadata_entry(s, ln,   a,k,i,n,w) {
            if (!pair(s)) { unreadable(ln); return }
            k = key
            if (keys[k]++ || cells(value, "", a) < 0 || !scalar(a[1]) ||
                (a[1] ~ /^[^"\047]/ && a[1] ~ /[][{},]/ && in_flow_metadata)) { unreadable(ln); return }
            if (k != "prdkit/needs" || trim(token) == "") return
            n = split(trim(token), w, /[ \t]+/)
            for (i = 1; i <= n; i++) {
                if (w[i] !~ /^(bash|python3|git|gh|dotnet|network)$/)
                    report(ln, "", "unknown prdkit/needs token: " w[i])
                else needs = needs (needs == "" ? "" : ",") w[i]
            }
        }
        function metadata(s, ln,   a,n,i) {
            n = cells(s, "", a)
            if (n < 0) { unreadable(ln); return }
            s = a[1]
            if (s == "") { block_metadata = 1; return }
            if (s !~ /^\{.*\}$/) { unreadable(ln); return }
            in_flow_metadata = 1
            s = trim(substr(s, 2, length(s)-2)) # awk-bytes-ok: remove the verified ASCII braces
            n = cells(s, ",", a)
            if (n < 0) { unreadable(ln); return }
            if (n && a[n] == "") n--
            for (i = 1; i <= n; i++) metadata_entry(a[i], ln)
            in_flow_metadata = 0
        }
        function skills(s, ln,   a,n,i) {
            n = cells(s, "", a)
            if (n < 0 || a[1] !~ /^\[.*\]$/) { unreadable(ln); return }
            s = trim(substr(a[1], 2, length(a[1])-2)); n = cells(s, ",", a) # awk-bytes-ok: remove the verified ASCII brackets
            if (n > 1 && a[n] == "") n--
            if (n < 0 || s == "") { unreadable(ln); return }
            for (i = 1; i <= n; i++) skill(a[i], ln)
        }
        function finish_entry() {
            if (block_metadata && !child_indent) unreadable(entry)
            if (block_tools && !tool_line) unreadable(entry)
            entry = block_metadata = block_tools = child_indent = 0
        }
        NR == 1 {
            opening = frontmatter_delimiter($0)
            if (opening == "absent" && /^(\357\273\277)?[ \t]*---[ \t]+#/) opening = "unsupported"
            if (opening == "absent") exit
            if (opening != "canonical") header_bad = NR
            next
        }
        {
            if (sub(/\r$/, "") && !header_bad) header_bad = NR
            if ($0 ~ /^---([ \t]*|[ \t]+#.*)$/) {
                if ($0 != "---" && !header_bad) header_bad = NR
                closed = 1; exit
            }
            if (!quote && !flow && /^[ \t]*(#|$)/) next
            if (entry && (/^[ \t]/ || /^-[ \t]/)) {
                if (block_metadata && /^ +[^ \t]/ && (!child_indent || child_indent == indent($0))) {
                    child_indent = indent($0); metadata_entry(trim($0), NR)
                } else if (block_tools && /^ *-[ \t]+/ && (!tool_line || child_indent == indent($0))) {
                    child_indent = indent($0); tool_line = NR
                    tool_edit = substr($0, 1, child_indent) "- Skill"
                    item = trim($0); sub(/^-[ \t]+/, "", item)
                    if (cells(item, "", piece) < 0) unreadable(NR); else tool(piece[1], NR)
                } else unreadable(NR)
                next
            }
            if (entry) finish_entry()
            if (quote || flow || /^[ \t]/ || /^-[ \t]/) {
                if (mode == "neutral" && !mapping && !quote && !flow && pair(trim($0)) && key == "skills") {
                    seen = 1; unreadable(NR)
                }
                if (!mapping && !bad_root) bad_root = NR
                scan_yaml($0); next
            }
            if (!pair($0)) {
                if (!bad_root) bad_root = NR
                scan_yaml($0); next
            }
            mapping = 1
            if ((mode == "neutral" && key == "skills") || (mode == "metadata" && key == "metadata") ||
                (mode == "claude" && key == "tools")) {
                if (seen++) { unreadable(NR); next }
                entry = NR
                print "entry", NR
                if (mode == "neutral") skills(value, NR)
                else if (mode == "metadata") metadata(value, NR)
                else { tools_line = NR; tools(value, NR) }
            } else scan_yaml($0)
        }
        END {
            if (entry) finish_entry()
            if (mode == "neutral" && !seen) exit
            if (opening != "absent" && (!closed || quote || flow || header_bad || bad_root))
                unreadable(header_bad ? header_bad : (bad_root ? bad_root : (NR ? NR : 1)))
            if (mode == "metadata" && needs != "") print "needs", needs
            if (mode == "claude") {
                if (!seen || bash_tool) print "shell"
                if (seen && !skill_tool && tool_edit != "") {
                    if (index(tool_edit, "\037")) { unreadable(tools_line); exit }
                    print (tool_line ? "insert" : "replace"), tool_line ? tool_line : tools_line, tool_edit
                }
            }
        }
    ' "$2"
}

as_finding() { # source line skill message
    AS_FINDINGS="$AS_FINDINGS$(printf "Agent '%s': %s line %s: skill '%s': %s" "$AS_NAME" "$1" "$2" "${3:-<list>}" "$4")"$'\n'
}

as_config() { # Load only for a declaring agent. Defaults may search plugin subdirectories.
    local kind value line roots_seen=false prefix_seen=false rel rest more LC_ALL=C
    AS_PREFIX=""; AS_ROOTS=()
    while IFS=$'\037' read -r kind value line; do
        case "$kind" in
            skillroots)
                if $roots_seen || [ -z "$value" ]; then
                    as_finding .prdkit/memory/agents.md "$line" "$AS_FIRST" "expected one nonempty 'Skill roots:' setting"
                else
                    rest="$value"; more=true
                    while $more; do
                        rel="${rest%%,*}"
                        if [[ "$rest" == *,* ]]; then rest="${rest#*,}"; else more=false; fi
                        rel="${rel#"${rel%%[!$' \t']*}"}"; rel="${rel%"${rel##*[!$' \t']}"}"
                        if [[ "$rel" =~ ^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$ && "/$rel/" != */../* && "/$rel/" != */./* ]]; then
                            AS_ROOTS+=("$AT_ROOT/$rel")
                        else
                            as_finding .prdkit/memory/agents.md "$line" "$AS_FIRST" "'Skill roots:' must list comma-separated repository-relative directories (no wildcards or . or .. segments)"
                            break
                        fi
                    done
                fi
                roots_seen=true ;;
            skillprefix)
                if $prefix_seen || [[ ! "$value" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
                    as_finding .prdkit/memory/agents.md "$line" "$AS_FIRST" "expected one 'Claude skill prefix:' setting with a plugin name"
                else
                    AS_PREFIX="$value"
                fi
                prefix_seen=true ;;
        esac
    done <<EOF
$AT_MAP
EOF
    if ! $roots_seen; then
        AS_ROOTS=("$AT_ROOT"/.claude/skills/*/skills "$AT_ROOT/.agents/skills")
    fi
}

as_skill_needs() { # id -> AS_NEEDS, validating all vendored copies
    local id="$1" dir path file root physical found=false records kind field label msg needs
    AS_NEEDS=""
    root="$(CDPATH="" cd -P "$AT_ROOT" && pwd)" || return 1
    for dir in "${AS_ROOTS[@]}"; do
        path="$dir/$id/SKILL.md"; file="${path#"$AT_ROOT"/}"
        [ -e "$path" ] || [ -L "$path" ] || continue
        physical="$(CDPATH="" cd -P "$dir/$id" 2>/dev/null && pwd)" || physical=""
        if [[ "$physical/" != "$root/"* ]] || [ -L "$path" ]; then
            as_finding "$file" 1 "$id" "SKILL.md must be a regular file inside the repository, not a file symlink"
            found=true; continue
        fi
        if [ ! -f "$path" ] || ! review_file_without_nul "$path" || ! records="$(as_records metadata "$path")"; then
            as_finding "$file" 1 "$id" "unreadable SKILL.md metadata"
            found=true; continue
        fi
        needs=""
        while IFS=$'\037' read -r kind field label msg; do
            case "$kind" in
                needs) needs="$field" ;;
                error) as_finding "$file" "$field" "$id" "$msg" ;;
            esac
        done <<EOF
$records
EOF
        if $found && [ "$needs" != "$AS_NEEDS" ]; then
            as_finding "$AS_DEF" "$AS_LINE" "$id" "vendored copies disagree on prdkit/needs (including $file)"
        else
            AS_NEEDS="$needs"
        fi
        found=true
    done
    $found || as_finding "$AS_DEF" "$AS_LINE" "$id" "no vendored skill directory containing SKILL.md in the configured roots"
}

# Common preflight for write and check/doctor/adoption. No declaration means no
# settings validation or skill-file access, even if those settings or files exist.
as_definition() { # def
    local records kind field label msg prior
    AS_DEF="${1#"$AT_ROOT"/}"; AS_NAME="${1##*/}"; AS_NAME="${AS_NAME%.md}"
    AS_LINE=""; AS_FIRST=""; AS_SKILLS=""; AS_FINDINGS=""
    records="$(as_records neutral "$1")" || return 1
    [ -n "$records" ] || return 0
    while IFS=$'\037' read -r kind field label msg; do
        case "$kind" in
            entry) AS_LINE="$field" ;;
            skill) AS_FIRST="${AS_FIRST:-$label}" ;;
            error) as_finding "$AS_DEF" "$field" "$label" "$msg" ;;
        esac
    done <<EOF
$records
EOF
    [ -n "$AS_FIRST" ] || return 0
    prior="$AS_FINDINGS"
    as_config
    [ "$AS_FINDINGS" = "$prior" ] || return 0
    while IFS=$'\037' read -r kind field label; do
        [ "$kind" = skill ] || continue
        as_skill_needs "$label" || return 1
        AS_SKILLS="$AS_SKILLS$label $AS_NEEDS"$'\n'
    done <<EOF
$records
EOF
}

# The V2 action list passed here is exactly the one used to emit the role rules.
# Claude inherits all tools without a restriction; otherwise Bash must be listed.
# Claude preloads all declarations even when a restricted agent has no Bash; the
# runnable subset is only used by the OpenCode allowlist and evidence notes.
as_projection() { # harness proj permissions
    local has_shell=false runnable="" list="" records kind field label msg id needs blockers
    AS_FINDINGS=""; AS_OC=""; AS_NOTES=""; AS_CLAUDE=""; AS_TOOL_ACTION=""; AS_TOOL_LINE=""; AS_TOOL_EDIT=""
    [ -n "$AS_SKILLS" ] || return 0
    if [ "$1" = opencode ]; then
        if [ -z "$3" ]; then
            as_finding "$AS_DEF" "$AS_LINE" "$AS_FIRST" "OpenCode permissions are not renderer-owned; set the local tier's OpenCode permissions cell to opt into V2, or exclude OpenCode in harnesses:"
            return 0
        fi
        case " $3 " in *" shell "*) has_shell=true ;; esac
    else
        if [ -z "$AS_PREFIX" ]; then
            as_finding "$AS_DEF" "$AS_LINE" "$AS_FIRST" "set 'Claude skill prefix:' to the plugin name in .prdkit/memory/agents.md"
            return 0
        fi
    fi
    if [ -f "$2" ]; then
        blockers="$(at_native_projection_findings "$2" "$3")" || return 1
        while IFS= read -r msg; do
            [ -z "$msg" ] || as_finding "$AS_DEF" "$AS_LINE" "$AS_FIRST" "$msg"
        done <<EOF
$blockers
EOF
    fi
    if [ "$1" = claude ]; then
        if [ -f "$2" ]; then
            records="$(as_records claude "$2")" || return 1
            while IFS=$'\037' read -r kind field label msg; do
                case "$kind" in
                    shell) has_shell=true ;;
                    insert|replace) AS_TOOL_ACTION="$kind"; AS_TOOL_LINE="$field"; AS_TOOL_EDIT="$label" ;;
                    error) as_finding "${2#"$AT_ROOT"/}" "$field" "$AS_FIRST" "$msg" ;;
                esac
            done <<EOF
$records
EOF
        else
            has_shell=true
        fi
    fi
    while read -r id needs; do
        [ -n "$id" ] || continue
        if $has_shell || [ -z "$needs" ]; then runnable="$runnable $id"
        elif [ "$1" = opencode ]; then
            # shellcheck disable=SC2016 # Literal Markdown code spans.
            AS_NOTES="$AS_NOTES$(printf 'Skill `%s` needs a shell (%s), which you cannot run here. When the review package carries its output (`%s.json`, `%s.md`), read the facts there; otherwise list them as unverified.' "$id" "$needs" "$id" "$id")"$'\n'
        fi
        list="$list${list:+, }$AS_PREFIX:$id"
    done <<EOF
$AS_SKILLS
EOF
    if [ "$1" = opencode ]; then AS_OC="deny$runnable"; else AS_CLAUDE="skills: [$list]"; fi
}
