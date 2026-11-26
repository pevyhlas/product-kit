#!/usr/bin/env bash
# Sourced by agent-tiers-lib.sh. Parse only the YAML subset used by skill projection.
# AT_ROOT and AT_MAP come from the tier library; callers consume the AS_* plan.
# shellcheck disable=SC2153,SC2034

# Output unit-separated records. Keep arbitrary input out of shell syntax and record
# separators; diagnostic labels are display-only. Use the tier library's lexical scan
# to distinguish top-level keys from unrelated multiline values. Use the C locale
# so the scanner can walk bytes; only split text at ASCII syntax boundaries.
as_records() { # neutral|metadata|claude|opencode file [projected skills line or "1" for OpenCode]
    LC_ALL=C awk -v mode="$1" -v projected="${3:-}" "$AT_DELIMITER_AWK$AT_YAML_SCAN_AWK"'
        BEGIN { OFS = "\037"; mark = "# prdkit-skill-projection: "; active = projected != "" }
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
        function report(ln, label, msg) {
            gsub(/[[:cntrl:]]/, "?", label); print "error", ln, label, msg
        }
        function unreadable(ln) {
            if (mode == "metadata") report(ln, "", "unreadable metadata; use a simple map of single-line values")
            else if (mode == "claude") report(ln, "", "unreadable Claude tools/frontmatter; use a simple mapping and a list of tool names")
            else if (mode == "opencode") report(ln, "", "unreadable OpenCode frontmatter; use a simple mapping")
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
        # Inspect only potential aliases for the reserved neutral key. This is not
        # a validator for unrelated YAML keys. Decode ASCII hex escapes by value;
        # other valid escapes cannot contribute a letter to "skills".
        function strip_properties(s) {
            while (sub(/^(!<[^>]*>|[!&][^ \t]*)([ \t]+|$)/, "", s)) {}
            return s
        }
        function possible_skills_key(s, explicit,   q,c,i,j,n,d,cp,text,tail,escaped,invalid) {
            s = strip_properties(s)
            if (explicit ? s ~ /^skills([ \t]+#.*|[ \t]*)$/ : s ~ /^skills[ \t]*:([ \t]|$)/) return 1
            q = substr(s, 1, 1)
            if (q != "\"" && q != "\047") return 0
            for (i = 2; i <= length(s); i++) {
                c = substr(s, i, 1)
                if (c == q) {
                    if (q == "\047" && substr(s, i+1, 1) == q) { text = text q; i++; continue }
                    tail = substr(s, i+1) # awk-bytes-ok: begins immediately after the ASCII closing quote
                    if (explicit ? tail !~ /^([ \t]+#.*|[ \t]*)$/ : tail !~ /^[ \t]*:([ \t]|$)/)
                        return explicit && index(s, "skills") && tail !~ /^[ \t]*:([ \t]|$)/
                    return text == "skills" || invalid
                }
                if (q != "\"" || c != "\\") { text = text c; continue }
                escaped = 1; c = substr(s, ++i, 1)
                n = (c == "x" ? 2 : (c == "u" ? 4 : (c == "U" ? 8 : 0)))
                if (!n) {
                    if (c == "" || !index("0abtnvfre \"/\\N_LP\t", c)) invalid = 1
                    text = text "?"; continue
                }
                cp = 0
                for (j = 1; j <= n; j++) {
                    c = substr(s, i+j, 1)
                    d = (c == "" ? 0 : index("0123456789abcdef", c))
                    if (!d && c != "") { d = index("ABCDEF", c); if (d) d += 10 }
                    if (!d) break
                    cp = cp * 16 + d - 1
                }
                if (j <= n) { invalid = 1; continue }
                i += n
                if (cp > 1114111 || (cp >= 55296 && cp <= 57343)) invalid = 1
                text = text (cp > 0 && cp < 128 ? sprintf("%c", cp) : "?")
            }
            return escaped || (explicit && index(s, "skills"))
        }
        # Accumulate just the scalar node of a root "? ..." key. Property-only
        # lines can precede the node, whose scalar style controls line joining.
        function explicit_start(s) {
            explicit_key = NR
            explicit_text = explicit_style = ""
            explicit_indent = explicit_strip = explicit_more = explicit_blanks = explicit_lead = explicit_ambiguous = 0
            sub(/^\?[ \t]*/, "", s)
            explicit_line(s)
        }
        function linebreaks(n,   s) {
            while (n-- > 0) s = s "\n"
            return s
        }
        function explicit_line(s,   n,part,more,sep,i) {
            if (explicit_style != "") {
                n = indent(s)
                if (s ~ /^ *$/ && (!explicit_indent || n <= explicit_indent)) {
                    if (!explicit_indent && n > explicit_lead) explicit_lead = n
                    explicit_blanks++; return
                }
                if (!explicit_indent) {
                    explicit_indent = n
                    if (explicit_lead > n) explicit_ambiguous = 1
                }
                if (n < explicit_indent) {
                    if (s !~ /^[ \t]*#/) {
                        explicit_ambiguous = 1
                        explicit_text = explicit_text "\n" trim(s)
                    }
                    return
                }
                part = substr(s, explicit_indent + 1) # awk-bytes-ok: skip only verified leading ASCII spaces
                more = n > explicit_indent || part ~ /^\t/
                sep = explicit_blanks + (explicit_text != "")
                if (explicit_style == ">" && explicit_text != "" && !explicit_more && !more) {
                    if (!explicit_blanks) explicit_text = explicit_text " "
                    sep = explicit_blanks
                }
                explicit_text = explicit_text linebreaks(sep) part
                explicit_blanks = 0; explicit_more = more; return
            }
            part = trim(s)
            if (explicit_text == "") {
                part = strip_properties(part)
                if (part ~ /^(#|$)/) return
                if (block_scalar_header(part)) {
                    explicit_style = substr(part, 1, 1)
                    explicit_strip = part ~ /^[|>][1-9]?-/
                    explicit_indent = block_scalar_indent(part)
                    return
                }
            } else if (part == "") { explicit_blanks++; return }
            else if (quote != "" || part !~ /^#/) {
                # A double-quoted backslash-newline suppresses ordinary folding.
                for (i = length(explicit_text); i > 0 && substr(explicit_text, i, 1) == "\\"; i--) {}
                if (quote == "\"" && (length(explicit_text) - i) % 2) sub(/\\$/, "", explicit_text)
                else if (!explicit_blanks) explicit_text = explicit_text " "
            } else return
            explicit_text = explicit_text linebreaks(explicit_blanks) part; explicit_blanks = 0
        }
        function explicit_finish() {
            if (!explicit_key || bad_root) { explicit_key = 0; return }
            if (explicit_style != "") {
                # Clip/keep preserve at least one newline in a nonempty block.
                if (!explicit_strip && explicit_text != "") explicit_text = explicit_text "\n"
                if (explicit_text == "skills" || (explicit_ambiguous && index(explicit_text, "skills"))) bad_root = explicit_key
            } else if (possible_skills_key(explicit_text, 1) ||
                (explicit_text ~ /^[*@`]/ && index(explicit_text, "skills"))) bad_root = explicit_key
            explicit_key = 0
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
            if (s == "Skill") skill_tool++
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
            if (n > 32) { report(ln, "", "declare at most 32 skills"); return }
            for (i = 1; i <= n; i++) skill(a[i], ln)
        }
        function ownership_error(ln) {
            report(ln, "", "cannot establish Claude skill projection ownership; restore the generated comments and fields from a known-good projection before rendering")
        }
        function native_skills_error(ln) {
            report(ln, "", "put native Claude skills on one line as a flow list ([a, b]) before rendering")
        }
        function marker(s) {
            if (s ~ /^begin [1-4]$/ && !mark_from) { mark_from = NR; mark_count = $NF + 0 }
            else if (!mark_from || mark_to || NR != mark_last + 1) ownership_error(NR)
            else if (s == "end") mark_to = NR
            else if (index(s, "generated-skills ") == 1 && NR == mark_from + 1)
                generated_skills = substr(s, length("generated-skills ") + 1) # awk-bytes-ok: strip the verified ASCII record prefix
            else if (index(s, "prior-skills ") == 1 && prior_skills == "" && prior_tool == "" && generated_tool == "")
                prior_skills = substr(s, length("prior-skills ") + 1) # awk-bytes-ok: strip the verified ASCII record prefix
            else if (index(s, "prior-tool ") == 1 && prior_tool == "" && generated_tool == "")
                prior_tool = substr(s, length("prior-tool ") + 1) # awk-bytes-ok: strip the verified ASCII record prefix
            else if (index(s, "generated-tool ") == 1 && generated_tool == "")
                generated_tool = substr(s, length("generated-tool ") + 1) # awk-bytes-ok: strip the verified ASCII record prefix
            else ownership_error(NR)
            mark_last = NR
        }
        function flow_list(s,   a) { return cells(s, "", a) >= 0 && a[1] ~ /^\[.*\]$/ }
        function saved_skills(s) { return pair(s) && key == "skills" && flow_list(value) }
        # A saved inline edit is reversible only if it is the same edit we would
        # derive from the original line. Do not trust comment text as YAML to replay.
        function valid_inline_record(   saved_edit,saved_skill,ok) {
            if (!pair(prior_tool) || key != "tools") return 0
            saved_edit = tool_edit; saved_skill = skill_tool
            tool_edit = ""; skill_tool = 0
            tools(value, mark_from)
            ok = !block_tools && !skill_tool && tool_edit == generated_tool && tool_edit != ""
            tool_edit = saved_edit; skill_tool = saved_skill; block_tools = 0
            return ok
        }
        function claude_plan(   i,hit,action,line,edit) {
            if (mark_last && (!mark_from || !mark_to || mark_to - mark_from - 1 != mark_count ||
                !saved_skills(generated_skills) || (prior_skills != "" && !saved_skills(prior_skills)))) {
                ownership_error(mark_last); return
            }
            if (!active && skills_line && (skills_line != mark_to + 1 ||
                (raw_skills != generated_skills && raw_skills != prior_skills))) {
                ownership_error(skills_line); return
            }
            if (prior_tool != "" && !valid_inline_record()) {
                ownership_error(mark_from); return
            }
            if (generated_tool != "") {
                if (!block_tool_list && prior_tool != "" && tools_line &&
                    (raw_tools == prior_tool || raw_tools == generated_tool)) {
                    if (active && raw_tools == prior_tool) { action = "replace"; line = tools_line; edit = generated_tool }
                    if (!active && raw_tools == generated_tool) { action = "replace"; line = tools_line; edit = prior_tool }
                } else if (block_tool_list && prior_tool == "" && generated_tool ~ /^ *- Skill$/) { # awk-bytes-ok: record sliced only after an ASCII prefix
                    for (i in tool_rows) if (tool_rows[i] == generated_tool) hit = i
                    if (skill_tool == 1 && hit) {
                        if (!active) {
                            if (tool_count == 1) { ownership_error(hit); return }
                            action = "delete"; line = hit
                        }
                    } else if (!skill_tool && tool_line && tool_edit == generated_tool) {
                        if (active) { action = "insert"; line = tool_line; edit = generated_tool }
                    } else { ownership_error(mark_from); return }
                } else { ownership_error(mark_from); return }
            } else if (active && !skill_tool && tool_edit != "") {
                action = (tool_line ? "insert" : "replace"); line = (tool_line ? tool_line : tools_line); edit = tool_edit
                generated_tool = edit
                if (action == "replace") prior_tool = raw_tools
            }
            if (index(prior_skills prior_tool generated_tool, "\037")) { ownership_error(mark_from ? mark_from : NR); return }
            if (action != "") print "tool", line, action, edit
            if (mark_from || skills_line) print "state", mark_from+0, mark_to+0, skills_line+0
            if (active) {
                if (!mark_from) prior_skills = raw_skills
                if (index(prior_skills, "\037")) { ownership_error(skills_line); return }
                print "save", mark "begin " (1 + (prior_skills != "") + (prior_tool != "") + (generated_tool != ""))
                print "save", mark "generated-skills " projected
                if (prior_skills != "") print "save", mark "prior-skills " prior_skills
                if (prior_tool != "") print "save", mark "prior-tool " prior_tool
                if (generated_tool != "") print "save", mark "generated-tool " generated_tool
                print "save", mark "end"
                print "save", projected
            } else if (prior_skills != "") print "restore", prior_skills
        }
        function finish_entry() {
            if (block_metadata && !child_indent) unreadable(entry)
            if (block_tools && !tool_line) unreadable(entry)
            entry = block_metadata = block_tools = child_indent = native_skills_entry = 0
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
            if (mode == "claude" && !quote && /^[ \t]*#/) {
                comment_line = $0; sub(/^[ \t]+/, "", comment_line)
                if (!yaml_block_content($0) && index(comment_line, "# prdkit-skill-projection:") == 1) {
                    marked = 1
                    if (flow)
                        report(NR, "", "Claude skill projection ownership records cannot be rewritten inside a YAML flow collection")
                    else if (index(comment_line, mark) == 1)
                        marker(substr(comment_line, length(mark) + 1)) # awk-bytes-ok: strip the verified ASCII marker prefix
                    else ownership_error(NR)
                    next
                }
            }
            if (mode == "neutral" && explicit_key) {
                if (quote || flow || /^[ \t]|^$/) explicit_line($0)
                else if (/^#/) {} # Comments between an explicit key and its node/value.
                else explicit_finish()
            }
            if (!quote && !flow && /^[ \t]*(#|$)/) next
            if (entry && (/^[ \t]/ || /^-[ \t]/)) {
                if (block_metadata && /^ +[^ \t]/ && (!child_indent || child_indent == indent($0))) {
                    child_indent = indent($0); metadata_entry(trim($0), NR)
                } else if (block_tools && /^ *-[ \t]+/ && (!tool_line || child_indent == indent($0))) {
                    child_indent = indent($0); tool_line = NR
                    tool_rows[NR] = $0; tool_count++
                    tool_edit = substr($0, 1, child_indent) "- Skill"
                    item = trim($0); sub(/^-[ \t]+/, "", item)
                    if (cells(item, "", piece) < 0) unreadable(NR); else tool(piece[1], NR)
                } else if (native_skills_entry) {
                    if (!native_skills_invalid) native_skills_error(entry)
                    native_skills_invalid = 1
                } else unreadable(NR)
                next
            }
            if (entry) finish_entry()
            if (quote || flow || /^[ \t]/ || /^-[ \t]/) {
                if (!unsafe && (((quote || flow) && /^[^ \t]/) ||
                    (single_line && !(block && root_key == "description")))) unsafe = NR
                if (mode == "neutral" && !mapping && !quote && !flow && pair(trim($0)) && key == "skills") {
                    seen = 1; unreadable(NR)
                }
                if (mode != "neutral" && !mapping && !bad_root) bad_root = NR
                scan_yaml($0); next
            }
            if (!pair($0) || (mode != "metadata" && $0 !~ /^[-A-Za-z0-9_.\057]+:([ \t]|$)/)) {
                if (mode == "neutral") {
                    mapping = 1
                    if ($0 ~ /^\?([ \t]|$)/) explicit_start($0)
                    else if (!bad_root && possible_skills_key($0, 0)) bad_root = NR
                    root_key = ""; single_line = 0
                } else if (!bad_root) bad_root = NR
                scan_yaml($0); next
            }
            mapping = 1
            root_key = key
            single_line = key ~ /^(name|description|tier|harnesses|model|variant|domain|source|library-ref|library-agent)$/
            if (mode == "claude" && key == "skills") {
                block = plain = 0
                if (skills_line) unreadable(NR)
                native_skills_invalid = !flow_list(value)
                if (native_skills_invalid) native_skills_error(NR)
                skills_line = NR; raw_skills = $0; entry = NR; native_skills_entry = 1
                next
            }
            if ((mode == "neutral" && key == "skills") || (mode == "metadata" && key == "metadata") ||
                (mode == "claude" && key == "tools")) {
                block = plain = 0
                if (seen++) { unreadable(NR); next }
                entry = NR
                print "entry", NR
                if (mode == "neutral") skills(value, NR)
                else if (mode == "metadata") metadata(value, NR)
                else { tools_line = NR; raw_tools = $0; tools(value, NR); block_tool_list = block_tools }
            } else {
                scan_yaml($0)
                if ((quote || flow) && single_line && !unsafe) unsafe = NR
            }
        }
        END {
            if (entry) finish_entry()
            if (mode == "neutral") explicit_finish()
            if (mode == "neutral" && bad_root)
                report(bad_root, "", "unsupported neutral frontmatter key for skills; use the plain top-level skills: key")
            if (mode == "neutral" && !seen) exit
            if (mode == "claude" && marked) print "marked"
            if (mode == "claude" && !active && !marked) exit
            if (opening != "absent" && (!closed || quote || flow || header_bad || (bad_root && mode != "neutral")))
                unreadable(header_bad ? header_bad : (bad_root ? bad_root : (NR ? NR : 1)))
            if (unsafe && mode != "metadata")
                report(unsafe, "", "unsafe multiline frontmatter for skill projection; indent unrelated continuations and keep projected fields on one line")
            if (mode == "metadata" && needs != "") print "needs", needs
            if (mode == "claude") claude_plan()
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
# Claude receives all declarations independent of shell availability.
as_projection() { # harness proj permissions
    local has_shell=false runnable="" list="" records kind field label msg id needs blockers active=""
    AS_FINDINGS=""; AS_OC=""; AS_NOTES=""; AS_CLAUDE=""; AS_CLAUDE_STATE=""; AS_TOOL_ACTION=""; AS_TOOL_LINE=""; AS_TOOL_EDIT=""
    [ -z "$AS_SKILLS" ] || active=1
    if [ "$1" = opencode ]; then
        [ -n "$active" ] || return 0
        if [ -z "$3" ]; then
            as_finding "$AS_DEF" "$AS_LINE" "$AS_FIRST" "OpenCode permissions are not renderer-owned; set the local tier's OpenCode permissions cell to opt into V2, or exclude OpenCode in harnesses:"
            return 0
        fi
        case " $3 " in *" shell "*) has_shell=true ;; esac
    else
        if [ -n "$active" ] && [ -z "$AS_PREFIX" ]; then
            as_finding "$AS_DEF" "$AS_LINE" "$AS_FIRST" "set 'Claude skill prefix:' to the plugin name in .prdkit/memory/agents.md"
            return 0
        fi
        if [ -n "$active" ]; then
            while read -r id needs; do
                [ -n "$id" ] || continue
                list="$list${list:+, }$AS_PREFIX:$id"
            done <<< "$AS_SKILLS"
            active="skills: [$list]"
        fi
    fi
    if [ -f "$2" ]; then
        records="$(as_records "$1" "$2" "$active")" || return 1
        if [ -z "$active" ]; then
            case $'\n'"$records"$'\n' in *$'\nmarked\n'*) ;; *) return 0 ;; esac
        fi
        blockers="$(at_native_projection_findings "$2" "$3")" || return 1
        while IFS= read -r msg; do
            [ -z "$msg" ] || as_finding "$AS_DEF" "${AS_LINE:-1}" "$AS_FIRST" "$msg"
        done <<EOF
$blockers
EOF
        while IFS=$'\037' read -r kind field label msg; do
            case "$kind" in
                state) AS_CLAUDE_STATE="$field $label $msg" ;;
                save) AS_CLAUDE="$AS_CLAUDE$field"$'\n' ;;
                restore) AS_CLAUDE="$field"$'\n' ;;
                tool) AS_TOOL_LINE="$field"; AS_TOOL_ACTION="$label"; AS_TOOL_EDIT="$msg" ;;
                error) as_finding "${2#"$AT_ROOT"/}" "$field" "$AS_FIRST" "$msg" ;;
            esac
        done <<EOF
$records
EOF
    elif [ "$1" = claude ] && [ -n "$active" ]; then
        AS_CLAUDE="$(printf '# prdkit-skill-projection: begin 1\n# prdkit-skill-projection: generated-skills %s\n# prdkit-skill-projection: end\n%s' "$active" "$active")"$'\n'
    fi
    [ "$1" = opencode ] && [ -n "$active" ] || return 0
    while read -r id needs; do
        [ -n "$id" ] || continue
        if $has_shell || [ -z "$needs" ]; then runnable="$runnable $id"
        else
            # shellcheck disable=SC2016 # Literal Markdown code spans.
            AS_NOTES="$AS_NOTES$(printf 'Skill `%s` needs a shell (%s), which you cannot run here. When the review package carries its output (`%s.json`, `%s.md`), read the facts there; otherwise list them as unverified.' "$id" "$needs" "$id" "$id")"$'\n'
        fi
    done <<EOF
$AS_SKILLS
EOF
    AS_OC="deny$runnable"
}
