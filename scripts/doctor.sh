#!/usr/bin/env bash
# doctor.sh — Read-only diagnostics: installation, spec layout and budgets, IDs, records,
# owner inbox, raw evidence, agent context and agent projections. Never repairs anything.
#
# Usage: doctor.sh [--json] [--strict] [--inventory]
# Errors (failing findings): installation drift, malformed IDs, malformed records, agent
# tier-map problems, a change record deleted without its specs/log.md line. Everything else is an advisory; --strict makes advisories fail too.
set -euo pipefail
SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/install-lib.sh"
source "$SCRIPT_DIR/context-budget-lib.sh"
source "$SCRIPT_DIR/agent-tiers-lib.sh"
source "$SCRIPT_DIR/spec-lib.sh"
source "$SCRIPT_DIR/diagnostics-lib.sh"
json=false; strict=false; inventory=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        --json) json=true ;;
        --strict) strict=true ;;
        --inventory) inventory=true ;;
        *) echo 'Usage: doctor.sh [--json] [--strict] [--inventory]' >&2; exit 2 ;;
    esac
    shift
done
root="$(get_repo_root)"; findings=(); advisories=()
today="$(spec_today)"; SEP="$SPEC_SEP"
in_git=false
git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1 && in_git=true

# --- Installation ------------------------------------------------------------------------------
while IFS= read -r finding; do
    [ -z "$finding" ] || findings+=("$finding")
done < <(install_findings "$root")
for file in "$root"/specs/changes/*.md; do
    [ -f "$file" ] || continue
    while IFS= read -r advisory; do
        [ -z "$advisory" ] || advisories+=("${file#"$root"/}: $advisory")
    done < <(spec_change_progress "$file" false advisories)
done
for file in .prdkit/workflows/protocol.md .prdkit/workflows/change.md .prdkit/workflows/review.md .prdkit/memory/constitution.md .prdkit/templates/change-template.md; do
    [ -f "$root/$file" ] || findings+=("Missing installed file: $file")
done

# --- Layout --------------------------------------------------------------------------------------
case "$(spec_layout "$root")" in
    0.x) advisories+=("0.x layout — run the cutover (.prdkit/workflows/compact.md) before 1.0 workflows apply") ;;
    both) advisories+=("Two canons: 1.0 spec files beside 0.x folders (specs/product-spec, specs/targets or specs/features); finish the cutover: condense them into the spec and specs/archive.md, turn a feature the owner keeps open into a change record, and git rm them (.prdkit/workflows/compact.md)") ;;
esac
# No raw archive on main: it surfaces in searches beside the current spec. Git keeps the files.
if $in_git; then
    archived="$({ git -C "$root" ls-files -- specs/archive/ 2>/dev/null || true; } | wc -l | tr -d ' ')"
    [ "${archived:-0}" -eq 0 ] || advisories+=("Archive on main: specs/archive/ tracks $archived file(s); condense them into specs/archive.md and remove them from main with git rm; git keeps them (.prdkit/workflows/compact.md)")
fi
# specs/archive.md records the base commit and the last 0.x feature; new-change.sh reserves the
# old feature numbers from both. A base a shallow clone lacks is not judged.
if [ -f "$root/specs/archive.md" ]; then
    last="$(spec_archive_last "$root")"; archive_problems=""
    [ -n "$last" ] || archive_problems="no readable **Last 0.x feature** line (a number, or none)"
    if [ "$last" != 0 ]; then
        tokens="$(spec_archive_base_tokens "$root")"
        if [ -z "$tokens" ]; then
            archive_problems="${archive_problems:+$archive_problems and }no **Base** commit"
        elif $in_git && [ "$(git -C "$root" rev-parse --is-shallow-repository 2>/dev/null)" != true ]; then
            resolved=false
            while IFS= read -r token; do
                if git -C "$root" rev-parse --verify --quiet "$token^{commit}" >/dev/null 2>&1; then resolved=true; break; fi
            done <<< "$tokens"
            $resolved || archive_problems="${archive_problems:+$archive_problems and }a **Base** commit that is not in this repository ($(printf '%s\n' "$tokens" | sed -n 1p))"
        fi
    fi
    [ -z "$archive_problems" ] || advisories+=("Archive: specs/archive.md has $archive_problems; new-change.sh reserves the old 0.x feature numbers from them (.prdkit/templates/archive-template.md)")
fi
mixed="$(spec_mixed_forms "$root")"
[ -z "$mixed" ] || advisories+=("Two spec forms: specs/SPEC.md beside $mixed; keep one form — split SPEC.md fully in one change and delete it, or fold the split files back (.prdkit/workflows/spec.md)")

# --- Reading budgets (never targets; never drop an item to fit) -------------------------------
# A line counts once per 100 characters (spec_reading_lines), so a long row cannot dodge one.
budget_fix() { # limit remedy path...
    local limit="$1" fix="$2" path reading lines size; shift 2
    for path in "$@"; do
        [ -f "$path" ] || continue
        read -r reading lines <<< "$(spec_reading_lines "$path")"
        [ "$reading" -gt "$limit" ] || continue
        size="$lines lines that read"; [ "$lines" != 1 ] || size="1 line that reads"
        if [ "$reading" = "$lines" ]; then size="${size% that read*}"; else size="$size as $reading at 100 characters a line"; fi
        advisories+=("Budget: ${path#"$root"/} has $size, over its $limit-line reading budget; $fix")
    done
}
budget() { # limit path...
    budget_fix "$1" "tighten the wording, move detail to code or tests, or split it (spec.md, Layout); never drop an item to fit" "${@:2}"
}
# In the 1.1 layout (beside specs/product/) product.md and architecture.md are one-page summaries;
# the 1.0 single-file forms keep 150 and 300.
if [ -d "$root/specs/product" ]; then
    budget 80 "$root"/specs/product.md; budget 100 "$root"/specs/architecture.md
else
    budget 150 "$root"/specs/product.md; budget 300 "$root"/specs/architecture.md
fi
# Each budget has a split (spec.md, Layout), and each piece keeps the budget of its parent.
budget 150 "$root"/specs/product/users.md "$root"/specs/product/users/*.md \
    "$root"/specs/product/non-goals.md "$root"/specs/product/non-goals/*.md \
    "$root"/specs/product/lifecycle.md "$root"/specs/product/lifecycle/*.md "$root"/specs/product/journeys/*.md \
    "$root"/specs/observed.md "$root"/specs/observed/*.md "$root"/specs/changes/*.md "$root"/specs/archive.md
budget 300 "$root"/specs/product/requirements.md "$root"/specs/product/qualities.md "$root"/specs/product/constraints.md \
    "$root"/specs/product/requirements/*.md "$root"/specs/product/qualities/*.md "$root"/specs/product/constraints/*.md \
    "$root"/specs/architecture/*.md "$root"/specs/architecture/*/*.md "$root"/specs/decisions/*.md \
    "$root"/specs/SPEC.md
budget 200 "$root"/specs/parts/*.md "$root"/specs/parts/*/*.md
budget_fix 150 "condense its older entries into specs/archive.md at the next compaction (compact.md)" "$root"/specs/log.md
budget_fix 150 "incorporate answered items (spec.md, Resolve owner answers), review the rest with the owner (/prdkit-inbox), and keep each item's context in the files it links" "$root"/specs/inbox.md
budget_fix 150 "remove lifted or expired holds and waivers, and DEPLOY and ATTEST lines a newer one supersedes; git keeps them" "$root"/specs/records.md

