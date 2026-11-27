#!/usr/bin/env bash
# Scan project-owned files for stock slots, not consumer-editable templates.
# The maintainer generator supplies the narrow anchors for common tokens.

template_residue_rows() ( # root, followed by the already discovered spec and change paths
    local catalog
    catalog="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/template-residue.tsv" || return 1
    cd "$1" || return 1
    shift
    local path seen_path files=()
    for path in .prdkit/memory/constitution.md .prdkit/memory/agents.md .prdkit/memory/config.md \
                .prdkit/history/archive.md .prdkit/agents/*.md specs/inbox.md specs/records.md specs/authority.md \
                specs/observed.md specs/observed/*.md "$@"; do
        [ -f "$path" ] || continue
        for seen_path in ${files[@]+"${files[@]}"}; do [ "$seen_path" != "$path" ] || continue 2; done
        files+=("$path")
    done
    [ "${#files[@]}" -gt 0 ] || return 0
    # Pass the catalog as a filename operand (not -v, which interprets backslashes).
    # shellcheck disable=SC2016 # awk uses its own $0
    LC_ALL=C awk -F '\t' -v marker="$PRDKIT_UNCONFIRMED_DEFAULT" -v stages="$SPEC_STAGE_DEFAULT" '
        BEGIN {
            # The combined form uses the same slot contexts as the split files.
            combined["problem and users"] = "product lifecycle"
            combined["journeys"] = "product journey"
            combined["requirements and qualities"] = "requirements qualities"
            combined["constraints and non-goals"] = "constraints non-goals"
            combined["shape and parts"] = "architecture architecture-topics part design"
            combined["decisions and why it works"] = "decision architecture-topics architecture"
            combined["left open"] = "requirements architecture part"
            ignored = sprintf("%c", 28)
            destination = sprintf("%c", 29)
            punctuation = "!\"#$%&\047()*+,-./:;<=>?@[\\]^_`{|}~"
            angle = "<([^<>[:cntrl:]]|<[^<>[:cntrl:]]*>)+>"
            candidate = "[<" destination "]([^<>[:cntrl:]]|<[^<>[:cntrl:]]*>)+>"
            attribute = "[[:space:]]+[A-Za-z_:][A-Za-z0-9_.:-]*" \
                "([[:space:]]*=[[:space:]]*(\"[^\"]*\"|\047[^\047]*\047|[^[:space:]\"<>=`\047]+))?"
            html_tag = "^<[A-Za-z][A-Za-z0-9:_-]*(" attribute ")*[[:space:]]*/?>"
            n = split(stages, defaults, ">")
            for (i = 1; i <= n; i++) stage_name[defaults[i]] = 1
            stage_name["general availability"] = 1
        }
        FILENAME == ARGV[1] {
            if ($1 == "# escaped-stock") { escaped_stock[$2] = 1; next }
            if ($0 ~ /^#/) next
            if (NF < 6 || (NF - 2) % 4 || $1 == "" || $2 == "" || (($1, $2) in size)) {
                invalid = 1; exit 1
            }
            for (col = 3; col <= NF; col += 4) {
                i = ++size[$1,$2]
                kind[$1,$2,i] = $col; arg[$1,$2,i] = $(col + 1)
                left[$1,$2,i] = $(col + 2); right[$1,$2,i] = $(col + 3)
                if ($col == "plain") plain[$1,++plain_count[$1]] = $2
                if ($col == "prose" && length($2) > max_slot) max_slot = length($2)
                if (index($2, "`")) keeps_ticks[$2] = 1
            }
            stock[$2] = 1
            loaded++
            next
        }
        function family(path,   components) {
            if (path == ".prdkit/memory/constitution.md") return "constitution"
            if (path == ".prdkit/memory/agents.md") return "agents"
            if (path == ".prdkit/memory/config.md") return "config"
            if (path == ".prdkit/history/archive.md") return "archive"
            if (path ~ /^\.prdkit\/agents\//) return "agent-definition"
            if (path ~ /^specs\/(inbox|records|authority)\.md$/) return substr(path, 7, length(path) - 9)
            if (path ~ /^specs\/observed(\.md|\/)/) return "observed"
            if (path == "specs/SPEC.md") return "spec"
            if (path ~ /^specs\/(product\.md$|product\/users(\.md$|\/))/) return "product"
            if (path == "specs/architecture.md") return "architecture"
            if (path == "specs/design.md") return "design"
            if (path ~ /^specs\/changes\//) return "change"
            if (path ~ /^specs\/parts\//) return "part"
            if (path ~ /^specs\/(decisions\/|architecture\/decisions(\.md$|\/))/) return "decision"
            if (path ~ /^specs\/architecture\//) return "architecture-topics"
            if (path ~ /^specs\/product\/journeys\//) return "journey"
            if (path ~ /^specs\/product\/(lifecycle|requirements|qualities|constraints|non-goals)(\.md$|\/)/) {
                split(path, components, /[\/.]/)
                return components[3]
            }
            return ""
        }
        function normalize(s) {
            gsub(/[[:blank:]]+/, " ", s)
            sub(/^ /, "", s); sub(/ $/, "", s)
            return s
        }
        function report_slot(token, nr) {
            printf "P\037%s:%d (%s)\n", file, nr, token
        }
        function heading_fits(before, slot_left, template) {
            if (before ~ slot_left) return 1
            # A split-file heading can move down in the combined form.
            if (group != "spec" || template == "spec" || before !~ /^###/) return 0
            while (before ~ /^##/) {
                before = substr(before, 2)
                if (before ~ slot_left) return 1
            }
            return 0
        }
        # Return true as soon as any active template authorizes this occurrence.
        # An occurrence cannot be counted twice by two contexts or templates.
        function accepts(names, token, before, after, surface, cell, in_link,   groups,n,g,k,i,mode,selector,parts,reason) {
            n = split(names, groups, " ")
            for (g = 1; g <= n; g++) {
                k = groups[g]
                for (i = 1; i <= size[k,token]; i++) {
                    mode = kind[k,token,i]; selector = arg[k,token,i]
                    # Only generated link anchors can authorize a destination slot.
                    if (in_link && mode != "table" && mode != "stage" && mode != "journey-link") continue
                    if (mode == "prose") {
                        if (surface ~ /^body/) return 1
                        continue
                    }
                    if (surface == "body-wrap") continue
                    if (mode == "table") {
                        if (surface != "body-cell") continue
                        split(selector, parts, ":")
                        if (!(parts[1] in headers) || cell != parts[2]) continue
                    } else if (mode == "stage") {
                        if (!stage_table) continue
                        if (selector == "header") {
                            if (surface != "body-header" || cell == "area") continue
                        } else if (surface != "body-cell") continue
                        else if (selector == "area" ? cell != "area" : !(cell in stage_columns)) continue
                    } else if (mode == "diagram") {
                        if (surface != "diagram" || selector != diagram) continue
                    } else if (mode == "journey-link") {
                        if (surface != "body" || section != "journeys") continue
                    } else if (mode ~ /^record-/) {
                        if (surface != "body" || index(before, selector " ") != 1) continue
                        reason = index(before, " — ")
                        if (mode == "record-field" ? reason != 0 : reason != length(before) - length(" — ") + 1)
                            continue
                    } else if (mode == "line") {
                        if (surface != "body" && surface != "commands") continue
                    } else if (mode != "plain" || surface != "plain") continue
                    if (heading_fits(before, left[k,token,i], k) && after ~ right[k,token,i]) return 1
                }
            }
            return 0
        }
        function scan(names, line, tail, nr, continuation, surface, cell,   rest,offset,at,end,len,token,before,after,in_link) {
            len = length(line); rest = line tail
            while (match(rest, candidate)) {
                at = offset + RSTART
                if (at > len) break
                end = at + RLENGTH - 1
                token = substr(rest, RSTART, RLENGTH)
                in_link = substr(token, 1, 1) == destination
                if (in_link) sub("^" destination, "<", token)
                before = substr(line, 1, at - 1); after = substr(line, end + 1)
                # A cross-line match can only be a distinctive prose token.
                if (accepts(names, token, before, after, (end > len ? "body-wrap" : surface), cell, in_link)) {
                    report_slot(token, continuation ? continuation : nr)
                } else {
                    # An unknown outer angle expression may contain a stock token.
                    end = at
                }
                rest = substr(rest, end - offset + 1); offset = end
            }
        }
        # Code spans use the next run of exactly the same length. Return the
        # consumed length through that run (or zero for a literal opener).
        function code_end(rest, ticks,   offset,run) {
            while (match(rest, /`+/)) {
                run = RLENGTH; offset += RSTART + run - 1
                if (run == ticks) return offset
                rest = substr(rest, RSTART + run)
            }
            return 0
        }
        function masked(text) {
            gsub(/[^\n]+/, ignored, text)
            return text
        }
        # Consume inline syntax in source order, within one block or cell.
        # An opener owns its matched payload; nothing inside is scanned again.
        function mask_inline(text,   out,at,n,rest,tmp,token,ch,depth,link,span,tag) {
            while (match(text, /\\[[:punct:]]|`+|<!--|[][]|</)) {
                at = RSTART
                n = RLENGTH
                out = out substr(text, 1, at - 1); text = substr(text, at)
                ch = substr(text, 1, 1)
                if (n == 2 && substr(text, 1, n) == "\\<") {
                    # Only prompts shipped with this escape are still stock.
                    tmp = substr(text, 2); gsub(/\n/, " ", tmp)
                    out = out (match(tmp, angle) && RSTART == 1 &&
                        normalize(substr(tmp, 1, RLENGTH)) in escaped_stock ? "<" : ignored)
                    text = substr(text, n + 1); continue
                } else if (ch == "`") {
                    rest = substr(text, n + 1)
                    if ((at = code_end(rest, n))) {
                        out = out masked(substr(text, 1, n + at))
                        text = substr(rest, at + 1); continue
                    }
                } else if (substr(text, 1, n) == "<!--") {
                    rest = substr(text, 5); at = index(rest, "-->")
                    if (at) {
                        n = at + 6
                        out = out masked(substr(text, 1, n)); text = substr(text, n + 1); continue
                    }
                } else if (ch == "[") depth++
                else if (ch == "]" && depth) {
                    depth--
                    if (substr(text, 2, 1) == "(" && (at = link_end(substr(text, 3), link))) {
                        span = link[1]
                        # Keep the destination visible only to explicit stock link anchors.
                        gsub(/</, destination, span)
                        out = out "](" span (link[2] == "" ? "" : masked(link[2])) ")"
                        text = substr(text, at + 3); continue
                    }
                } else if (ch == "<") {
                    if ((tag = markup_prefix(text)) != "") {
                        out = out masked(tag); text = substr(text, length(tag) + 1); continue
                    }
                    # A stock prompt can itself contain literal Markdown code.
                    tmp = text; gsub(/\n/, " ", tmp)
                    if (match(tmp, angle) && RSTART == 1) {
                        token = normalize(substr(tmp, 1, RLENGTH))
                        if (token in keeps_ticks) n = RLENGTH
                    }
                }
                out = out substr(text, 1, n); text = substr(text, n + 1)
            }
            return out text
        }
        function escaped(s, i) {
            return substr(s, i, 1) == "\\" && i < length(s) && index(punctuation, substr(s, i + 1, 1))
        }
        function quoted_end(s, i, delimiter,   ch) {
            for (i++; i <= length(s); i++) {
                ch = substr(s, i, 1)
                if (escaped(s, i)) i++
                else if (ch == delimiter) return i
                else if ((delimiter == ">" && (ch == "<" || ch == "\n")) || (delimiter == ")" && ch == "(")) return 0
            }
            return 0
        }
        # Return the first character after the bare or angle-delimited destination.
        function destination_end(s, i,   ch,depth,at) {
            if (substr(s, i, 1) == "<") {
                at = quoted_end(s, i, ">")
                return at ? at + 1 : 0
            }
            for (; i <= length(s); i++) {
                ch = substr(s, i, 1)
                if (escaped(s, i)) i++
                else if (ch == "(") depth++
                else if (ch == ")") { if (!depth) return i; depth-- }
                else if (index(" \t\n\r\f\v", ch)) break
            }
            return depth ? 0 : i
        }
        # After a destination, consume an optional whitespace-separated title.
        # An inline link must end at ), a reference definition at end of line.
        function link_tail(s, i, terminal,   gap,ch,at) {
            match(substr(s, i), /^[[:space:]]*/); gap = RLENGTH
            i += gap; ch = substr(s, i, 1)
            if (ch == terminal) return i
            if (!gap || ch == "" || !index("\"\047(", ch)) return 0
            at = quoted_end(s, i, (ch == "(" ? ")" : ch))
            if (!at) return 0
            match(substr(s, at + 1), /^[[:space:]]*/)
            i = at + RLENGTH + 1
            return substr(s, i, 1) == terminal ? i : 0
        }
        function link_end(s, parts,   start,stop,end) {
            match(s, /^[[:space:]]*/); start = RLENGTH + 1
            if (!(stop = destination_end(s, start)) || !(end = link_tail(s, stop, ")"))) return 0
            parts[1] = substr(s, 1, stop - 1)
            parts[2] = substr(s, stop, end - stop)
            return end
        }
        function reference_definition(s,   start,stop) {
            if (!match(s, /^ ? ? ?\[(\\.|[^][\\])+\]:[[:blank:]]*/)) return 0
            start = RLENGTH + 1
            stop = destination_end(s, start)
            return stop > start && link_tail(s, stop, "")
        }
        function markup_prefix(s,   n,tag,name,flat) {
            if (match(s, /^<([A-Za-z][A-Za-z0-9+.-]+:[^<>[:space:][:cntrl:]]*|[A-Za-z0-9.!#$%&*+\/=?^_`{|}~-]+@[A-Za-z0-9][A-Za-z0-9.-]*)>/) ||
                match(s, /^<\/[A-Za-z][A-Za-z0-9:_-]*[[:space:]]*>/)) return substr(s, 1, RLENGTH)
            if (!match(s, html_tag)) return ""
            n = RLENGTH; tag = substr(s, 1, n)
            if (tag ~ /\/>$/) return tag
            if (tag ~ /^<[A-Za-z][A-Za-z0-9:_-]*>$/) {
                name = tolower(substr(tag, 2, n - 2))
                s = tolower(substr(s, n + 1))
                # The name is restricted to literal ASCII tag-name characters.
                if (s ~ ("^[[:space:]]*</" name "[[:space:]]*>")) return tag
                return ""
            }
            # Stock prose prompts such as <what must be true> also parse as
            # HTML with boolean attributes. Preserve those exact prompts.
            flat = tag; gsub(/\n/, " ", flat)
            return (normalize(flat) in stock) ? "" : tag
        }
        function split_cells(line, cells,   pipe,n,k) {
            # GFM consumes the backslash immediately before a pipe, regardless
            # of preceding backslashes. Earlier backslashes stay in the cell.
            gsub(/\\\|/, ignored, line)
            pipe = index(line, "|")
            sub(/^ *\|/, "", line); sub(/\| *$/, "", line)
            n = split(line, cells, /\|/)
            for (k = 1; k <= n; k++) gsub(ignored, "|", cells[k])
            cells[0] = pipe
            return n
        }
        function table_ahead(line, row, base,   divider,k,n,parts) {
            if (row >= last || line !~ /\|/ || line ~ /^    /) return 0
            divider = src[row + 1]
            if (indent(divider) < base) return 0
            divider = relative(divider, base)
            if (divider !~ /\|/ || divider ~ /^    /) return 0
            n = split_cells(normalize(divider), parts)
            if (!parts[0]) return 0
            for (k = 1; k <= n; k++)
                if (parts[k] !~ /^ *:?-+:? *$/) return 0
            return (split_cells(line, parts) == n && parts[0]) ? n : 0
        }
        function start_table(parts, n,   k,name) {
            for (k = 1; k <= n; k++) {
                parts[k] = normalize(mask_inline(parts[k]))
                name = tolower(parts[k])
                columns[k] = name; headers[name] = 1
                if (name ~ / \(now\)$/ || name ~ /^<(now|next|later) stage>$/ ||
                    (section == "journeys" && name in stage_name)) stage_columns[name] = 1
            }
        }
        function end_table(   key) {
            for (key in headers) delete headers[key]
            for (key in stage_columns) delete stage_columns[key]
            stage_table = 0
        }
        function scan_plain(names, line, nr,   groups,n,g,k,i,token,at) {
            n = split(names, groups, " ")
            for (g = 1; g <= n; g++) {
                k = groups[g]
                for (i = 1; i <= plain_count[k]; i++) {
                    token = plain[k,i]; at = index(line, token)
                    if (at && accepts(k, token, substr(line, 1, at - 1), substr(line, at + length(token)), "plain"))
                        report_slot(token, nr)
                }
            }
        }
        function scan_accounts(line, nr,   key,value,items,i,n) {
            key = line; sub(/:.*/, "", key)
            if (key !~ /^- review-(publishers|owner)$/) return
            value = substr(line, length(key) + 2)
            n = split(value, items, ",")
            for (i = 1; i <= n; i++) {
                # Each comma-delimited account is a value of the same stock field.
                # Allow the other supported publisher prefix without matching prose.
                value = normalize(items[i])
                if (key == "- review-publishers") sub(/^user:/, "bot:", value)
                scan("config", key ": " value, "", nr, 0, "body")
            }
        }
        function set_section(text) {
            section = ""
            if (text ~ /^## /) {
                section = tolower(substr(text, 4))
                sub(/ #+$/, "", section)
            }
            group_names = group
            if (group == "spec" && combined[section] != "") group_names = group " " combined[section]
            if (group == "constitution" && section == "commands") group_names = group " " group "@commands"
        }
        function body(text, first, item, heading,   a,n,i,j,nr,tail,value) {
            n = split(mask_inline(text), a, "\n")
            for (i = 1; i <= n; i++) a[i] = normalize(a[i])
            if (heading && a[1] ~ /^##?( |$)/) set_section(a[1])
            for (i = 1; i <= n; i++) {
                nr = first + i - 1
                if (group == "config") {
                    if (section == "configuration") scan_accounts(a[i], nr)
                    continue
                }
                if (group == "constitution") {
                    value = a[i]
                    if (sub(/^[-*[:space:]]*[Rr]igor\**:\**[[:space:]]*/, "", value) && index(value, marker))
                        printf "D\037%s:%d (Rigor)\n", file, nr
                }
                tail = ""
                if (index(a[i], "<"))
                    for (j = i + 1; j <= n && length(tail) < max_slot; j++) tail = tail " " a[j]
                scan(group_names, a[i], tail, nr, item, "body")
                scan_plain(group_names, a[i], nr)
            }
        }
        # Resume at the first exposed text after a comment that crossed a
        # block boundary. Comment contents cannot alter the block structure.
        function comment_tail(text,   at) {
            if (!(at = index(text, "-->"))) return ignored
            comment = 0
            return ignored substr(text, at + 3)
        }
        function table(first, base, text, width,   values,counts,i,j,k,n,parts) {
            split_cells(text, parts)
            start_table(parts, width)
            counts[first] = width
            for (k = 1; k <= width; k++) values[first,k] = parts[k]
            if ("area" in headers) {
                for (k in stage_columns) { stage_table = 1; break }
            }
            for (i = first + 2; i <= last; i++) {
                text = src[i]
                if (indent(text) < base) break
                text = relative(text, base)
                if (text !~ /[^[:blank:]]/ || text ~ /^    / || interrupts(text) || reference_definition(text)) break
                # GFM pads short rows (including one cell without pipes) and
                # discards surplus cells. Missing cells have nothing to scan.
                n = split_cells(text, parts)
                # Let the document scanner handle HTML at a short-row boundary.
                if (!parts[0] && text ~ /^ ? ? ?</) break
                if (n > width) n = width
                counts[i] = n
                for (k = 1; k <= n; k++) {
                    values[i,k] = normalize(mask_inline(parts[k]))
                    # A journey link identifies a custom stage column.
                    if ("area" in headers && (section == "journeys" || stage_table) &&
                        columns[k] != "area" && values[i,k] ~ /\]\(product\/journeys\//) {
                        stage_columns[columns[k]] = 1
                        stage_table = 1
                    }
                }
            }
            for (j = first; j < i; j++) {
                for (k = 1; k <= counts[j]; k++)
                    scan(group_names, values[j,k], "", j, 0,
                        (j == first ? "body-header" : "body-cell"), columns[k])
            }
            end_table()
            return i
        }
        function indent(text) { match(text, /^ */); return RLENGTH }
        function expand_indent(text, start,   pad,i,ch) {
            for (i = 1; i <= length(text); i++) {
                ch = substr(text, i, 1)
                if (ch == " ") pad = pad " "
                else if (ch == "\t") pad = pad substr("    ", 1, 4 - (start + length(pad)) % 4)
                else break
            }
            return pad substr(text, i)
        }
        function relative(text, base) {
            return (indent(text) >= base ? substr(text, base + 1) : text)
        }
        function fence_run(text,   mark) {
            if (!match(text, /^ ? ? ?(```+|~~~+)/)) return ""
            mark = normalize(substr(text, 1, RLENGTH))
            if (substr(mark, 1, 1) == "`" && index(substr(text, RLENGTH + 1), "`")) return ""
            return mark
        }
        function list_prefix(text,   prefix) {
            if (!match(text, /^ ? ? ?([-*+]|[0-9]+[.)])([[:blank:]]+|$)/)) return ""
            prefix = substr(text, 1, RLENGTH)
            if (match(prefix, /[0-9]+/) && RLENGTH > 9) return ""
            return prefix
        }
        function thematic(text) {
            return text ~ /^ ? ? ?((- *)- *-[- ]*|(\* *)\* *\*[* ]*|(_ *)_ *_[_ ]*)$/
        }
        function atx(text) {
            return text ~ /^ ? ? ?##?#?#?#?#?([[:blank:]]|$)/
        }
        function comment_prefix(text) {
            return match(text, /^ ? ? ?<!--/) ? RLENGTH : 0
        }
        function interrupts(text, in_paragraph,   prefix) {
            if (atx(text) || text ~ /^ ? ? ?>/ || fence_run(text) != "" ||
                thematic(text) || comment_prefix(text)) return 1
            prefix = list_prefix(text)
            if (!in_paragraph || prefix == "") return prefix != ""
            return (length(prefix) < length(text) && prefix ~ /^ *([-*+]|0*1[.)])/)
        }
        function paragraph(first, base, text, item,   i,line) {
            for (i = first + 1; i <= last; i++) {
                line = relative(src[i], base)
                # A setext underline ends the heading; a backtick in its text
                # cannot pair with a run in the paragraph that follows.
                if (indent(src[i]) >= base && line ~ /^ ? ? ?(=+|-+) *$/) { i++; break }
                if (line ~ /^[[:blank:]]*$/ || interrupts(line, !(item && indent(src[i]) < base)) ||
                    table_ahead(line, i, base)) break
                text = text "\n" line
            }
            body(text, first, item, 0)
            return i
        }
        function fenced(first, base, mark, info,   names,parts,n,i,j,line,rows,text) {
            names = ""
            if (info == "mermaid") {
                n = split((group == "spec" ? combined[section] : group), parts, " ")
                for (i = 1; i <= n; i++) names = names (i > 1 ? " " : "") parts[i] "@mermaid"
            } else if (group == "constitution" && section == "commands") {
                names = group "@commands"
            }
            for (i = first + 1; i <= last; i++) {
                line = src[i]
                if (indent(line) < base && line ~ /[^[:blank:]]/) break
                line = relative(line, base)
                if (line ~ /^ ? ? ?(`+|~+)[[:blank:]]*$/ && index(normalize(line), mark) == 1) {
                    i++; break
                }
                if (names == "") continue
                if (info != "mermaid") scan(names, normalize(line), "", i, 0, "commands")
                else text = text (i > first + 1 ? "\n" : "") (line ~ /^ *%%/ ? "" : line)
            }
            if (info == "mermaid" && names != "") {
                n = split(mask_inline(text), rows, "\n")
                diagram = ""
                for (j = 1; j <= n; j++) {
                    line = normalize(rows[j])
                    if (line ~ /^(flowchart |sequenceDiagram$)/) { diagram = line; sub(/ .*/, "", diagram) }
                    else scan(names, line, "", first + j, 0, "diagram")
                }
            }
            return i
        }
        function document(   i,text,line,lead,base,depth,indents,items,item,marker_len,prefix,pad,mark,columns_n,quote,n) {
            group_names = group; section = ""; comment = 0
            i = 1
            if (group == "agent-definition" && src[i] == "---") {
                for (i++; i <= last && src[i] != "---"; i++)
                    scan_plain(group "@frontmatter", normalize(src[i]), i)
                i++
            }
            while (i <= last) {
                line = src[i]
                if (comment) {
                    line = comment_tail(line)
                    if (!comment) body(line, i, 0, 0)
                    i++
                    continue
                }
                lead = indent(line)
                while (depth && lead < indents[depth] && line ~ /[^[:blank:]]/) depth--
                base = (depth ? indents[depth] : 0)
                text = relative(line, base)
                if (quote && text ~ /[^[:blank:]]/ &&
                    !interrupts(text, 1) && !table_ahead(text, i, base)) { i++; continue }
                quote = 0
                if (text !~ /[^[:blank:]]/ || thematic(text)) { i++; continue }
                prefix = list_prefix(text)
                if (prefix != "") {
                    marker_len = length(prefix)
                    pad = prefix; sub(/^.*[^[:blank:]]/, "", pad)
                    text = substr(text, marker_len + 1)
                    prefix = substr(prefix, 1, marker_len - length(pad))
                    pad = expand_indent(pad, base + length(prefix))
                    if (length(pad) > 4) {
                        text = substr(pad, 2) text
                        pad = " "
                    }
                    prefix = prefix pad
                    base += length(prefix) + (pad == "" ? 1 : 0)
                    indents[++depth] = base; items[depth] = i
                }
                item = (depth ? items[depth] : 0)
                if (text ~ /^    / || text !~ /[^[:blank:]]/ || reference_definition(text)) i++
                else if ((n = comment_prefix(text))) {
                    comment = 1
                    text = comment_tail(substr(text, n + 1))
                    if (!comment) body(text, i, 0, 0)
                    i++
                } else if (text ~ /^ ? ? ?>/) {
                    sub(/^([[:blank:]]*>)+[[:blank:]]*/, "", text)
                    quote = (text != "" && text !~ /^<!--/ && !interrupts(text))
                    i++
                } else if ((mark = fence_run(text)) != "") {
                    sub(/^ */, "", text)
                    i = fenced(i, base, mark, normalize(substr(text, length(mark) + 1)))
                } else if (atx(text)) {
                    body(text, i, 0, !depth)
                    i++
                } else if ((columns_n = table_ahead(text, i, base))) {
                    i = table(i, base, text, columns_n)
                } else {
                    i = paragraph(i, base, prefix text, item)
                }
            }
        }
        FNR == 1 {
            if (last) document()
            file = FILENAME; group = family(file); last = 0
        }
        group != "" {
            line = $0; sub(/\r$/, "", line)
            src[++last] = expand_indent(line)
        }
        END { if (!loaded || invalid) exit 1; if (last) document() }
    ' "$catalog" "${files[@]}"
)
