#!/usr/bin/env bash
# Compare project-owned files with generated stock line skeletons, not with
# consumer-editable templates. See maintainer/generate-template-residue.py.

template_residue_rows() ( # root, followed by the already discovered spec and change paths
    local catalog
    catalog="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/template-residue.tsv" || return 1
    cd "$1" || return 1
    shift
    local path files=()
    for path in .prdkit/memory/constitution.md .prdkit/memory/agents.md .prdkit/memory/config.md \
                .prdkit/history/archive.md .prdkit/agents/*.md specs/inbox.md specs/records.md specs/authority.md \
                specs/observed.md specs/observed/*.md "$@"; do
        [ ! -f "$path" ] || files+=("$path")
    done
    [ "${#files[@]}" -gt 0 ] || return 0
    # Pass the catalog as a filename operand (not -v, which interprets backslashes).
    # shellcheck disable=SC2016 # awk uses its own $0
    LC_ALL=C awk -F '\t' -v marker="$PRDKIT_UNCONFIRMED_DEFAULT" "$SPEC_METADATA_SKIP_AWK"'
        BEGIN {
            # The combined form uses the same row skeletons as the split files.
            combined["problem and users"] = "product lifecycle"
            combined["journeys"] = "product journey"
            combined["requirements and qualities"] = "requirements qualities"
            combined["constraints and non-goals"] = "constraints non-goals"
            combined["shape and parts"] = "architecture architecture-topics part design"
            combined["decisions and why it works"] = "decision architecture-topics architecture"
            combined["left open"] = "requirements architecture part"
        }
        FILENAME == ARGV[1] {
            if ($0 ~ /^#/) next
            if (NF != 5) { invalid = 1; exit 1 }
            i = ++count[$1]
            literal[$1,i] = $2; ordinal[$1,i] = $3
            wrapped[$1,i] = $4; regex[$1,i] = $5
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
        function reset_window() {
            prev1 = prev2 = ""
        }
        function fits(line, shape, nested_heading) {
            if (line ~ shape) return 1
            # Split-file headings become subheadings in the combined file.
            if (!nested_heading) return 0
            while (line ~ /^##/) {
                line = substr(line, 2)
                if (line ~ shape) return 1
            }
            return 0
        }
        # A catalog regex fixes one slot to its original token, with the other
        # slots open. Test the entire line; dedupe alternate skeletons (including
        # combined/split overlap) but count repeated slots in the same row.
        function scan(groups, suffix, line, nested_heading,   n, g, i, names, group, token, shape, start, key, body2, body3, at, reason, candidate) {
            n = split(groups, names, " ")
            body2 = (prev1 != "" ? prev1 " " line : "")
            body3 = (prev2 != "" ? prev2 " " body2 : "")
            at = (groups == "records" ? index(line, " — ") : 0)
            if (at) reason = substr(line, at + length(" — "))
            for (g = 1; g <= n; g++) {
                group = names[g] suffix
                for (i = 1; i <= count[group]; i++) {
                    token = literal[group,i]
                    shape = regex[group,i]
                    # The owner may use em dashes in a reason. Do not let an
                    # open slot consume their quote and match a suffix of it.
                    candidate = (at && token != reason ? substr(line, 1, at - 1) " — filled" : line)
                    if (index(candidate, token) && fits(candidate, shape, nested_heading && group != "spec")) start = FNR
                    else if (wrapped[group,i] && index(body2, token) && body2 ~ shape) start = prevnr
                    else if (wrapped[group,i] && index(body3, token) && body3 ~ shape) start = prevnr2
                    else continue
                    key = start SUBSEP token SUBSEP ordinal[group,i] SUBSEP account
                    if (!seen[key]++) printf "P\037%s:%d (%s)\n", FILENAME, start, token
                }
            }
            prev2 = prev1; prevnr2 = prevnr
            prev1 = line; prevnr = FNR
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
                account = i
                scan("config", "", key ": " value)
            }
            account = ""
        }
        FNR == 1 {
            group = family(FILENAME)
            metadata_code = metadata_comment = section = code_groups = code_suffix = ""
            reset_window()
            for (key in seen) delete seen[key]
            frontmatter = 0
        }
        group == "" { next }
        {
            line = $0; sub(/\r$/, "", line)
            if (group == "agent-definition" && line == "---" && (FNR == 1 || frontmatter)) {
                frontmatter = (FNR == 1)
                next
            }
            if (frontmatter) {
                scan(group, "@frontmatter", normalize(line))
                next
            }
            was_code = metadata_code
            if (metadata_skip(line)) {
                if (was_code != "" && metadata_code != "" && code_groups != "")
                    scan(code_groups, code_suffix, normalize(line))
                else {
                    code_groups = code_suffix = ""
                    reset_window()
                    if (was_code == "" && metadata_code != "") {
                        if (group == "constitution" && section == "commands") {
                            code_groups = group; code_suffix = "@commands"
                        }
                        if (line ~ /^ ? ? ?(```+|~~~+)mermaid[[:blank:]]*$/) {
                            code_groups = group == "spec" ? combined[section] : group
                            code_suffix = "@mermaid"
                        }
                    }
                }
                next
            }
            # Quoted text and Markdown examples are not project policy.
            if (line ~ /^[[:blank:]]*>/) { reset_window(); next }
            indented = line ~ /^    |^\t/
            gsub(/<!--([^-]|-[^-]|--[^>])*-->/, "", line)
            if ((at = index(line, "<!--")) > 0) {
                metadata_comment = 1
                line = substr(line, 1, at - 1)
            }
            line = normalize(line)
            if (line ~ /^##?( |$)/ && !indented) {
                section = ""
                if (line ~ /^## /) {
                    section = tolower(substr(line, 4))
                    sub(/ #+$/, "", section)
                }
            }
            if (line == "" || line ~ /^#/) reset_window()
            if (line == "") next
            if (indented) { reset_window(); next }
            if (group == "config") {
                if (section == "configuration") scan_accounts(line)
                next
            }
            if (group == "constitution") {
                value = line
                if (sub(/^[-*[:space:]]*[Rr]igor\**:\**[[:space:]]*/, "", value) && index(value, marker))
                    printf "D\037%s:%d (Rigor)\n", FILENAME, FNR
            }
            groups = group
            if (group == "spec" && combined[section] != "") groups = groups " " combined[section]
            # The Commands placeholder remains a slot if copied out of its fence.
            if (group == "constitution" && section == "commands") scan(group, "@commands", line)
            else scan(groups, "", line, group == "spec" && line ~ /^###/)
        }
        END { if (!loaded || invalid) exit 1 }
    ' "$catalog" "${files[@]}"
)
