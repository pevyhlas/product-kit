#!/usr/bin/env bash
# Focused spec grammar. Do not use this scanner for legacy navigation or budgets.

spec_focused() { # snapshot index|section selector expected-lines expected-bytes
    local range start=0 end=0
    range="$(spec_navigation "$1" range '' "$4" "$5")" || { printf '%s\n' "$range"; return 1; }
    if [ -n "$range" ]; then read -r start end <<< "$range"; fi
    LC_ALL=C PRDKIT_FOCUS_SELECTOR="$3" awk -v mode="$2" -v omit_start="$start" -v omit_end="$end" \
        -v expected_lines="$4" -v expected_bytes="$5" \
        "$SPEC_HEADING_AWK $SPEC_BULLET_ID_AWK $SPEC_PART_AWK $SPEC_RECORD_ROW_AWK"'
        function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
        function ltrim(s) { sub(/^[ \t]+/, "", s); return s }
        function norm(s) { s = trim(s); gsub(/[ \t]+/, " ", s); return tolower(s) }
        function indent(s, col,   i,c,n) {
            n = col
            for (i = 1; i <= length(s); i++) {
                c = substr(s,i,1)
                if (c == " ") n++
                else if (c == "\t") n += 4 - n % 4
                else break
            }
            lead = i - 1
            return n - col
        }
        function fail(message) { if (!problem) { problem = message; problem_line = line_no } }
        function alias(id,   key) {
            if (!section || mode != "section" || id == "") return
            key = norm(id)
            if (!((section,key) in aliases)) {
                aliases[section,key] = 1
                ids[section] = ids[section] (ids[section] == "" ? "" : ", ") id
            }
        }
        function tracking(s,   n,labels,label,i) {
            if (!sub(/^Tracking: +/, "", s)) return
            while (s != "") {
                if (!match(s, /^\[[A-Za-z0-9][A-Za-z0-9._\/-]*\]\[[Nn][Aa][Vv]-[A-Za-z0-9_-]+\]/)) return
                label = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
                labels[++n] = substr(label, 2, index(label, "]") - 2)
                if (s != "" && !sub(/^ +/, "", s)) return
            }
            for (i = 1; i <= n; i++) alias(labels[i])
        }
        # GFM protects pipes (also in inline code) with a preceding backslash.
        # Outer pipes are optional and not counted as cells.
        function cells(s, field,   n,cell,chunk,outer) {
            s = trim(s); sub(/^\|/, "", s); n = 1
            while (match(s, /\|/)) {
                chunk = substr(s,1,RSTART-1); s = substr(s,RSTART+1)
                if (sub(/\\$/, "", chunk)) cell = cell chunk "|"
                else {
                    field[n++] = trim(cell chunk); cell = ""
                    if (s == "") outer = 1
                }
            }
            if (outer) return n - 1
            field[n] = trim(cell s); return n
        }
        function table_header(s, base,   next_line,w,f,d,n,m,i) {
            if (line_no == NR) return 0
            next_line = raw[line_no+1]; w = indent(next_line, 0)
            if (w < base || w - base >= 4) return 0
            next_line = ltrim(next_line)
            if (next_line ~ /^-+[ \t]*$/) return 0 # This is a Setext underline, not a delimiter.
            m = cells(next_line, d)
            for (i = 1; i <= m; i++) if (d[i] !~ /^:?-+:?$/) return 0
            n = cells(s, f)
            if (m != n) return 0
            parts = tolower(f[1]) == "part"
            return 1
        }
        function table_row(s,   f,id,row,r) {
            cells(s, f)
            if (parts) {
                id = f[1]; sub(/[ \t].*/, "", id)
                if (spec_part_id(id)) alias(id)
            }
            if (spec_record_row(f[1], row) != "") return
            r = row["reason"]
            if (row["type"] ~ /^(HOLD|WAIVER)$/ && r ~ /^ref=/ &&
                (r !~ /^ref=specs\/authority\.md#[A-Za-z0-9][A-Za-z0-9._-]*@[0-9a-f]+$/ ||
                 length(r) - index(r, "@") != 12)) return
            alias(row["name"])
        }
        function heading(depth,   d,word) {
            for (d = 6; d >= depth; d--) if (d in open) {
                last_line[open[d]] = line_no - 1; delete open[d]
            }
            for (d = depth - 1; d > 0 && !(d in open); d--) {}
            section++
            first[section] = line_no; levels[section] = depth; titles[section] = heading_title
            tree[section] = d ? tree[open[d]] "  " : ""
            open[depth] = section
            split(heading_title,word," "); sub(/:$/, "", word[1])
            if (word[1] ~ /^[A-Za-z][A-Za-z0-9._-]*-[0-9]+$/ || spec_part_id(word[1])) alias(word[1])
        }
        function thematic(s) {
            gsub(/[ \t]/, "", s); return s ~ /^(---+|\*\*\*+|___+)$/
        }
        function fence_run(s) {
            if (!match(s, /^```+|^~~~+/)) return 0
            return RLENGTH
        }
        function list_mark(s,   tenth) {
            if (match(s, /^[-+*]([ \t]|$)/)) return 1
            tenth = substr(s,10,1)
            return (tenth == "" || !index("0123456789", tenth)) && match(s, /^[0-9]+[.)]([ \t]|$)/)
        }
        function html_block(s) {
            return s ~ /^<[A-Za-z!?\/]/ &&
                s !~ /^<[A-Za-z][A-Za-z0-9+.-]*:[^<> \t]+>|^<[^<> \t@]+@[^<> \t@]+>/
        }
        function interrupts(s) {
            return spec_heading(s) || fence_run(s) || thematic(s) || list_mark(s) || s ~ /^>/ || html_block(s)
        }
        # A link reference at a block boundary can have a continuation destination
        # or title. A reference-like citation cannot interrupt a prose paragraph.
        function reference_title(s) {
            return s ~ /^("([^"\\]|\\.)*"|\047([^\047\\]|\\.)*\047|\(([^()\\]|\\.)*\))[ \t]*$/
        }
        function naked_destination(s,   i,c,depth,following) {
            for (i = 1; i <= length(s); i++) {
                c = substr(s,i,1)
                following = substr(s,i+1,1)
                if (c == "\\" && following != "" && index("!\"#$%&\047()*+,-./:;<=>?@[\\]^_`{|}~", following)) i++
                else if (c == "(") depth++
                else if (c == ")" && --depth < 0) return 0
            }
            return depth == 0
        }
        function reference(s, base,   rest,w,title,at,next_text,dest,i,closed) {
            if (!match(s, /^\[([^][\\]|\\.)+\]:/)) return 0
            rest = trim(substr(s, RLENGTH+1)); at = line_no
            if (rest == "" && at < NR) {
                next_text = raw[++at]; w = indent(next_text,0)
                if (w < base) return 0
                rest = ltrim(next_text)
                if (w - base < 4 && (interrupts(rest) || rest ~ /^-+[ \t]*$/)) return 0
            }
            if (!match(rest, /^(<([^<>\\ \t]|\\.)*>|[^<> \t]+)([ \t]|$)/)) return 0
            dest = trim(substr(rest,1,RLENGTH))
            title = trim(substr(rest,RLENGTH+1))
            if (substr(dest,1,1) != "<" && !naked_destination(dest)) return 0
            if (title == "" && at < NR) {
                next_text = raw[at+1]; w = indent(next_text,0)
                next_text = ltrim(next_text)
                if (w >= base && next_text ~ /^["\047(]/) { title = next_text; at++ }
            }
            if (title != "") {
                if (title !~ /^["\047(]/) return 0
                closed = reference_title(title)
                for (i = at+1; i <= NR && !closed; i++) {
                    next_text = raw[i]; w = indent(next_text,0)
                    next_text = ltrim(next_text)
                    if (w < base || next_text == "" || (w - base < 4 && interrupts(next_text))) break
                    title = title " " next_text
                    if (reference_title(title)) { at = i; closed = 1 }
                }
                if (!closed) return 0
            }
            line_no = at
            return 1
        }
        function scan(s,   col,t,rel,base,k,depth,blank,mark,marker,pad,body,previous_lists) {
            col = indent(s,0); t = ltrim(s); blank = t == ""
            if (fence != "") {
                if (blank || col >= fence_base) {
                    k = fence_run(t)
                    if (col - fence_base < 4 && k >= fence_size && substr(t,1,1) == fence &&
                        t ~ /^(`+|~+)[ \t]*$/) fence = ""
                    return
                }
                fence = "" # Dedenting ends a list container and its literal block.
            }
            if (comment) {
                if (blank || col >= comment_base) { if (index(t,"-->")) comment = 0; return }
                comment = 0
            }
            if (blank) { paragraph = table = 0; return }
            previous_lists = lists
            while (lists && col < list_col[lists]) lists--
            base = lists ? list_col[lists] : 0
            if (base != table_base) table = 0
            rel = col - base
            while (1) {
                if (rel >= 4) {
                    if (!paragraph || paragraph_base != base) fail("Indented code blocks are not supported.")
                    else if (lists) tracking(t)
                    return
                }
                if (paragraph && base == paragraph_base && !table && t ~ /^(=+|-+)[ \t]*$/) {
                    fail("Setext (underlined) headings are not supported."); return
                }
                if (thematic(t)) {
                    if (paragraph && base == paragraph_base) fail("Thematic breaks must start a block.")
                    paragraph = table = 0; return
                }
                depth = spec_heading(t)
                if (depth) {
                    if (lists) fail("Headings inside lists are not supported.")
                    else heading(depth)
                    paragraph = table = 0; return
                }
                if (t ~ /^<!--/) {
                    if (!index(t,"-->")) { comment = 1; comment_base = base }
                    if (!lists && s == "<!-- prdkit:navigation:v1 begin -->") footer_start = line_no
                    if (!lists && s == "<!-- prdkit:navigation:v1 end -->") footer_end = line_no
                    paragraph = table = 0; return
                }
                k = fence_run(t)
                if (k && (substr(t,1,1) == "~" || !index(substr(t,k+1),"`"))) {
                    fence = substr(t,1,1); fence_size = k; fence_base = base
                    paragraph = table = 0; return
                }
                if (t ~ /^>/) { fail("Block quotes are not supported."); return }
                if (html_block(t)) {
                    fail("HTML blocks other than comments are not supported."); return
                }
                if (!list_mark(t)) break
                marker = substr(t,1,RLENGTH); sub(/[ \t]$/, "", marker); mark = length(marker)
                body = t; sub(/^([-+*]|[0-9]+[.)])/, "", body); pad = indent(body,col+mark)
                if (paragraph && base == paragraph_base &&
                    ((length(marker) > 1 && marker !~ /^1[.)]$/) || lead == length(body))) break
                # Keep the source ID convention (bold unordered item), not arbitrary citations.
                alias(spec_bullet_id(t))
                if (titles[section] == "Retired") alias(spec_retired_part(t))
                if (lead == length(body)) {
                    list_col[++lists] = col + mark + 1; paragraph = table = 0; return
                }
                if (pad > 4) { fail("Indented code blocks are not supported."); return }
                col += mark + pad
                base = list_col[++lists] = col; rel = 0
                t = ltrim(body); paragraph = table = previous_lists = 0
            }
            if (table) { table_row(t); return }
            if (!paragraph && reference(t,base)) return
            if (table_header(t,base)) {
                table = 1; table_base = base; paragraph = 0; line_no++; return
            }
            tracking(t)
            # Plain unindented text may lazily continue the current list paragraph.
            if (paragraph && previous_lists > lists) {
                lists = previous_lists; base = list_col[lists]
            }
            paragraph = 1; paragraph_base = base
        }
        function label(n,   h) {
            for (h = ""; length(h) < levels[n]; h = h "#") {}
            return first[n] ": " tree[n] h " " (titles[n] == "" ? "(untitled)" : titles[n])
        }
        function index_sections(   n,count) {
            if (!section) print "No ATX headings."
            for (n = 1; n <= section; n++) {
                count = prefix[last_line[n]] - prefix[first[n]-1]
                printf "%s (%d reading line%s)\n", label(n), count, (count == 1 ? "" : "s")
            }
        }
        function select_section(   selector,key,n,found,count,i) {
            selector = ENVIRON["PRDKIT_FOCUS_SELECTOR"]; key = norm(selector)
            for (n = 1; n <= section; n++)
                if (key != "" && ("x" norm(titles[n]) == "x" key || (n,key) in aliases)) {
                    matched[n] = 1; found = n; count++
                }
            if (count != 1) {
                if (key == "") print "Missing section selector. Available candidates:"
                else printf "%s section selector: \"%s\". Available candidates:\n", (count ? "Ambiguous" : "No match for"), selector
                if (!section) print "  (no ATX headings)"
                for (n = 1; n <= section; n++) if (!count || matched[n])
                    print "  " label(n) (ids[n] == "" ? "" : " [IDs: " ids[n] "]")
                print "Use a unique heading or ID, or --raw to inspect the source."
                exit 10
            }
            for (i = first[found]; i <= last_line[found]; i++) if (visible(i)) printf "%d: %s\n", i, raw[i]
        }
        function visible(i) {
            return !omit_start || omit_start != footer_start || omit_end != footer_end || i < omit_start || i > omit_end
        }
        { raw[NR] = $0; bytes += length($0) + 1 }
        END {
            if (NR != expected_lines || bytes != expected_bytes) {
                printf "Incomplete focused input: expected %d lines/%d bytes, checked %d lines/%d bytes\n",
                    expected_lines, expected_bytes, NR, bytes
                exit 1
            }
            for (line_no = 1; line_no <= NR && !problem; line_no++) scan(raw[line_no])
            if (problem) { printf "%d: %s Please use --raw to inspect the source.\n", problem_line, problem; exit 10 }
            for (d in open) last_line[open[d]] = NR
            if (mode == "index") {
                for (i = 1; i <= NR; i++) {
                    s = raw[i]; gsub(/[\200-\277]/, "", s)
                    weight = length(s) > 100 ? int((length(s) + 99) / 100) : 1
                    prefix[i] = prefix[i-1] + (visible(i) ? weight : 0)
                }
                index_sections()
            } else select_section()
        }
    ' "$1"
}