# --- IDs ---------------------------------------------------------------------------------------
items="$(spec_items "$root")"
while IFS= read -r problem; do [ -z "$problem" ] || findings+=("$problem"); done < <(
    printf '%s\n' "$items" | awk -F "$SEP" 'NF { if ($1 in at) print "Duplicate ID " $1 ": defined at " at[$1] " and " $7; else at[$1] = $7 }')
while IFS="$SEP" read -r file part; do
    [ -n "$file" ] || continue
    if [ -z "$part" ]; then advisories+=("$file: no '# P<n> name' heading, so its behaviors and invariants cannot be checked against their part"); continue; fi
    while IFS= read -r problem; do [ -z "$problem" ] || findings+=("$problem"); done < <(
        printf '%s\n' "$items" | awk -F "$SEP" -v file="$file" -v part="$part" '
            index($7, file ":") == 1 && $1 ~ /^P[0-9]+\./ && substr($1, 1, index($1, ".") - 1) != part {
                print $1 " is defined in " $7 ", the part file of " part }')
done < <(spec_part_headings "$root")
while IFS= read -r where; do [ -z "$where" ] || findings+=("Malformed ID at $where: IDs are J-, R-, Q-, C-, N-, D- or P<n>.B-/P<n>.I- with two or more digits"); done < <(
    while IFS= read -r file; do
        awk -v file="$file" "$SPEC_SKIP_AWK"'{ if (spec_skip($0)) next }
            /^[[:space:]]*[-*][[:space:]]+\*\*J-[0-9][[:space:]*]/ { next }
            /^[[:space:]]*[-*][[:space:]]+\*\*(P[0-9]+\.)?[JRQCDNBI]-/ && !/^[[:space:]]*[-*][[:space:]]+\*\*(P[0-9]+\.[BI]|[JRQCDN])-[0-9][0-9]+[[:space:]*]/ { print file ":" NR }
            /^#[[:space:]]+J-/ && !/^#[[:space:]]+J-[0-9][0-9]+[[:space:]]/ { print file ":" NR }
            /^##?#?[[:space:]]+D-/ && !/^##?#?[[:space:]]+D-[0-9][0-9]+[[:space:]]/ { print file ":" NR }' "$root/$file"
    done < <(spec_files "$root"))
# The 1.0 product template wrote journeys as one-digit `- **J-1 ...**` bullets; the Restructure
# renumbers them.
oldj=""
while IFS= read -r where; do [ -z "$where" ] || oldj="${oldj:+$oldj, }$where"; done < <(
    while IFS= read -r file; do
        awk -v file="$file" "$SPEC_SKIP_AWK"'{ if (spec_skip($0)) next }
            /^[[:space:]]*[-*][[:space:]]+\*\*J-[0-9][[:space:]*]/ { print file ":" NR }' "$root/$file"
    done < <(spec_files "$root"))
[ -z "$oldj" ] || advisories+=("One-digit journey IDs at $oldj (the 1.0 form): the Restructure in .prdkit/workflows/compact.md renumbers them to J-01")

cite_files=()
while IFS= read -r file; do cite_files+=("$file"); done < <(
    spec_files "$root"
    spec_test_files "$root")
if [ "${#cite_files[@]}" -gt 0 ]; then
    while IFS= read -r problem; do [ -z "$problem" ] || advisories+=("$problem"); done < <(
        { printf '%s\n' "$items" | awk -F "$SEP" 'NF { print "D" FS $1 FS $5 }'
          spec_citations "$root" "${cite_files[@]}" | awk -F "$SEP" '{ print "C" FS $1 FS $2 }'; } |
        awk -F "$SEP" '
            $1 == "D" { defined[$2] = 1; if ($3 == "yes") retired[$2] = 1; next }
            { if (!($2 in defined)) { if (!(($2) in undef)) { undef[$2] = $3; order[++n] = $2 } }
              else if (($2 in retired) && $3 !~ /^specs\//) { if (!(($2) in ret)) { ret[$2] = $3; rorder[++m] = $2 } } }
            END {
                for (i = 1; i <= n; i++) print "ID " order[i] " is cited at " undef[order[i]] " but defined nowhere in the spec"
                for (i = 1; i <= m; i++) print "Retired ID " rorder[i] " is still cited by a test at " ret[rorder[i]] "; edit the test or the line"
            }')
fi

# --- References: every link resolves; every spec file is reached from a summary ---------------
# A budget is safe only because a file past it splits and its parent links each piece; a piece
# no summary reaches is lost to readers. A retired file (`retired:` in its heading) is exempt.
# Reach is checked in the 1.1 layout, whose summaries link every piece; a folder link reaches
# the files directly in it. Pieces of observed.md must be linked from it.
# shellcheck disable=SC2016
reach_awk='
    $1 == "F" { n++; file[n] = $2; retired[$2] = $3; next }
    $1 == "E" { to[$2] = to[$2] FS $4 }
    END {
        t = 0
        for (i = 1; i <= n; i++) if (index(" " roots " ", " " file[i] " ")) { seen[file[i]] = 1; q[++t] = file[i] }
        for (h = 1; h <= t; h++) {
            m = split(to[q[h]], d, FS)
            for (j = 2; j <= m; j++) for (i = 1; i <= n; i++)
                if (!(file[i] in seen) && (file[i] == d[j] || (index(file[i], d[j] "/") == 1 && !index(substr(file[i], length(d[j]) + 2), "/")))) { seen[file[i]] = 1; q[++t] = file[i] }
        }
        if (t || always) for (i = 1; i <= n; i++) if (!(file[i] in seen) && !retired[file[i]]) print file[i] " " msg
    }'
reach() { # roots message always links file...: always reports even when no root exists
    local roots="$1" msg="$2" always="$3" edges="$4" file; shift 4
    { for file in "$@"; do
          awk -v f="$file" '/^#/ { r = (tolower($0) ~ /retired:/); exit } END { print "F\037" f "\037" (r ? 1 : 0) }' "$root/$file"
      done
      printf '%s\n' "$edges" | awk 'NF { print "E\037" $0 }'; } |
    awk -F "$SEP" -v roots="$roots" -v msg="$msg" -v always="$always" "$reach_awk"
}
missing_links() { # links
    local file line target
    while IFS="$SEP" read -r file line target; do
        if [ -n "$target" ] && [ ! -e "$root/$target" ]; then
            printf 'Link at %s:%s points to %s, which does not exist\n' "$file" "$line" "$target"
        fi
    done <<< "$1"
}
links="$(spec_links "$root")"
spec_list=(); while IFS= read -r file; do spec_list+=("$file"); done < <(spec_files "$root")
observed=(); for file in "$root"/specs/observed.md "$root"/specs/observed/*.md; do [ -f "$file" ] && observed+=("${file#"$root"/}"); done
observed_links=""; [ "${#observed[@]}" -eq 0 ] || observed_links="$(spec_links "$root" "${observed[@]}")"
archive_links=""; [ ! -f "$root/specs/archive.md" ] || archive_links="$(spec_links "$root" specs/archive.md)"
while IFS= read -r problem; do [ -z "$problem" ] || advisories+=("$problem"); done < <(
    missing_links "$links"; missing_links "$observed_links"; missing_links "$archive_links"
    if [ -d "$root/specs/product" ] && [ "${#spec_list[@]}" -gt 0 ]; then
        reach "specs/product.md specs/architecture.md specs/SPEC.md" \
            "is reached from no summary (product.md, architecture.md or a file they link); give it a line and a link in its parent (spec.md, Layout)" \
            0 "$links" "${spec_list[@]}"
    fi
    if [ -d "$root/specs/observed" ] && [ "${#observed[@]}" -gt 0 ]; then
        reach "specs/observed.md" "is not linked from specs/observed.md; give it a line and a link there" \
            1 "$observed_links" "${observed[@]}"
    fi)

# --- Lifecycle: the current stage, from: markers, the product page's stage columns ----------
stages="$(spec_stages "$root")"
now_next="$(spec_stage_now "$root")"; now="${now_next%%"$SEP"*}"
if [ -f "$root/specs/product/lifecycle.md" ]; then
    known="$(awk "$SPEC_STAGE_AWK"' BEGIN { print stage_rank(ARGV[1]); exit }' "$now")"
    [ "$known" != 0 ] || findings+=("Lifecycle: specs/product/lifecycle.md needs '**Now**: <stage>', one of: $SPEC_STAGE_LIST")
fi
# An advisory: `from:` may also start a source note, such as `from: owner interview`.
while IFS= read -r problem; do [ -z "$problem" ] || advisories+=("$problem"); done < <(
    printf '%s\n' "$stages" | awk -F "$SEP" -v list="$SPEC_STAGE_LIST" "$SPEC_STAGE_AWK"'
        NF && !stage_rank($2) { print "Lifecycle: \"from: " $2 "\" in " $1 " at " $3 " names no stage; stages: " list }')
if [ -n "$stages" ] && [ -z "$now" ]; then
    advisories+=("Lifecycle: items carry from: markers, but specs/product/lifecycle.md names no current stage, so every item counts as needed now")
fi
if [ -n "$now" ]; then
    if [ -n "$stages" ]; then
        reached="$(printf '%s\n' "$stages" | awk -F "$SEP" -v now="$now" "$SPEC_STAGE_AWK"'
            NF && stage_rank($2) && stage_rank($2) <= stage_rank(now) { out = out (out ? ", " : "") $1 }
            END { print out }')"
        [ -z "$reached" ] || advisories+=("Lifecycle: the stage is $now, so remove the reached from: markers of $reached")
    fi
    # product.md may show journeys in stage columns; each must match the journey's own marker.
    if [ -f "$root/specs/product.md" ]; then
        while IFS= read -r problem; do [ -z "$problem" ] || advisories+=("$problem"); done < <(
            { printf '%s\n' "$stages" | awk -F "$SEP" 'NF && $1 ~ /^J-/ { print "S" FS $1 FS $2 }'
              awk "$SPEC_SKIP_AWK"'{ if (spec_skip($0)) next } { print "L" "\037" FNR "\037" $0 }' "$root/specs/product.md"; } |
            awk -F "$SEP" -v now="$now" "$SPEC_STAGE_AWK"'
                $1 == "S" { from[$2] = $3; next }
                $3 !~ /^\|/ { cols = 0; next }
                {
                    n = split($3, cell, "|")
                    if (!cols || $3 ~ /^\|[[:space:]:-]+\|/) {
                        if ($3 ~ /^\|[[:space:]:-]+\|/) next
                        cols = 0
                        for (i = 2; i < n; i++) { h = tolower(cell[i]); gsub(/\*|\(now\)/, "", h); r = stage_rank(h); colrank[i] = r; colname[i] = h; if (r) cols = 1 }
                        next
                    }
                    for (i = 2; i < n; i++) {
                        if (!colrank[i]) continue
                        t = cell[i]
                        while (match(t, /J-[0-9][0-9]+/)) {
                            j = substr(t, RSTART, RLENGTH); t = substr(t, RSTART + RLENGTH)
                            have = (j in from) ? stage_rank(from[j]) : 0
                            if (colrank[i] > stage_rank(now) && have != colrank[i])
                                print "product.md:" $2 " shows " j " in the" colname[i] "column, but its file has " (have ? "from: " from[j] : "no from: marker")
                            else if (colrank[i] <= stage_rank(now) && have > stage_rank(now))
                                print "product.md:" $2 " shows " j " in the" colname[i] "column, but its file says from: " from[j]
                        }
                    }
                }')
    fi
fi

# --- Environments: each stage runs in one the environments topic lists ------------------------
env_files=(); stage_files=()
for path in "$root"/specs/architecture/environments.md "$root"/specs/architecture/environments/*.md; do
    if [ -f "$path" ]; then env_files+=("${path#"$root"/}"); fi
done
for path in "$root"/specs/product/lifecycle.md "$root"/specs/product/lifecycle/*.md; do
    if [ -f "$path" ]; then stage_files+=("${path#"$root"/}"); fi
done
if [ "${#env_files[@]}" -gt 0 ] && [ "${#stage_files[@]}" -gt 0 ]; then
    while IFS= read -r problem; do [ -z "$problem" ] || advisories+=("$problem"); done < <(
        cd "$root" && awk "$SPEC_SKIP_AWK"'
            # A name as written: no emphasis, code, link target, or note after it (`TEST (early)`).
            function plain(s) {
                gsub(/\*|`/, "", s); sub(/\]\([^)]*\)/, "", s); gsub(/\[|\]/, "", s)
                gsub(/^[[:space:]_]+|[[:space:]_]+$/, "", s)
                sub(/[[:space:]]+(\(|—|–).*$/, "", s); sub(/:([[:space:]].*)?$/, "", s); return s
            }
            # Whether text names an environment, as a whole word spelled as the topic spells it.
            # A neighbour is tested with index(), never a regex: macOS awk counts bytes, and a
            # regex over the lone byte of a multibyte character (TEST—early) aborts it.
            function names(text,   s, e, at, pre, post, w) {
                w = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-"
                for (e in env) {
                    s = text
                    while ((at = index(s, e)) > 0) {
                        pre = at > 1 ? substr(s, at - 1, 1) : ""; post = substr(s, at + length(e), 1)
                        if (!(pre != "" && index(w, pre)) && !(post != "" && index(w, post))) return 1
                        s = substr(s, at + length(e))
                    }
                }
                return 0
            }
            # A stage Environment line, with its wrapped continuation, once it is complete.
            function check() {
                if (!open) return
                open = 0
                if (tolower(value) ~ /^none([^a-z]|$)/ || value ~ /^</ || names(value)) return
                printf "Environments: %s at %s:%d runs in none of the environments specs/architecture/environments.md lists (%s); name one, or add it there\n", (vstage != "" ? "the " vstage " stage" : "a stage"), vfile, vline, list
            }
            { sub(/\r$/, "") }
            FNR == 1 { check(); fence = 0; comment = 0; table = 0; stage = "" }
            { if (spec_skip($0)) next }
            # The environments: the first cells of the table headed `| Environment |`.
            FILENAME ~ /^specs\/architecture\/environments/ {
                if ($0 !~ /^\|/) { table = 0; next }
                split($0, cell, "|"); name = plain(cell[2])
                if (tolower(name) == "environment") { table = 1; headed = 1; next }
                if (table && name !~ /^:?-+:?$/ && name !~ /^</ && name != "") {
                    if (!(name in env)) list = list (list ? ", " : "") name
                    env[name] = 1
                }
                next
            }
            list == "" { exit }
            open && /^[[:space:]]+[^-*+[:space:]]/ { t = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", t); value = value " " t; next }
            { check() }
            /^##[[:space:]]/ { stage = $0; sub(/^##[[:space:]]+/, "", stage); sub(/[[:space:]]*\([^)]*\)[[:space:]]*$/, "", stage); next }
            /^[[:space:]]*([-*+][[:space:]]+)?\*\*Environment(\*\*:|:\*\*)/ {
                value = $0; sub(/^[^:]*:(\*\*)?[[:space:]]*/, "", value); gsub(/[[:space:]]+$/, "", value)
                open = 1; vstage = stage; vfile = FILENAME; vline = FNR
            }
            END {
                check()
                if (list == "" && headed) print "Environments: the | Environment | table in specs/architecture/environments.md holds only placeholders; name each environment, so stages can name where they run"
                else if (list == "") print "Environments: specs/architecture/environments.md has no table headed | Environment |, so no stage can name where it runs"
            }
        ' "${env_files[@]}" "${stage_files[@]}")
fi

# --- Trace: spec to code, plans, retired IDs, allocation, change records -----------------------
# One advisory per check: its count and first locations. --json counts each check by its code.
trace_json=""
trace() { # code message fix rows (one location each)
    local out n
    out="$(printf '%s\n' "$4" | awk 'NF { if (++n <= 5) at = at (n > 1 ? ", " : "") $0 }
        END { print n + 0 "\037" at (n > 5 ? " and " n - 5 " more" : "") }')"
    n="${out%%"$SEP"*}"; trace_json="${trace_json:+$trace_json,}\"$1\":$n"
    [ "$n" -eq 0 ] || advisories+=("$2 ($n): ${out#*"$SEP"}; $3")
}
pick() { printf '%s\n' "$1" | awk -F "$SEP" -v k="$2" '$1 == k { print $2 }'; } # rows kind -> rest
# A path after a Code: label that is not in the repository. Judged: a code span holding a "/",
# a bare word whose first directory exists, and a file name (`b.py`) once a path named before it
# in the same item gives it a directory; a path also resolves in the directory of one before it.
# Placeholders, globs, commands, URLs, absolute paths and org/repo:path are not judged; a
# #anchor or :line suffix is dropped.
code_paths_missing() {
    local kind path where prev="" bases="" base found
    local line_re='^(.*):[0-9]+(-[0-9]+)?$' ext_re='\.[A-Za-z][A-Za-z0-9]*$' odd_re="[][:space:]<>*?{}\$|=:'\"[]"
    while IFS="$SEP" read -r kind path where; do
        [ "$where" = "$prev" ] || { prev="$where"; bases=""; }
        path="${path#./}"; path="${path%%#*}"
        while :; do case "$path" in *[.,:\;!?/]) path="${path%?}" ;; *) break ;; esac; done
        if [[ "$path" =~ $line_re ]]; then path="${BASH_REMATCH[1]}"; fi
        case "$path" in ''|/*|~*|-*) continue ;; esac
        if [[ "$path" =~ $odd_re ]]; then continue; fi
        case "$kind" in
            span) case "$path" in */*) ;; *) [[ "$path" =~ $ext_re ]] || continue ;; esac ;;
            *) [ -e "$root/${path%%/*}" ] || continue ;;
        esac
        found=""
        if [ -e "$root/$path" ]; then found="$path"
        else
            while IFS= read -r base; do
                [ -n "$base" ] && [ -e "$root/$base/$path" ] && { found="$base/$path"; break; }
            done <<< "$bases"
        fi
        if [ -n "$found" ]; then
            [ -d "$root/$found" ] || case "$found" in */*) found="${found%/*}" ;; *) found=. ;; esac
            bases="$bases$found"$'\n'
        elif [ -n "$bases" ] || [ "${path#*/}" != "$path" ]; then
            printf '%s at %s\n' "$path" "$where"
        fi
    done < <(spec_code_paths "$root")
}
trace code-path "Code path not in the repository" "name repo-relative paths that exist (spec.md, Writing)" "$(code_paths_missing)"

