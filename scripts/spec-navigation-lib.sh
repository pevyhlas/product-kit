#!/usr/bin/env bash
# One conservative recognizer for prose budgets and routine context. Raw source stays canonical.
# Bash 3.2 / POSIX awk; no network, tracker, jq or generated source writes.

spec_navigation() { # file budget|stats|compact|diagnostics|target|index|section [selector] [expected lines and bytes]
    local terminated=1 last
    [ -f "$1" ] || { printf 'No source file: %s\n' "$1" >&2; return 2; }
    last="$(tail -c 1 "$1" && printf x)" || return 1
    case "$last" in x|$'\nx') ;; *) terminated=0 ;; esac
    LC_ALL=C PRDKIT_NAV_SELECTOR="${3:-}" awk -v mode="$2" -v terminated="$terminated" \
        -v expected_lines="${4:-}" -v expected_bytes="${5:-}" \
        "$SPEC_HEADING_AWK $SPEC_BULLET_ID_AWK $SPEC_PART_AWK $SPEC_RECORD_ROW_AWK"'
        BEGIN { focused = mode == "index" || mode == "section" }
        function norm(s) {
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); gsub(/[[:space:]]+/, " ", s)
            return tolower(s)
        }
        function chars(s) { gsub(/[\200-\277]/, "", s); return length(s) }
        function reading(s,   n) { n = chars(s); return n > 100 ? int((n + 99) / 100) : 1 }
        function bad(s) { if (!reason) reason = s; invalid = 1 }
        function brackets(s,   key) {
            while (match(s, /\[[^][]+\]/)) {
                key = norm(substr(s, RSTART + 1, RLENGTH - 2)); mentions[key]++
                s = substr(s, RSTART + RLENGTH)
            }
        }
        function tracking(s,   key, label, pending, records, n, i) {
            sub(/^ *Tracking: */, "", s)
            while (s != "") {
                if (!match(s, /^\[[A-Za-z0-9][A-Za-z0-9._\/-]*\]\[[Nn][Aa][Vv]-[A-Za-z0-9_-]+\]/)) return
                label = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
                if (mode == "section") records[++n] = substr(label, 2, index(label, "]") - 2)
                sub(/^\[[^]]+\]\[/, "", label); sub(/\]$/, "", label)
                key = norm(label); pending[key]++
                if (s != "" && s !~ /^ +/) return
                sub(/^ +/, "", s)
            }
            for (key in pending) uses[key] += pending[key]
            for (i = 1; i <= n; i++) alias(section, records[i])
        }
        function alias(n, id,   key) {
            if (!n || id == "") return
            key = norm(id)
            if (!((n, key) in aliases)) {
                aliases[n, key] = 1
                names[n] = names[n] (names[n] == "" ? "" : ", ") id
            }
        }
        function structure_break() { paragraph = 0; part_table = 0 }
        # Match only a potential top-level paragraph underline, not a break after a blank.
        function check_setext(t, depth,   markers) {
            if (!underline && paragraph && t ~ /^(=+|-+)[ \t]*$/) underline = NR
            if (t ~ /^[ \t]+[^ \t]/) return
            markers = t; gsub(/[ \t]/, "", markers)
            paragraph = !depth && t !~ /^[ \t]*$|^[|>]|^([-+*]|[0-9]+[.)])([ \t]|$)/ &&
                        markers !~ /^---+$|^\*\*\*+$|^___+$/ && t !~ /^=+[ \t]*$/
        }
        # The most recent heading owns its IDs; only section spans include descendants.
        function structure(line, t,   depth, d, word, row) {
            depth = spec_heading(line)
            check_setext(t, depth)
            if (depth) {
                part_table = 0; retired = heading_title == "Retired"
                for (d = 6; d >= depth; d--) if (d in open) {
                    last_line[open[d]] = NR - 1; delete open[d]
                }
                for (d = depth - 1; d > 0 && !(d in open); d--) {}
                section = ++sections
                first_line[section] = NR; levels[section] = depth; titles[section] = heading_title
                indent[section] = d ? indent[open[d]] "  " : ""
                open[depth] = section
                if (mode == "section") {
                    split(heading_title, word, " "); sub(/:$/, "", word[1])
                    if (word[1] ~ /^[A-Za-z][A-Za-z0-9._-]*-[0-9]+$/ || spec_part_id(word[1]))
                        alias(section, word[1])
                }
            } else if (mode == "section" && section) {
                alias(section, spec_bullet_id(line))
                if (line !~ /^\|/) part_table = 0
                if (spec_part_header(line)) part_table = 1
                else if (part_table) alias(section, spec_part_row(line))
                if (retired) alias(section, spec_retired_part(line))
                if (spec_record_row(line, row) == "") alias(section, row["name"])
            }
        }
        function visible(i) { return !valid || i < start || i > end }
        function section_label(n,   h) {
            for (h = ""; length(h) < levels[n]; h = h "#") {}
            return first_line[n] ": " indent[n] h " " (titles[n] == "" ? "(untitled)" : titles[n])
        }
        function index_sections(   n, i, count) {
            if (!sections) print "No ATX headings."
            for (n = 1; n <= sections; n++) {
                count = 0
                for (i = first_line[n]; i <= last_line[n]; i++) if (visible(i)) count += weight[i]
                printf "%s (%d reading line%s)\n", section_label(n), count, (count == 1 ? "" : "s")
            }
        }
        function select_section(   selector, n, found, count, i) {
            selector = norm(ENVIRON["PRDKIT_NAV_SELECTOR"])
            for (n = 1; n <= sections; n++) {
                if (selector != "" && ("x" norm(titles[n]) == "x" selector || (n, selector) in aliases)) {
                    matched[n] = 1; found = n; count++
                }
            }
            if (count != 1) {
                if (selector == "") print "Missing section selector. Available candidates:"
                else printf "%s section selector: \"%s\". Available candidates:\n",
                    (count ? "Ambiguous" : "No match for"), ENVIRON["PRDKIT_NAV_SELECTOR"]
                if (!sections) print "  (no ATX headings)"
                for (n = 1; n <= sections; n++) if (!count || matched[n])
                    print "  " section_label(n) (names[n] == "" ? "" : " [IDs: " names[n] "]")
                print "Use a unique heading or ID, or --raw to inspect the source."
                exit 10
            }
            for (i = first_line[found]; i <= last_line[found]; i++) if (visible(i)) printf "%d: %s\n", i, raw[i]
        }
        {
            raw[NR] = $0; bytes[NR] = length($0) + 1; weight[NR] = reading($0)
            raw_bytes += bytes[NR]; raw_reading += weight[NR]
            line = $0; sub(/\r$/, "", line)
            t = spec_unindent(line)
            if (fence != "") {
                if (match(t, /^`+|^~+/) && substr(t, 1, 1) == fence && RLENGTH >= fence_len &&
                    substr(t, RLENGTH + 1) ~ /^[ \t]*$/) fence = ""
                next
            }
            if (comment) { if (index(line, "-->")) comment = 0; next }
            starts_comment = line ~ /^[[:space:]]*<!--/
            if (starts_comment && !index(line, "-->")) comment = 1
            if (index(line, "prdkit:navigation:")) {
                if (line == "<!-- prdkit:navigation:v1 begin -->") {
                    if (start) bad("multiple or nested navigation blocks")
                    else start = NR
                    in_block = 1
                } else if (line == "<!-- prdkit:navigation:v1 end -->") {
                    if (!in_block || end) bad("unmatched navigation end marker")
                    end = NR; in_block = 0
                } else bad("unknown or malformed navigation marker")
                candidate = 1; structure_break(); next
            }
            if (in_block && line ~ /^\[[Nn][Aa][Vv]-[A-Za-z0-9_-]+\]: https?:\/\/[^][[:space:]<>()"\047]+$/) {
                # No blanks, prose, titles or general-purpose references inside the envelope.
                key = line; sub(/^\[/, "", key); sub(/\].*/, "", key); key = norm(key)
                url = line; sub(/^[^]]+\]: /, "", url)
                authority = url; sub(/^https?:\/\//, "", authority); sub(/[\/#?].*/, "", authority)
                path = url; sub(/^https?:\/\/[^\/]*\//, "", path)
                if (authority !~ /^[A-Za-z0-9][A-Za-z0-9.-]*(:[0-9]+)?$/ || path == url || path == "")
                    bad("navigation targets need an absolute detail URL without user information")
                if (key in urls) bad("duplicate navigation label")
                urls[key] = url; locations[key] = NR; definitions++; next
            }
            if (in_block) {
                bad("navigation block contains an unsupported definition or other content")
                if (!focused) next
            }
            if (end && line !~ /^[[:space:]]*$/) bad("navigation block is not a footer")
            if (starts_comment) { structure_break(); next }
            if (match(t, /^```+|^~~~+/) && (substr(t, 1, 1) == "~" || !index(substr(t, RLENGTH + 1), "`"))) {
                fence = substr(t, 1, 1); fence_len = RLENGTH; structure_break(); next
            }
            if (focused) structure(line, t)
            # Full HTML-block parsing is outside this narrow convention. Keep the raw file.
            if (line ~ /<[\/!?A-Za-z]/) html = 1
            # Count possible definitions/uses conservatively, including unusual indentation,
            # inline code and containers. False ambiguity keeps content; it never hides it.
            brackets(line)
            scan = line
            while (match(scan, /\[[^][]+\]:/)) {
                key = norm(substr(scan, RSTART + 1, RLENGTH - 3)); outside[key]++
                scan = substr(scan, RSTART + RLENGTH)
            }
            if (line ~ /^ ? ? ?Tracking: /) tracking(line)
        }
        END {
            if (NR && !terminated) { bytes[NR]--; raw_bytes-- }
            if (expected_lines != "" && (NR != expected_lines || raw_bytes != expected_bytes)) {
                printf "Incomplete navigation input: expected %d lines/%d bytes, checked %d/%d\n", expected_lines, expected_bytes, NR, raw_bytes
                exit 1
            }
            if (candidate) {
                if (!start || !end || in_block || !definitions) bad("incomplete or empty navigation footer")
                if (html) bad("unsupported HTML context; navigation retained")
                for (key in urls) {
                    if (outside[key]) bad("navigation label conflicts with an authored definition")
                    if (!uses[key] || mentions[key] != uses[key]) bad("navigation label is unreferenced or used outside Tracking links")
                }
                for (key in uses) if (!(key in urls)) bad("Tracking link has no navigation definition")
            }
            valid = candidate && !invalid
            if (valid) for (i = start; i <= end; i++) {
                omitted_lines++; omitted_bytes += bytes[i]; omitted_reading += weight[i]
            }
            prose = raw_reading - omitted_reading
            state = valid ? "valid" : (candidate ? "retained-invalid" : "absent")
            if (mode == "budget") print prose, NR
            else if (mode == "stats")
                printf "projection=prdkit-navigation-v1 state=%s raw_bytes=%d raw_lines=%d raw_reading_lines=%d prose_reading_lines=%d omitted_bytes=%d omitted_lines=%d definitions=%d\n", state, raw_bytes, NR, raw_reading, prose, omitted_bytes, omitted_lines, (valid ? definitions : 0)
            else if (mode == "diagnostics") { if (candidate && invalid) print "Generated navigation retained: " reason }
            else if (mode == "compact") {
                for (i = 1; i <= NR; i++) if (visible(i)) printf "%d: %s\n", i, raw[i]
            } else if (mode == "target") {
                key = norm(ENVIRON["PRDKIT_NAV_SELECTOR"])
                if (!valid || !(key in urls)) exit 1
                printf "%d: [%s]: %s\n", locations[key], key, urls[key]
            } else if (focused) {
                if (underline) {
                    printf "%d: Setext (underlined) headings are not supported; use --raw or convert to ATX headings.\n", underline
                    exit 10
                }
                for (d in open) last_line[open[d]] = NR
                if (mode == "index") index_sections()
                else select_section()
            }
        }
    ' "$1"
}
