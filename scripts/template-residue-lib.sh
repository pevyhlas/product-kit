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
            angle = "<([^<>[:cntrl:]]|<[^<>[:cntrl:]]*>)+>"
            ignored = sprintf("%c", 28)
            n = split(stages, defaults, ">")
            for (i = 1; i <= n; i++) stage_name[defaults[i]] = 1
            stage_name["general availability"] = 1
        }
        FILENAME == ARGV[1] {
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
            gsub(/\\</, "<", s)
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
        function accepts(names, token, before, after, surface, cell,   groups,n,g,k,i,mode,selector,parts,reason) {
            n = split(names, groups, " ")
            for (g = 1; g <= n; g++) {
                k = groups[g]
                for (i = 1; i <= size[k,token]; i++) {
                    mode = kind[k,token,i]; selector = arg[k,token,i]
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
        function scan(names, line, tail, nr, continuation, surface, cell,   rest,offset,at,end,len,token,before,after) {
            len = length(line); rest = line tail
            while (match(rest, angle)) {
                at = offset + RSTART
                if (at > len) break
                end = at + RLENGTH - 1
                token = substr(rest, RSTART, RLENGTH)
                before = substr(line, 1, at - 1); after = substr(line, end + 1)
                # A cross-line match can only be a distinctive prose token.
                if (accepts(names, token, before, after, (end > len ? "body-wrap" : surface), cell)) {
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
        function mask_inline(text,   out,at,n,rest,span,tmp,token) {
            while (match(text, /[`<]/)) {
                at = RSTART
                out = out substr(text, 1, at - 1); text = substr(text, at)
                if (substr(text, 1, 1) == "<") {
                    # One stock prompt contains literal Markdown code itself.
                    tmp = text; gsub(/\n/, " ", tmp)
                    if (match(tmp, angle) && RSTART == 1) {
                        span = substr(text, 1, RLENGTH); token = normalize(substr(tmp, 1, RLENGTH))
                        if (token in keeps_ticks) { out = out span; text = substr(text, RLENGTH + 1); continue }
                    }
                } else {
                    match(text, /^`+/); n = RLENGTH
                    rest = substr(text, n + 1)
                    if ((at = code_end(rest, n))) {
                        span = substr(rest, 1, at)
                        gsub(/[^\n]+/, ignored, span)
                        out = out ignored span; text = substr(rest, at + 1); continue
                    }
                    out = out substr(text, 1, n); text = rest; continue
                }
                out = out "<"; text = substr(text, 2)
            }
            return out text
        }
        function strip_comments(line,   out,at,n,rest) {
            while (line != "") {
                if (comment) {
                    at = index(line, "-->")
                    if (!at) return out
                    out = out ignored; line = substr(line, at + 3); comment = 0
                } else if (match(line, /<!--|`+/)) {
                    out = out substr(line, 1, RSTART - 1)
                    n = RLENGTH; line = substr(line, RSTART)
                    if (index(line, "<!--") == 1) { line = substr(line, 5); comment = 1 }
                    else {
                        rest = substr(line, n + 1); at = code_end(rest, n)
                        out = out substr(line, 1, n + at); line = substr(rest, at + 1)
                    }
                } else return out line
            }
            return out
        }
        function split_cells(line, cells) {
            gsub(/\\\|/, ignored, line)
            sub(/^\|/, "", line); sub(/\|$/, "", line)
            return split(line, cells, /\|/)
        }
        function start_table(line, divider,   k,n,name) {
            if (line !~ /\|/ || divider !~ /\|/) return 0
            n = split_cells(line, columns)
            if (n != split_cells(divider, cells)) return 0
            for (k = 1; k <= n; k++)
                if (cells[k] !~ /^ *:?-+:? *$/) return 0
            for (k = 1; k <= n; k++) {
                name = tolower(normalize(columns[k]))
                columns[k] = name; headers[name] = 1
                if (name ~ / \(now\)$/ || name ~ /^<(now|next|later) stage>$/ ||
                    (section == "journeys" && name in stage_name)) stage_columns[name] = 1
            }
            return n
        }
        function end_table(   key) {
            for (key in headers) delete headers[key]
            for (key in stage_columns) delete stage_columns[key]
            stage_table = width = 0
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
        function flush_block(   a,b,n,i,j,k,m,line,tail,nr,continuation,bullet,header) {
            if (!line_count) return
            n = split(mask_inline(buffer), a, "\n")
            for (i = 1; i <= n; i++) b[i] = normalize(a[i])
            end_table()
            for (i = 1; i <= n; i++) {
                line = b[i]; nr = first_line + i - 1
                header = 0
                if (line !~ /\|/) end_table()
                else if (!width && i < n && (width = start_table(line, b[i+1]))) {
                    header = 1
                    if ("area" in headers) {
                        for (k in stage_columns) { stage_table = 1; break }
                        # A journey destination also identifies a custom stage
                        # column, without treating every other column as a stage.
                        if (section == "journeys" || stage_table)
                            for (j = i + 2; j <= n && b[j] ~ /\|/; j++) {
                                m = split_cells(b[j], cells)
                                for (k = 1; k <= m && k <= width; k++)
                                    if (columns[k] != "area" && cells[k] ~ /\]\(product\/journeys\//) {
                                        stage_columns[columns[k]] = 1
                                        stage_table = 1
                                    }
                            }
                    }
                }
                if (width) {
                    m = split_cells(line, cells)
                    for (k = 1; k <= m; k++)
                        scan(group_names, normalize(cells[k]), "", nr, 0,
                            (header ? "body-header" : "body-cell"), (k <= width ? columns[k] : ""))
                    continue
                }
                if (line ~ /^[-*+] /) bullet = nr
                else if (line ~ /^(#|\|)/ || a[i] !~ /^[[:blank:]]/) bullet = 0
                continuation = (bullet && bullet < nr ? bullet : 0)
                tail = ""
                if (index(line, "<")) {
                    for (j = i + 1; j <= n && length(tail) < max_slot; j++) {
                        if (b[j] ~ /^(#|\||[-*+] )/) break
                        tail = tail " " substr(b[j], 1, max_slot)
                    }
                }
                scan(group_names, line, tail, nr, continuation, "body")
                scan_plain(group_names, line, nr)
            }
            line_count = 0; buffer = ""
        }
        function scan_accounts(line,   key, value, items, i, n) {
            key = line; sub(/:.*/, "", key)
            if (key !~ /^- review-(publishers|owner)$/) return
            value = substr(line, length(key) + 2)
            n = split(value, items, ",")
            for (i = 1; i <= n; i++) {
                # Each comma-delimited account is a value of the same stock field.
                # Allow the other supported publisher prefix without matching prose.
                value = normalize(items[i])
                if (key == "- review-publishers") sub(/^user:/, "bot:", value)
                scan("config", key ": " value, "", FNR, 0, "body")
            }
        }
        FNR == 1 {
            flush_block()
            file = FILENAME
            group = family(FILENAME)
            group_names = group; section = fence = code_groups = diagram = ""
            frontmatter = comment = quoted_paragraph = 0
        }
        group == "" { next }
        {
            line = $0; sub(/\r$/, "", line)
            if (group == "agent-definition" && line == "---" && (FNR == 1 || frontmatter)) {
                frontmatter = (FNR == 1)
                next
            }
            if (frontmatter) {
                scan_plain(group "@frontmatter", normalize(line), FNR)
                next
            }
            if (fence != "") {
                if (line ~ /^ ? ? ?(`+|~+)[[:blank:]]*$/ && length(normalize(line)) >= length(fence) &&
                    index(normalize(line), fence) == 1) fence = comment = ""
                else if (code_groups != "") {
                    line = normalize(line)
                    if (line ~ /^(flowchart |sequenceDiagram$)/) { diagram = line; sub(/ .*/, "", diagram) }
                    else if (diagram == "commands") scan(code_groups, line, "", FNR, 0, "commands")
                    else if (line !~ /^%%/) scan(code_groups, normalize(mask_inline(strip_comments(line))), "", FNR, 0, "diagram")
                }
                next
            }
            if (!comment && line ~ /^[[:blank:]]*>/) {
                flush_block()
                quote = line; sub(/^[[:blank:]>]+/, "", quote)
                quoted_paragraph = (quote != "" && quote !~ /^(#|```|~~~|<!--)/)
                next
            }
            # A quote paragraph may continue on an unmarked line.
            if (quoted_paragraph && line !~ /^[[:blank:]]*($|#|```|~~~|<!--|[-*+] |[0-9]+[.)] )/) next
            quoted_paragraph = 0
            if (!comment && match(line, /^ ? ? ?(```+|~~~+)/)) {
                info = normalize(substr(line, RLENGTH + 1)); fence = normalize(substr(line, 1, RLENGTH))
                flush_block()
                code_groups = diagram = ""
                if (info == "mermaid") {
                    source_groups = (group == "spec" ? combined[section] : group)
                    n = split(source_groups, sources, " ")
                    for (i = 1; i <= n; i++) code_groups = code_groups (i > 1 ? " " : "") sources[i] "@mermaid"
                } else if (group == "constitution" && section == "commands") {
                    code_groups = group "@commands"; diagram = "commands"
                }
                next
            }
            indented = line ~ /^    |^\t/
            line = strip_comments(line)
            text = normalize(line)
            if (text == "" || text == ignored || indented) { flush_block(); next }
            if (text ~ /^##?( |$)/) {
                flush_block()
                section = ""
                if (text ~ /^## /) {
                    section = tolower(substr(text, 4))
                    sub(/ #+$/, "", section)
                }
                group_names = group
                if (group == "spec" && combined[section] != "") group_names = group " " combined[section]
                if (group == "constitution" && section == "commands") group_names = group " " group "@commands"
            }
            if (group == "config") {
                if (section == "configuration") scan_accounts(normalize(mask_inline(line)))
                next
            }
            if (group == "constitution") {
                value = text
                if (sub(/^[-*[:space:]]*[Rr]igor\**:\**[[:space:]]*/, "", value) && index(value, marker))
                    printf "D\037%s:%d (Rigor)\n", file, FNR
            }
            if (!line_count) first_line = FNR
            buffer = buffer (line_count++ ? "\n" : "") line
        }
        END { if (!loaded || invalid) exit 1; flush_block() }
    ' "$catalog" "${files[@]}"
)