# planned: <change> names an open change record (here, or in a worktree unless the log closed
# it), else a closed or unknown one. A live item's marker naming no change number (M1, 12) is
# unknown too; org/repo#n names another repository's change.
closed_ids=" $( [ ! -f "$root/specs/log.md" ] || sed -n 's/^- [0-9-]* \([^ :]*\):.*/\1/p' "$root/specs/log.md" | tr '\n' ' ')"
open_ids=" "
while IFS="$SEP" read -r path _ loc; do
    for file in "$path"/specs/changes/*.md; do
        [ -f "$file" ] || continue
        id="${file##*/}"; id="${id%.md}"
        [ "$loc" = . ] || case "$closed_ids" in *" $id "*) continue ;; esac
        open_ids="$open_ids$id "
    done
done < <(spec_checkouts "$root")
planned_closed=""; planned_unknown=""
while IFS="$SEP" read -r id where; do
    [ -n "$id" ] || continue
    case "$open_ids" in *" ${id%%-*}-"*) continue ;; esac
    case "$closed_ids" in
        *" ${id%%-*}-"*) planned_closed+="${id%-} at $where"$'\n' ;;
        *) planned_unknown+="${id%-} at $where"$'\n' ;;
    esac
done < <(spec_planned_at "$root")
xrepo_re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(#[0-9]+)?$'
while IFS="$SEP" read -r _ _ _ target retired _ where; do
    [ "$retired" = no ] || continue
    target="${target//[\`*]/}"
    while [ "${target#_}" != "$target" ]; do target="${target#_}"; done
    while [ "${target%_}" != "$target" ]; do target="${target%_}"; done
    case "$target" in ''|[0-9][0-9][0-9]*) continue ;; esac
    [[ "$target" =~ $xrepo_re ]] || planned_unknown+="$target at $where"$'\n'
done <<< "$items"
trace planned-closed "Planned for a closed change" "specs/log.md closed it: remove the marker if it was built, or re-plan it to an open change" "$planned_closed"
trace planned-unknown "Planned for no open change" "point it at an open change record (new-change.sh opens one) or remove the marker" "$planned_unknown"

# Spec text by item, as spec_items reads it. The program defines flush(), which sees the item's
# line[1..lines], at[1..lines] and text, and newfile(); its own rules run after these.
# shellcheck disable=SC2016
ITEM_AWK='
    function add() { line[++lines] = $0; at[lines] = FILENAME ":" FNR; text = text " " $0 }
    FNR == 1 { flush(); lines = 0; text = ""; fence = 0; comment = 0; newfile() }
    { if (spec_skip($0)) { flush(); lines = 0; text = ""; next } }
    /^[[:space:]]*$/ { flush(); lines = 0; text = ""; next }
    /^[[:space:]]*([-*+]|[0-9]+\.)[[:space:]]/ || /^(#|\|)/ { flush(); lines = 0; text = "" }
    { add() }
    END { flush() }'

# A retired ID cited in the spec, once per file. Not judged: architecture/retired and decision
# records (history), a file whose heading retires it, and an item that says retired, superseded
# or replaced (a retiring line, or history).
cited_in=(); retired_in=(); for file in ${spec_list[@]+"${spec_list[@]}"}; do
    case "$file" in specs/architecture/retired.md|specs/architecture/retired/*) continue ;; esac
    cited_in+=("$file")
    case "$file" in specs/decisions/*|specs/architecture/decisions.md|specs/architecture/decisions/*) ;; *) retired_in+=("$file") ;; esac
done
retired_cited=""
if [ "${#retired_in[@]}" -gt 0 ]; then
    retired_cited="$({ printf '%s\n' "$items" | awk -F "$SEP" 'NF && $5 == "yes" { print "R" FS $1 }'
        (cd "$root" && awk "$SPEC_SKIP_AWK $SPEC_ID_AWK $ITEM_AWK"'
            function flush(   i) {
                if (gone || tolower(text) ~ /retired|supersed|replac/) return
                for (i = 1; i <= lines; i++) spec_ids(line[i], "C\037" at[i])
            }
            function newfile() { gone = 0; head = 1 }
            head && /^#/ { head = 0; gone = (tolower($0) ~ /retired:/) }' "${retired_in[@]}"); } |
        awk -F "$SEP" '$1 == "R" { r[$2] = 1; next }
            $2 == "C" && ($1 in r) { f = $3; sub(/:[0-9]+$/, "", f); if (!seen[$1, f]++) print $1 " at " $3 }')"
fi
trace retired-cited "Retired ID cited in the spec" "cite what replaced it, or drop the reference" "$retired_cited"

# Allocation: a live R or Q needed now (no later from: stage) that no part or architecture file
# cites; a part whose parts-table row and Why it exists cite no J, R or Q. A range (R-03 to R-07)
# cites every ID in it. An item's own text never allocates it (SPEC.md holds both).
alloc=(); for file in ${cited_in[@]+"${cited_in[@]}"}; do
    case "$file" in specs/SPEC.md|specs/architecture*|specs/parts/*|specs/decisions/*) alloc+=("$file") ;; esac
done
allocation="$({ printf '%s\n' "$items" | awk 'NF { print "T\037" $0 }'
    printf '%s\n' "$stages" | awk 'NF { print "S\037" $0 }'
    spec_part_headings "$root" | awk 'NF { print "H\037" $0 }'
    [ "${#alloc[@]}" -eq 0 ] || (cd "$root" && awk "$SPEC_SKIP_AWK $ITEM_AWK"'
        function cites(s, where,   w, pre, tok, post, end, lo, hi, k, pad) {
            w = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_"
            while (match(s, /[JRQ]-[0-9][0-9]+/)) {
                pre = RSTART > 1 ? substr(s, RSTART - 1, 1) : ""
                tok = substr(s, RSTART, RLENGTH); post = substr(s, RSTART + RLENGTH, 1)
                s = substr(s, RSTART + RLENGTH)
                if ((pre != "" && index(w ".", pre)) || (post != "" && index(w, post))) continue
                print "C\037" tok "\037" where
                if (!match(s, /^[[:space:]]*(to|through|-|–|—|\.\.)[[:space:]]*[JRQ]-[0-9][0-9]+/)) continue
                end = substr(s, RSTART, RLENGTH); match(end, /[JRQ]-[0-9][0-9]+$/); end = substr(end, RSTART)
                if (substr(end, 1, 1) != substr(tok, 1, 1)) continue
                lo = substr(tok, 3) + 0; hi = substr(end, 3) + 0; pad = length(tok) - 2
                if (lo > hi) { k = lo; lo = hi; hi = k }
                for (k = lo + 1; k < hi && k <= lo + 99; k++) print "C\037" sprintf("%s-%0" pad "d", substr(tok, 1, 1), k) "\037" where
            }
        }
        function flush(   f) { if (lines) { f = at[1]; sub(/:[0-9]+$/, "", f); cites(text, at[1] "\037" (why ? f : "")) } }
        function newfile() { why = 0; top = (FILENAME ~ /^specs\/parts\/[^\/]+\.md$/) }
        /^#/ { why = top && tolower($0) ~ /^##[[:space:]]+why/ }' "${alloc[@]}"); } |
    awk -F "$SEP" -v now="$now" "$SPEC_STAGE_AWK"'
        $1 == "T" { at[$2] = $8; if ($6 == "yes") gone[$2] = 1
                    else if ($2 ~ /^[RQ]-/) need[++n] = $2
                    else if ($2 ~ /^P[0-9]+$/ && !($2 in listed)) { listed[$2] = 1; part[++m] = $2 }
                    next }
        $1 == "S" { from[$2] = $3; next }
        $1 == "H" { if ($2 ~ /^specs\/parts\/[^\/]+\.md$/ && $3 != "") { file[$3] = $2; if (!($3 in listed)) { listed[$3] = 1; part[++m] = $3 } } next }
        $1 == "C" { if ($3 != at[$2]) cited[$2] = 1; if ($4 != "") why[$4] = 1; row[$3] = 1 }
        END {
            for (i = 1; i <= n; i++) {
                id = need[i]
                if (now != "" && (id in from) && stage_rank(from[id]) > stage_rank(now)) continue
                if (!(id in cited)) print "U\037" id " at " at[id]
            }
            for (i = 1; i <= m; i++) {
                p = part[i]
                if ((p in gone) || ((p in at) && (at[p] in row)) || ((p in file) && (file[p] in why))) continue
                print "X\037" p " at " ((p in at) ? at[p] : file[p])
            }
        }')"
trace unallocated "R or Q no part or architecture file cites" "allocate it to a part, or ask the owner whether it is still needed" \
    "$(pick "$allocation" U)"
trace part-need "Part citing no journey, R or Q" "say in Why it exists which J, R and Q need it, or ask the owner (spec.md, Parts)" \
    "$(pick "$allocation" X)"

# Change records are not spec files: one restating a spec item, or citing (once per record) an ID
# that neither the spec, a record's own item, nor a record's Spec edits section (IDs a change
# adds) names.
change_files=(); for file in "$root"/specs/changes/*.md; do [ -f "$file" ] && change_files+=("${file#"$root"/}"); done
change_ids=""
if [ "${#change_files[@]}" -gt 0 ]; then
    change_ids="$({ printf '%s\n' "$items" | awk -F "$SEP" 'NF { print "D" FS $1 FS $7 }'
        spec_items "$root" "${change_files[@]}" | awk -F "$SEP" 'NF { print "N" FS $1 FS $7 }'
        (cd "$root" && awk "$SPEC_SKIP_AWK $SPEC_ID_AWK"'
            FNR == 1 { fence = 0; comment = 0; edits = 0 }
            { if (spec_skip($0)) next }
            /^## / { edits = ($0 ~ /^##[[:space:]]+Spec edits/) }
            { spec_ids($0, FILENAME ":" FNR "\037" edits) }' "${change_files[@]}"); } |
        awk -F "$SEP" '$1 == "D" { spec[$2] = $3; next }
            $1 == "N" { own[$2] = 1; if ($2 in spec) print "R" FS $2 " at " $3 " (spec: " spec[$2] ")"; next }
            { if ($3 == 1) own[$1] = 1; id[++n] = $1; at[n] = $2 }
            END { for (i = 1; i <= n; i++) {
                f = at[i]; sub(/:[0-9]+$/, "", f)
                if (!(id[i] in spec) && !(id[i] in own) && !seen[id[i], f]++) print "U" FS id[i] " at " at[i] } }')"
fi
trace change-restates "Change record restates a spec item" "cite its ID and edit the spec instead" \
    "$(pick "$change_ids" R)"
trace change-undefined "Change record cites an ID defined nowhere" "list it under Spec edits, define it in the spec, or fix the reference" \
    "$(pick "$change_ids" U)"

# --- Records and inbox -----------------------------------------------------------------------
while IFS="$SEP" read -r line type name who _ _ _ date until _ reason; do
    [ -n "$line" ] || continue
    case "$type" in
        INVALID) findings+=("Malformed record at specs/records.md:$line: $reason") ;;
        HOLD|WAIVER)
            if spec_is_date "$until" && [ "$(spec_days_between "$until" "$today")" -gt 0 ]; then
                advisories+=("Expired $type $name (owner $who, until $until): it no longer applies; the owner renews or removes it")
            fi ;;
    esac
done < <(spec_records "$root")
open_count=0; oldest=""; undisposed=0; unparsed=""; oneline=0; resolved=0; processing=0
while IFS="$SEP" read -r line date who state _ _ _ _ _ _ problems; do
    [ -n "$line" ] || continue
    [ "$state" = unparsed ] || [ "$(sed -n "${line}p" "$root/specs/inbox.md" | cut -c1-4)" = "### " ] || oneline=$((oneline + 1))
    case "$state" in
        open) open_count=$((open_count + 1)); { [ -n "$oldest" ] && [[ ! "$date" < "$oldest" ]]; } || oldest="$date" ;;
        processing) processing=$((processing + 1)) ;;
        unknown) undisposed=$((undisposed + 1)) ;;
        folded|declined|deferred) resolved=$((resolved + 1)) ;;
        unparsed) unparsed="${unparsed:+$unparsed, }$line" ;;
    esac
    if [ -n "$problems" ]; then
        case "$problems" in
            *duplicate*|*'answer revision mismatch'*) findings+=("Owner inbox specs/inbox.md:$line: $problems") ;;
            *) advisories+=("Owner inbox specs/inbox.md:$line: $problems; reconcile with /prdkit-inbox") ;;
        esac
    fi
done < <(spec_inbox "$root")
[ "$open_count" -eq 0 ] || advisories+=("Owner inbox: $open_count open item(s), oldest from $oldest ($(spec_days_between "$oldest" "$today") days)")
[ "$processing" -eq 0 ] || advisories+=("Owner inbox: $processing item(s) awaiting agent processing, not another owner answer; incorporate and verify spec/policy, provenance and obligations with /prdkit-inbox")
[ "$resolved" -eq 0 ] || advisories+=("Owner inbox: $resolved resolved-state item(s) retained; verify canonical decisions, provenance and remaining obligations, then remove them (spec.md, Resolve owner answers)")
[ "$undisposed" -eq 0 ] || advisories+=("Owner inbox: $undisposed item(s) without an open, processing, folded, declined or deferred disposition")
[ -z "$unparsed" ] || advisories+=("Owner inbox: specs/inbox.md line(s) $unparsed are not inbox items (a '### <title>' heading, then '*<YYYY-MM-DD> · <owner|agent> · <disposition>*'), so status skips them")
[ "$oneline" -eq 0 ] || advisories+=("Owner inbox: $oneline item(s) in the one-line form; rewrite each as a heading with its meta line and options (.prdkit/templates/inbox-template.md)")

# --- Local machine paths: tracked docs, specs and agent context use repo-relative paths -------
# A machine's own path (/home/<user>, /Users/<user>, C:\Users\<user>) is flagged; a generic ~/
# default is not, nor is a `>` quote: owner words stay verbatim. 0.x folders and a leftover
# specs/archive/, each its own advisory until removed, keep their history as it was.
path_files=()
while IFS= read -r file; do path_files+=("$file"); done < <(
    if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "$root" ls-files -- '*.md' ':(exclude)specs/archive/**' ':(exclude)specs/features/**' \
            ':(exclude).prdkit/templates/**' ':(exclude).prdkit/workflows/**' ':(exclude).product-kit/**'
    else
        spec_files "$root"
        for file in specs/inbox.md specs/records.md specs/observed.md specs/log.md \
                    .prdkit/memory/constitution.md AGENTS.md CLAUDE.md; do
            [ -f "$root/$file" ] && printf '%s\n' "$file"
        done
    fi)
if [ "${#path_files[@]}" -gt 0 ]; then
    present=(); for file in "${path_files[@]}"; do [ -f "$root/$file" ] && present+=("$file"); done
    [ "${#present[@]}" -gt 0 ] || present=(/dev/null)
    local_paths="$(cd "$root" && awk '
        /^[[:space:]]*>/ { next }
        /(^|[^A-Za-z0-9_.-])(\/home\/[A-Za-z0-9_]|\/Users\/[A-Za-z0-9_]|[A-Za-z]:\\Users\\)/ {
            if (++n <= 8) at = at (n > 1 ? ", " : "") FILENAME ":" FNR }
        END { if (n > 8) at = at " and " n - 8 " more"; print at }' "${present[@]}" 2>/dev/null)"
    [ -z "$local_paths" ] || advisories+=("Local machine path at $local_paths: write paths relative to the repository, and org/repo plus a path for another repository")
fi

# --- Closed changes reach the log: a deleted change record needs its specs/log.md line ------------
if git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    unlogged=""; through="$(spec_archive_log_through "$root")"
    while IFS= read -r id; do
        [ -n "$id" ] && [ ! -f "$root/specs/changes/$id.md" ] || continue
        # Entries condensed into specs/archive.md (compact.md) left the log on purpose.
        case "${id%%-*}" in ''|*[!0-9]*) ;; *) [ "$((10#${id%%-*}))" -gt "${through:-0}" ] || continue ;; esac
        grep -q "^- [0-9-]* $id:" "$root/specs/log.md" 2>/dev/null || unlogged="${unlogged:+$unlogged, }$id"
    done < <(git -C "$root" log -M --diff-filter=D --name-only --format= -- 'specs/changes/*.md' 2>/dev/null |
        sed -n 's|^specs/changes/\(.*\)\.md$|\1|p' | sort -u)
    [ -z "$unlogged" ] || findings+=("Closed without a specs/log.md line: $unlogged; the change that deletes its record adds '- <date> <id>: <what changed>' to specs/log.md")
    # A reviewed record still on the default branch and in this checkout: its change merged
    # without closing. A branch that closes it (record deleted, log line added) is not flagged.
    base="$(spec_default_branch "$root")"
    if [ -n "$base" ] && spec_objects_local "$root"; then
        named=" $(spec_open_changes "$root" | awk -F "$SEP" '{ v = $7; gsub(/`/, "", v); if (v != "") printf "%s ", v }')"
        unclosed=""; n=0
        while IFS= read -r cid; do
            [ -f "$root/specs/changes/$cid.md" ] || continue
            case "$named" in *" $cid "*) continue ;; esac
            n=$((n + 1)); [ "$n" -gt 8 ] || unclosed="${unclosed:+$unclosed, }$cid"
        done < <(spec_unclosed_changes "$root" "$base")
        [ "$n" -le 8 ] || unclosed="$unclosed and $((n - 8)) more"
        [ "$n" -eq 0 ] || advisories+=("Merged without closing: $unclosed passed review and are still on $base, with no child or outcome checkpoint keeping them open; close each in the next relevant PR, or give one that spans PRs an outcome checkpoint (.prdkit/workflows/review.md, Closing)")
    fi
fi

# --- Raw evidence under specs/ (it belongs in CI, the PR or .prdkit/cache/evidence/) -------------
if $in_git; then
    raw_count=0; raw_bytes=0; raw_first=""
    while IFS= read -r -d '' path; do
        case "$path" in
            *.md) continue ;;
            */reviews/*|*/results/*|*/evidence/*|*.patch|*.trx|*.log) ;;
            *) continue ;;
        esac
        raw_count=$((raw_count + 1)); [ -n "$raw_first" ] || raw_first="$path"
        if [ -f "$root/$path" ] && [ ! -L "$root/$path" ]; then
            raw_bytes=$((raw_bytes + $(wc -c < "$root/$path" | tr -d ' ')))
        fi
    done < <(git -C "$root" ls-files -z -- specs 2>/dev/null || true)
    [ "$raw_count" -eq 0 ] || advisories+=("Raw evidence tracked under specs/: $raw_count file(s), $((raw_bytes / 1024)) KB, e.g. $raw_first. Keep packages and outputs in .prdkit/cache/evidence/ or CI and link them; untrack with git rm --cached")
fi

# --- Agent context and agent definitions ---------------------------------------------------------
while IFS= read -r advisory; do [ -z "$advisory" ] || advisories+=("$advisory"); done < <(context_budget_advisories "$root")
# Agent context loads on every turn: a path into 0.x folders or an archive the cutover removed
# sends agents to files that are gone; history questions go to specs/archive.md. Only a plain
# repo-relative path counts, `./` and an `@` import too: not one after ":", "/" or a word
# character (a git show pointer, a URL or absolute path, another repository's owner/repo), not
# a placeholder or glob (<, *, {), not a bare folder (a rule such as "never recreate
# specs/features/"). A function: bash 3.2 misparses case patterns inside a process substitution.
context_0x_paths() { # file
    local token path
    { grep -oE '(\./|[^[:space:]])?specs/(archive|product-spec|targets|features)/[^[:space:]]*' "$1" 2>/dev/null || true; } |
        while IFS= read -r token; do
            case "$token" in
                specs/*) path="$token" ;;
                ./specs/*) path="${token#./}" ;;
                *) path="${token#?}"; case "${token%"$path"}" in :|/|[[:alnum:]_]) continue ;; esac ;;
            esac
            while :; do
                case "$path" in
                    *'`'|*'*'|*.|*,|*';'|*:|*')'|*']'|*'"'|*"'"|*'!'|*'?'|*'>') path="${path%?}" ;;
                    *) break ;;
                esac
            done
            case "$path" in *'<'*|*'*'*|*'{'*) continue ;; esac
            path="${path%%[!A-Za-z0-9._/-]*}"
            case "$path" in specs/archive/|specs/product-spec/|specs/targets/|specs/features/) ;; *) printf '%s\n' "$path" ;; esac
        done | LC_ALL=C sort -u
}
stale_paths=""
for name in $CONTEXT_AGENT_FILES; do
    [ -f "$root/$name" ] || continue
    if $in_git && ! git -C "$root" ls-files --error-unmatch -- "$name" >/dev/null 2>&1; then continue; fi
    while IFS= read -r path; do
        [ -e "$root/$path" ] || stale_paths="${stale_paths:+$stale_paths, }$name: $path"
    done < <(context_0x_paths "$root/$name")
done
[ -z "$stale_paths" ] || advisories+=("Agent context names removed 0.x paths ($stale_paths); point it at the current spec, and history questions at specs/archive.md; qualify paths in other repositories as owner/repo:path (.prdkit/workflows/compact.md)")
roster="$root/.prdkit/memory/agents.md"
for def in "$root"/.prdkit/agents/*.md; do
    [ -f "$def" ] || continue
    name="$(basename "$def" .md)"
    if [ ! -f "$roster" ] || ! grep -qF -- "$name" "$roster"; then
        findings+=("Agent '$name': neutral definition has no entry in .prdkit/memory/agents.md")
    fi
    for harness in $(at_targets "$root" "$def"); do
        [ -f "$root/.$harness/agents/$name.md" ] || findings+=("Agent '$name': no projection in .$harness/agents/ (render-agents.sh, or /prdkit-configure)")
    done
done
while IFS= read -r finding; do [ -z "$finding" ] || findings+=("$finding"); done < <(agent_tier_findings "$root")
# A worktree directory removed without `git worktree remove` leaves a prunable registration
# that a resuming session cannot re-enter. Detect only; pruning is cleanup-change.sh's job.
if $in_git; then
    wt_path=""
    while IFS= read -r line; do
        case "$line" in
            "worktree "*) wt_path="${line#worktree }" ;;
            "prunable"*) [ -z "$wt_path" ] || advisories+=("Stale worktree registration: $wt_path (directory gone; clear it with .prdkit/scripts/bash/cleanup-change.sh --prune)") ;;
        esac
    done < <(git -C "$root" worktree list --porcelain 2>/dev/null || true)
fi

if $strict; then findings+=(${advisories[@]+"${advisories[@]}"}); advisories=(); fi
result=pass; [ "${#findings[@]}" -eq 0 ] || result=fail
if $json; then
    printf '{"result":"%s","findings":%s,"advisories":%s,"trace":{%s},"strict":%s,"readiness":"not-evaluated"' \
        "$result" "$(json_array ${findings[@]+"${findings[@]}"})" "$(json_array ${advisories[@]+"${advisories[@]}"})" "$trace_json" "$strict"
    printf ',"adoption":%s' "$(diagnostic_adoption "$root")"
    if $inventory; then printf ',"configuration":%s' "$(diagnostic_configuration "$root")"; fi
    printf '}\n'
else
    printf 'Product-Kit doctor: %s\n' "$result"
    diagnostic_adoption "$root" --text
    for reason in ${findings[@]+"${findings[@]}"}; do printf '  %s\n' "$reason"; done
    for reason in ${advisories[@]+"${advisories[@]}"}; do printf '  advisory: %s\n' "$reason"; done
    [ "${#advisories[@]}" -eq 0 ] || printf 'Advisories do not fail doctor; --strict makes them failing findings.\n'
    printf 'No repairs performed. A clean report is not readiness.\n'
    if $inventory; then
        printf 'Effective configuration (JSON; null means unknown, not a default):\n'
        diagnostic_configuration "$root"; printf '\n'
    fi
fi
[ "$result" = pass ]
