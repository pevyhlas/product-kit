#!/usr/bin/env bash
# Script-safety guards: regressions here destroy user data or defeat worktree
# isolation, so each fix from the 2026-08 hardening pass gets a behavioral test:
#   - new-change.sh must not silently mutate a dirty main checkout when
#     worktree creation fails, and must surface git's actual error
#   - JSON emitters must escape quotes/backslashes in interpolated values
#   - ledger-emit.sh must read config from the ## Configuration section, not
#     the first "backend:"-shaped line anywhere in the policy file
#   - build-review-package.sh must reject path-escaping change ids and claim
#     round directories atomically
#   - no awk program may run a regex over one byte of a multibyte character:
#     macOS awk aborts on it in a UTF-8 locale (status, doctor and bounds did)
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ---------------------------------------------------------------------------
it "json_escape escapes quotes and backslashes"
# shellcheck source=/dev/null
source "$PK_ROOT/scripts/common.sh"
assert_eq 'a\"b\\c' "$(json_escape 'a"b\c')" "quote and backslash escaped"
assert_eq 'plain' "$(json_escape 'plain')" "plain string unchanged"

it "JSON arrays round-trip every Bash-representable control and Unicode through a strict parser"
controls=""
for ((code=1; code<32; code++)); do
    printf -v octal '%03o' "$code"
    printf -v character '%b' "\\$octal"
    controls="$controls$character"
done
value=$'quote" slash\\ literal\\u0001 café → 🧪\177'"$controls"$'\n\n'
JSON_TMP="$(mktemp -d)"; track_tmp "$JSON_TMP"
for locale in C "${LC_ALL:-${LANG:-C}}"; do
    LC_ALL="$locale" json_array "$value" '' "$value" > "$JSON_TMP/out" 2> "$JSON_TMP/err"
    assert_eq 0 "$?" "emitter succeeds under $locale"
    run jq -e --arg expected "$value" '. == [$expected, "", $expected]' "$JSON_TMP/out"
    assert_eq 0 "$STATUS" "strict parser preserves controls, Unicode, empty strings and order: $OUTPUT"
    assert_eq '' "$(cat "$JSON_TMP/err")" 'no diagnostics in a successful JSON channel'
done
assert_eq '[]' "$(json_array)" 'empty array remains valid'

# ---------------------------------------------------------------------------
PROJ="$(make_inited_project)"; track_tmp "$PROJ"
PROJ="$(cd "$PROJ" && pwd -P)"
CNF="$PROJ/.prdkit/scripts/bash/new-change.sh"
cd "$PROJ" || exit 1

# ---------------------------------------------------------------------------
it "worktree failure on a clean tree falls back loudly with git's real error"
git -C "$PROJ" add -A >/dev/null 2>&1
git -C "$PROJ" commit -qm "wip commit so the tracked tree is clean" >/dev/null 2>&1
mkdir -p "$PROJ/.worktrees/091-stale"
echo junk > "$PROJ/.worktrees/091-stale/leftover.txt"
run bash "$CNF" --json --number 91 --short-name "stale" "stale worktree dir"
assert_eq 0 "$STATUS" "clean-tree fallback still succeeds"
assert_contains "$OUTPUT" "Could not create a worktree" "warns about the worktree failure"
assert_contains "$OUTPUT" "091-stale" "surfaces git's actual error (mentions the path)"
assert_contains "$OUTPUT" "Falling back" "fallback is loud, not silent"
git -C "$PROJ" checkout -q - >/dev/null 2>&1 || git -C "$PROJ" checkout -q master >/dev/null 2>&1
rm -f "$PROJ/specs/changes/091-stale.md"

it "worktree failure on a dirty tree refuses to mutate the main checkout"
BEFORE_BRANCH="$(git -C "$PROJ" branch --show-current)"
mkdir -p "$PROJ/.worktrees/092-dirty"
echo junk > "$PROJ/.worktrees/092-dirty/leftover.txt"
echo "uncommitted tracked change" >> "$PROJ/.gitkeep"
run bash "$CNF" --json --number 92 --short-name "dirty" "dirty tree case"
assert_eq 1 "$STATUS" "exits non-zero instead of switching a dirty checkout"
assert_contains "$OUTPUT" "uncommitted changes" "explains the refusal"
assert_eq "$BEFORE_BRANCH" "$(git -C "$PROJ" branch --show-current)" "main checkout branch unchanged"
assert_contains "$(cat "$PROJ/.gitkeep")" "uncommitted tracked change" "WIP left untouched"
git -C "$PROJ" checkout -q -- .gitkeep

it "automatic fallback refuses untracked-only work without changing its checkout or content"
mkdir -p "$PROJ/.worktrees/093-untracked" "$PROJ/specs"
printf 'occupied\n' > "$PROJ/.worktrees/093-untracked/leftover.txt"
printf 'untracked owner direction\n' > "$PROJ/specs/inbox.md"
BEFORE_HEAD="$(git rev-parse HEAD)"
BEFORE_INDEX="$(git ls-files --stage)"
assert_eq '' "$(git status --porcelain --untracked-files=no)" "fixture has no tracked modifications"
run bash "$CNF" --json --number 93 --short-name untracked "untracked-only fallback"
assert_eq 1 "$STATUS" "refuses untracked-only fallback"
assert_contains "$OUTPUT" 'tracked or untracked' "refusal explains that untracked work counts"
assert_eq "$BEFORE_BRANCH" "$(git branch --show-current)" "current branch preserved"
assert_eq "$BEFORE_HEAD" "$(git rev-parse HEAD)" "HEAD commit preserved"
assert_eq "$BEFORE_INDEX" "$(git ls-files --stage)" "index preserved"
assert_eq 'untracked owner direction' "$(cat specs/inbox.md)" "untracked content preserved"
assert_eq absent "$([ -e specs/changes/093-untracked.md ] && echo present || echo absent)" "refusal creates no record"

it "explicit --no-worktree carries staged, unstaged and untracked work without altering it"
printf 'unstaged tracked edit\n' > .gitkeep
printf 'staged edit\n' > staged.txt
git add staged.txt
BEFORE_INDEX="$(git ls-files --stage)"
run bash "$CNF" --json --no-worktree --number 94 --short-name explicit "explicit in-place change"
assert_eq 0 "$STATUS" "explicit override still succeeds"
assert_eq 094-explicit "$(git branch --show-current)" "explicitly switches the current checkout"
assert_eq "$BEFORE_HEAD" "$(git rev-parse HEAD)" "does not commit existing work"
assert_eq "$BEFORE_INDEX" "$(git ls-files --stage)" "does not stage or unstage existing work"
assert_eq 'unstaged tracked edit' "$(cat .gitkeep)" "unstaged content preserved"
assert_eq 'staged edit' "$(cat staged.txt)" "staged content preserved"
assert_eq 'untracked owner direction' "$(cat specs/inbox.md)" "untracked content preserved"
assert_file specs/changes/094-explicit.md "new record created"

# ---------------------------------------------------------------------------
it "ledger-emit.sh reads config from ## Configuration, not the first match anywhere"
LPROJ="$(mktemp -d)"; track_tmp "$LPROJ"
mkdir -p "$LPROJ/.prdkit/memory" "$LPROJ/.prdkit/scripts/bash"
cp "$PK_ROOT/scripts/ledger-emit.sh" "$PK_ROOT/scripts/common.sh" "$PK_ROOT/scripts/json-lib.sh" "$LPROJ/.prdkit/scripts/bash/"
git -C "$LPROJ" init -q
git -C "$LPROJ" config user.email t@example.com
git -C "$LPROJ" config user.name test
cat > "$LPROJ/adapter.sh" <<EOF
#!/usr/bin/env bash
cat > "$LPROJ/adapter-received.json"
EOF
chmod +x "$LPROJ/adapter.sh"
cat > "$LPROJ/.prdkit/memory/task-ledger.md" <<EOF
# Task Ledger

Documentation example (must NOT be parsed as config):

- backend: none

## Configuration

- backend: command
- command: ./adapter.sh
- events: all
- mode: best-effort

## Fields

- backend: also-not-config
EOF
run bash -c 'cd "$1" && echo '\''{"event":"test"}'\'' | bash .prdkit/scripts/bash/ledger-emit.sh test.event' _ "$LPROJ"
assert_eq 0 "$STATUS" "emission succeeds: $OUTPUT"
assert_file "$LPROJ/adapter-received.json" "adapter ran: Configuration section won over the decoy line above it"

it "adapter paths containing spaces remain forbidden independently of policy section parsing"
mkdir -p "$LPROJ/space dir"
cp "$LPROJ/adapter.sh" "$LPROJ/space dir/adapter.sh"
rm "$LPROJ/adapter-received.json"
printf '# Task Ledger\n\n## Configuration\n\n- backend: command\n- command: ./space dir/adapter.sh\n- events: all\n- mode: best-effort\n' > "$LPROJ/.prdkit/memory/task-ledger.md"
run bash -c 'cd "$1" && echo '\''{"event":"test"}'\'' | bash .prdkit/scripts/bash/ledger-emit.sh test.event' _ "$LPROJ"
assert_eq 1 "$STATUS" 'invalid adapter configuration fails'
assert_contains "$OUTPUT" 'single path' 'diagnostic explains the intentional path contract'
if [ ! -e "$LPROJ/adapter-received.json" ]; then
    _ok 'forbidden adapter never runs'
else
    _no 'forbidden adapter ran'
fi

# ---------------------------------------------------------------------------
it "build-review-package.sh rejects path-escaping change ids"
BRP="$PK_ROOT/scripts/build-review-package.sh"
cd "$PROJ" || exit 1
for bad in "../evil" "090-ok/../../x" "/abs" "T001"; do
    run bash "$BRP" "$bad" "HEAD"
    assert_eq 1 "$STATUS" "path-shaped id rejected: $bad"
    assert_contains "$OUTPUT" "CHANGE_ID" "error names the argument"
done

it "build-review-package.sh claims the next free round even when dirs exist"
mkdir -p "$PROJ/.prdkit/cache/evidence/090-plan-guard/reviews/round-1" "$PROJ/.prdkit/cache/evidence/090-plan-guard/reviews/round-2"
( cd "$PROJ" && git add -A >/dev/null 2>&1 && git commit -qm "base" >/dev/null 2>&1 )
BASE="$(git -C "$PROJ" rev-parse HEAD)"
echo change > "$PROJ/tracked-change.txt"
( cd "$PROJ" && git add tracked-change.txt >/dev/null 2>&1 && git commit -qm "head" >/dev/null 2>&1 )
run bash "$BRP" 090-plan-guard "$BASE"
assert_eq 0 "$STATUS" "package build succeeds"
assert_contains "$OUTPUT" '"ROUND":3' "existing round dirs advance the claim to round-3"
assert_contains "$OUTPUT" '"REPORT_PATH":' "report path emitted"
assert_file "$PROJ/.prdkit/cache/evidence/090-plan-guard/reviews/round-3/diff.patch" "diff.patch written into the claimed round"
assert_contains "$(cat "$PROJ/.prdkit/cache/evidence/090-plan-guard/reviews/round-3/diff.patch")" "tracked-change.txt" "package covers the full range"
assert_eq "" "$(git -C "$PROJ" status --porcelain -- .prdkit/cache)" "package stays untracked"

it "expected command failures are captured even when a suite enables errexit"
run bash -c 'set -e; source "$1/tests/lib.sh"; run bash -c "exit 7"; test "$STATUS" -eq 7' _ "$PK_ROOT"
assert_eq 0 "$STATUS" "run preserves nonzero status without aborting the suite"

it "missing temporary storage stops a suite before it can mutate the caller repository"
# A failing mktemp first on PATH stands in for unavailable storage. A missing TMPDIR is not
# enough: macOS mktemp still allocates in its per-user temporary directory.
NOTMP="$(mktemp -d)"; track_tmp "$NOTMP"
printf '#!/bin/sh\nexit 1\n' > "$NOTMP/mktemp"; chmod +x "$NOTMP/mktemp"
refs_before="$(git -C "$PROJ" show-ref)"
run bash -c 'cd "$1" && PATH="$3:$PATH" bash "$2/tests/test_delivery_checkpoint.sh"' _ "$PROJ" "$PK_ROOT" "$NOTMP"
assert_eq 1 "$STATUS" 'fixture storage failure stops the test process'
assert_contains "$OUTPUT" 'No tests were started' 'failure is explicit'
assert_eq "$refs_before" "$(git -C "$PROJ" show-ref)" 'caller refs remain untouched'

# ---------------------------------------------------------------------------
# macOS awk counts bytes in substr() but runs every regex over characters, and aborts ("towc:
# multibyte conversion failure") on the lone byte of a multibyte character in a UTF-8 locale:
# the first byte of an arrow, or of the dash after an ID. Linux awks never abort, so CI runs this
# scan. It finds each awk program by reading the shell around it (quotes, $( ), here-documents,
# and shell variables spliced into the program). Within one program, a variable, array,
# parameter or function return is tainted for good once it is given a value that may hold part
# of a character: a substr() of one to three characters, of a length not measured by match(),
# index() or length(), or from length() to the end; or a tainted value, alone or concatenated.
# Reassignment, comparison and getline never clear the taint, though a comparison's own 0 or 1
# holds no bytes. No regex (~, !~, match(), sub(), gsub(), split(), FS) and no toupper() or
# tolower() may see a tainted value. Test one character with == or index() instead.
# This is a best-effort lint over shell and awk text, not a parser: it misses what it cannot see
# (eval, awk -f, "$AWK", wrapper functions, backticks, a program built at run time such as
# prog=$(cat <<'EOF' ... EOF); awk "$prog") and can flag what is safe. A file that ends inside a
# quote, a $( ), a ( ) or a here-document was not read to the end, and is reported as
# "file:EOF: scan lost track". A line that ends in the comment "# awk-bytes-ok: <reason>" is left
# out of the scan: nothing it assigns is tainted and no regex on it is checked. Give the reason.
# The macOS job runs the suites under macOS awk and is the behavioural backstop.
regex_on_substr() { # file... -> "file:line: text" for each offending line
    awk '
        # One character is tested with ==, != or index(), never a regex: this scan runs under macOS awk.
        function isdig(c) { return c != "" && index("0123456789", c) > 0 }
        function isids(c) { return c != "" && index("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz_", c) > 0 }
        function isidc(c) { return isids(c) || isdig(c) }

        # ---- shell lexing: words of each simple command, per command-substitution level --------------
        function piece(x, type, text, ln,   n) { n = ++WPN[x]; WPT[x, n] = type; WPX[x, n] = text; WPL[x, n] = ln; WACT[x] = 1 }
        function flushlit(x) { if (LIT[x] != "") { piece(x, "L", LIT[x], LITL[x]); LIT[x] = "" } }
        function endword(x,   w, p) {
            flushlit(x)
            if (!WACT[x]) return
            w = ++NW[x]; CWN[x, w] = WPN[x]
            for (p = 1; p <= WPN[x]; p++) { CWT[x, w, p] = WPT[x, p]; CWX[x, w, p] = WPX[x, p]; CWL[x, w, p] = WPL[x, p] }
            WPN[x] = 0; WACT[x] = 0
        }
        function wlit(x, w,   p, s) {   # the word as plain text when wholly unquoted, else "\001"
            s = ""
            for (p = 1; p <= CWN[x, w]; p++) { if (CWT[x, w, p] != "L") return "\001"; s = s CWX[x, w, p] }
            return s
        }
        function isassign(x, w,   s, j) {
            if (CWN[x, w] < 1 || CWT[x, w, 1] != "L") return 0
            s = CWX[x, w, 1]; if (!isids(substr(s, 1, 1))) return 0
            for (j = 2; j <= length(s); j++) { if (substr(s, j, 1) == "=") return j; if (!isidc(substr(s, j, 1))) return 0 }
            return 0
        }
        function endcmd(x,   n, w, w0, e, name, p, lit, first, k, allassign) {
            n = NW[x]; NW[x] = 0
            if (n == 0) return
            w0 = 1; lit = wlit(x, 1)
            if (lit == "local" || lit == "export" || lit == "readonly" || lit == "declare" || lit == "typeset") w0 = 2
            allassign = 1
            for (w = w0; w <= n; w++) if (!isassign(x, w)) { allassign = 0; break }
            if (allassign && w0 <= n) {
                for (w = w0; w <= n; w++) {
                    e = isassign(x, w); name = FNAME SUBSEP substr(CWX[x, w, 1], 1, e - 1); GV[substr(CWX[x, w, 1], 1, e - 1)] = name
                    k = 0; VN[name] = 0
                    if (e < length(CWX[x, w, 1])) { VN[name] = ++k; VT[name, k] = "L"; VX[name, k] = substr(CWX[x, w, 1], e + 1); VL[name, k] = CWL[x, w, 1] }
                    for (p = 2; p <= CWN[x, w]; p++) { if (CWT[x, w, p] == "X") { VN[name] = -1; break } VN[name] = ++k; VT[name, k] = CWT[x, w, p]; VX[name, k] = CWX[x, w, p]; VL[name, k] = CWL[x, w, p] }
                    VF[name] = FNAME
                }
                return
            }
            for (w = 1; w <= n; w++) {
                if (isassign(x, w)) continue
                lit = wlit(x, w)
                if (lit == "if" || lit == "then" || lit == "else" || lit == "elif" || lit == "do" || lit == "while" || lit == "until" || lit == "!" || lit == "time" || lit == "exec" || lit == "command" || lit == "env" || lit == "{") continue
                break
            }
            if (w > n) return
            lit = wlit(x, w)
            sub(/.*\//, "", lit)
            if (lit != "awk" && lit != "gawk" && lit != "mawk" && lit != "nawk") return
            for (w++; w <= n; w++) {
                first = (CWT[x, w, 1] == "L") ? CWX[x, w, 1] : ""
                if (first == "--") { w++; break }
                if (substr(first, 1, 1) != "-" || first == "-") break
                if (first == "-f" && CWN[x, w] == 1) return
                if ((first == "-F" || first == "-v") && CWN[x, w] == 1) w++
            }
            if (w > n) return
            np = ++NPW; PWF[np] = FNAME; PWN[np] = CWN[x, w]
            for (p = 1; p <= CWN[x, w]; p++) { PWT[np, p] = CWT[x, w, p]; PWX[np, p] = CWX[x, w, p]; PWL[np, p] = CWL[x, w, p] }
        }
        function braceend(s, i,   n, j, c, dep) {   # the "}" closing the ${ at i, past nested quotes and braces
            n = length(s); dep = 0
            for (j = i + 1; j <= n; j++) {
                c = substr(s, j, 1)
                if (c == "\\") j++
                else if (c == "\047") { for (j++; j <= n && substr(s, j, 1) != "\047"; j++) ; }
                else if (c == "\"") {
                    for (j++; j <= n; j++) { c = substr(s, j, 1); if (c == "\\") j++; else if (c == "$" && substr(s, j + 1, 1) == "{") j = braceend(s, j); else if (c == "\"") break }
                }
                else if (c == "{") dep++
                else if (c == "}" && --dep == 0) return j
            }
            return n
        }
        function lexline(s, ln,   n, i, c, d, x, j, dep, del) {
            # A here-document: a quoted delimiter keeps the body literal; otherwise $( ) in it still runs.
            if (HDEL != "") { t = s; if (HSTRIP) while (substr(t, 1, 1) == "\t") t = substr(t, 2); if (t == HDEL) HDEL = ""; return }
            if (ST[CD] == "H") { t = s; if (HSTR[CD]) while (substr(t, 1, 1) == "\t") t = substr(t, 2); if (t == HDH[CD]) { ST[CD] = "N"; return } }
            s = s "\n"; n = length(s)
            for (i = 1; i <= n; i++) {
                x = CD; c = substr(s, i, 1)
                if (ST[x] == "H") {
                    if (c == "\\") i++
                    else if (c == "$" && substr(s, i + 1, 1) == "{") i = braceend(s, i)
                    else if (c == "$" && substr(s, i + 1, 1) == "(" && substr(s, i + 2, 1) != "(") { CD++; ST[CD] = "N"; PAR[CD] = 0; NW[CD] = 0; WPN[CD] = 0; WACT[CD] = 0; LIT[CD] = ""; i++ }
                    continue
                }
                if (ST[x] == "S") { if (c == "\047") { piece(x, "S", SB[x], SBL[x]); ST[x] = "N" } else SB[x] = SB[x] c; continue }
                if (ST[x] == "D") {
                    if (c == "\\") { SB[x] = SB[x] c substr(s, i + 1, 1); i++; continue }
                    if (c == "\"") { piece(x, "D", SB[x], SBL[x]); ST[x] = "N"; continue }
                    if (c == "$" && substr(s, i + 1, 1) == "{") { j = braceend(s, i); SB[x] = SB[x] substr(s, i, j - i + 1); i = j; continue }
                    if (c == "$" && substr(s, i + 1, 1) == "(" && substr(s, i + 2, 1) != "(") {
                        piece(x, "D", SB[x], SBL[x]); SB[x] = ""; SBL[x] = ln; piece(x, "X", "", ln)
                        CD++; ST[CD] = "N"; PAR[CD] = 0; NW[CD] = 0; WPN[CD] = 0; WACT[CD] = 0; LIT[CD] = ""; i++; continue
                    }
                    SB[x] = SB[x] c; continue
                }
                if (c == "#" && !WACT[x] && LIT[x] == "") { if (substr(s, i) ~ /^#[ \t]*awk-bytes-ok:[ \t]*[^ \t\n]/) OK[FNAME SUBSEP ln] = 1; i = n - 1; continue }
                if (c == "\\") { d = substr(s, i + 1, 1); i++; if (d != "\n") { if (LIT[x] == "") LITL[x] = ln; LIT[x] = LIT[x] d }; continue }
                if (c == "\047") { flushlit(x); ST[x] = "S"; SB[x] = ""; SBL[x] = ln; WACT[x] = 1; continue }
                if (c == "\"") { flushlit(x); ST[x] = "D"; SB[x] = ""; SBL[x] = ln; WACT[x] = 1; continue }
                if (c == "$" && substr(s, i + 1, 1) == "\047") {   # ANSI-C quoting: a backslash escapes its closing quote
                    for (j = i + 2; j <= n; j++) { d = substr(s, j, 1); if (d == "\\") j++; else if (d == "\047") break }
                    if (LIT[x] == "") LITL[x] = ln; LIT[x] = LIT[x] substr(s, i, j - i + 1); i = j; continue
                }
                if (c == "(" && substr(s, i + 1, 1) == "(") {   # (( arithmetic )), where << is a shift
                    dep = 0; for (j = i; j <= n; j++) { d = substr(s, j, 1); if (d == "(") dep++; else if (d == ")" && --dep == 0) break }
                    endword(x); i = j; continue
                }
                if (c == "$" && substr(s, i + 1, 1) == "(") {
                    if (substr(s, i + 2, 1) == "(") { dep = 0; for (j = i + 1; j <= n; j++) { d = substr(s, j, 1); if (d == "(") dep++; else if (d == ")" && --dep == 0) break } if (LIT[x] == "") LITL[x] = ln; LIT[x] = LIT[x] "0"; i = j; continue }
                    flushlit(x); piece(x, "X", "", ln)
                    CD++; ST[CD] = "N"; PAR[CD] = 0; NW[CD] = 0; WPN[CD] = 0; WACT[CD] = 0; LIT[CD] = ""; i++; continue
                }
                if (c == "$" && substr(s, i + 1, 1) == "{") { j = braceend(s, i); if (LIT[x] == "") LITL[x] = ln; LIT[x] = LIT[x] substr(s, i, j - i + 1); i = j; continue }
                if (c == " " || c == "\t") { endword(x); continue }
                if (c == "\n") {
                    endword(x); endcmd(x)
                    if (HPEND != "") { if (HPQ) { HDEL = HPEND } else { ST[x] = "H"; HDH[x] = HPEND; HSTR[x] = HSTRIP } HPEND = "" }
                    continue
                }
                if (c == ";" || c == "&" || c == "|") { endword(x); endcmd(x); continue }
                if (c == "(") { endword(x); endcmd(x); PAR[x]++; continue }
                if (c == ")") {
                    endword(x); endcmd(x)
                    if (PAR[x] > 0) PAR[x]--
                    else if (CD > 0) { CD--; if (ST[CD] == "D") { SB[CD] = ""; SBL[CD] = ln } }
                    continue
                }
                if (c == "<" && substr(s, i + 1, 2) == "<<") { endword(x); i += 2; continue }   # a here-string
                if (c == "<" && substr(s, i + 1, 1) == "<") {
                    endword(x); i += 2; HSTRIP = 0
                    if (substr(s, i, 1) == "-") { HSTRIP = 1; i++ }
                    while (substr(s, i, 1) == " ") i++
                    del = ""; HPQ = 0
                    for (; i <= n; i++) { d = substr(s, i, 1); if (d == " " || d == "\t" || d == "\n" || d == ";" || d == ")" || d == "|" || d == "&") break; if (d != "\047" && d != "\"" && d != "\\") del = del d; else HPQ = 1 }
                    HPEND = del; i--; continue
                }
                if (c == "<" || c == ">") { endword(x); continue }
                if (LIT[x] == "") LITL[x] = ln
                LIT[x] = LIT[x] c; WACT[x] = 1
            }
        }
        function lexreset() { CD = 0; ST[0] = "N"; HPQ = 0; PAR[0] = 0; NW[0] = 0; WPN[0] = 0; WACT[0] = 0; LIT[0] = ""; HDEL = ""; HPEND = "" }

        # ---- awk programs: text with a source line per program line ----------------------------------
        function ptext(k, t, f, ln,   n, parts, j) {   # append t (from file f, first line ln) to program k
            n = split(t, parts, "\n")
            if (n == 0) return
            if (PLN[k] == 0) { PLN[k] = 1; PLINE[k, 1] = "" }
            seg(k, PLN[k], f, ln); PLINE[k, PLN[k]] = PLINE[k, PLN[k]] parts[1]
            for (j = 2; j <= n; j++) { PLN[k]++; PLINE[k, PLN[k]] = ""; seg(k, PLN[k], f, ln + j - 1); PLINE[k, PLN[k]] = parts[j] }
        }
        # Each piece of a program line keeps its own source: the file and line it came from.
        function seg(k, l, f, ln,   n) { n = ++SN[k, l]; SC[k, l, n] = length(PLINE[k, l]) + 1; SF[k, l, n] = f; SL[k, l, n] = ln }
        function loc(k, l, col,   n) { for (n = SN[k, l]; n > 1 && SC[k, l, n] > col; n--) ; return SF[k, l, n] SUBSEP SL[k, l, n] }
        function pvar(k, name, f,   p, v) {   # a shell variable: its value in file f, else where it is last set
            v = ((f SUBSEP name) in VN) ? f SUBSEP name : GV[name]
            if (VN[v] > 0) for (p = 1; p <= VN[v]; p++) ppiece(k, VT[v, p], VX[v, p], VF[v], VL[v, p])
        }
        function ppiece(k, type, raw, f, ln,   out, i, c, d, j, name, nl) {
            if (type == "L" || type == "S") { ptext(k, raw, f, ln); return }
            if (type != "D") return
            out = ""; nl = ln
            for (i = 1; i <= length(raw); i++) {
                c = substr(raw, i, 1)
                if (c == "\\") { d = substr(raw, i + 1, 1); i++; if (d == "\n") { ptext(k, out, f, nl); nl += gsubcount(out) + 1; out = ""; continue } if (d == "$" || d == "\"" || d == "\\" || d == "`") out = out d; else out = out c d; continue }
                if (c == "$") {
                    d = substr(raw, i + 1, 1); name = ""
                    if (d == "{") { for (j = i + 2; j <= length(raw) && substr(raw, j, 1) != "}"; j++) name = name substr(raw, j, 1); i = j }
                    else if (isids(d)) { for (j = i + 1; j <= length(raw) && isidc(substr(raw, j, 1)); j++) name = name substr(raw, j, 1); i = j - 1 }
                    else if (isdig(d)) { i++; continue }
                    else { out = out c; continue }
                    ptext(k, out, f, nl); nl += gsubcount(out); out = ""; pvar(k, name, f); continue
                }
                out = out c
            }
            ptext(k, out, f, nl)
        }
        function gsubcount(s,   n, i) { n = 0; for (i = 1; i <= length(s); i++) if (substr(s, i, 1) == "\n") n++; return n }

        # ---- awk tokens --------------------------------------------------------------------------------
        function push(type, text, ln, col) { NT++; TK[NT] = text; TT[NT] = type; TL[NT] = ln; TLOC[NT] = loc(TKP, ln, col) }
        function operand(k) { return k > 0 && (TT[k] == "num" || TT[k] == "str" || TK[k] == ")" || TK[k] == "]" || (TT[k] == "id" && !(TK[k] in KW))) }
        function tokprog(k,   j, s, n, i, c, d, inb, m, cont) {
            NT = 0; TKP = k
            for (j = 1; j <= PLN[k]; j++) {
                s = PLINE[k, j]; n = length(s); i = 1
                while (i <= n) {
                    c = substr(s, i, 1)
                    if (c == " " || c == "\t" || c == "\r") { i++; continue }
                    if (c == "#") { if (substr(s, i) ~ /^#[ \t]*awk-bytes-ok:[ \t]*[^ \t]/) OK[loc(k, j, i)] = 1; break }
                    if (c == "\\" && i == n) { i++; continue }
                    if (c == "\"") {
                        for (m = i + 1; m <= n; m++) { d = substr(s, m, 1); if (d == "\\") { m++; continue } if (d == "\"") break }
                        push("str", substr(s, i, m - i + 1), j, i); i = m + 1; continue
                    }
                    if (c == "/" && !operand(NT)) {
                        inb = 0
                        for (m = i + 1; m <= n; m++) {
                            d = substr(s, m, 1)
                            if (d == "\\") { m++; continue }
                            if (inb) {
                                if (d == "[" && substr(s, m + 1, 1) == ":" && (cont = index(substr(s, m + 2), ":]"))) { m += cont + 2; continue }
                                if (d == "]" && m > inb) inb = 0
                            } else if (d == "[") { inb = m + 1; if (substr(s, inb, 1) == "^") inb++ }
                            else if (d == "/") break
                        }
                        if (m <= n) { push("re", substr(s, i, m - i + 1), j, i); i = m + 1; continue }
                    }
                    if (isdig(c)) { for (m = i + 1; m <= n && (isdig(substr(s, m, 1)) || substr(s, m, 1) == "."); m++) ; push("num", substr(s, i, m - i), j, i); i = m; continue }
                    if (isids(c)) { for (m = i + 1; m <= n && isidc(substr(s, m, 1)); m++) ; push("id", substr(s, i, m - i), j, i); i = m; continue }
                    d = c substr(s, i + 1, 1)
                    if (length(d) == 2 && index(" !~ == != <= >= && || += -= *= /= %= ^= ++ -- ", " " d " ")) { push("op", d, j, i); i += 2; continue }
                    push("op", c, j, i); i++
                }
                # A newline ends a statement unless the line ends in a continuation.
                if (NT > 0 && !(substr(s, n, 1) == "\\" || TK[NT] == "," || TK[NT] == "{" || TK[NT] == "&&" || TK[NT] == "||" || TK[NT] == "do" || TK[NT] == "else")) push("nl", "", j, n)
            }
            TK[0] = ""; TT[0] = ""; TK[NT + 1] = ""; TT[NT + 1] = ""
        }
        function closer(p,   o, x, dep, j) {
            o = TK[p]; x = (o == "(") ? ")" : (o == "[") ? "]" : "}"; dep = 0
            for (j = p; j <= NT; j++) { if (TK[j] == o) dep++; else if (TK[j] == x && --dep == 0) return j }
            return NT
        }
        function opener(q,   x, o, dep, j) {
            x = TK[q]; o = (x == ")") ? "(" : "["; dep = 0
            for (j = q; j >= 1; j--) { if (TK[j] == x) dep++; else if (TK[j] == o && --dep == 0) return j }
            return 1
        }
        # Arguments of the call whose "(" is at p: tokens A1[p, j] to A2[p, j] for j = 1..n; returns n.
        function args(p,   e, j, n, dep) {
            if (p in NA) return NA[p]
            e = closer(p); n = 0
            if (e == p + 1) return NA[p] = 0
            n = 1; A1[p, 1] = p + 1; dep = 0
            for (j = p + 1; j < e; j++) {
                if (TK[j] == "(" || TK[j] == "[") dep++
                else if (TK[j] == ")" || TK[j] == "]") dep--
                else if (dep == 0 && TK[j] == ",") { A2[p, n] = j - 1; n++; A1[p, n] = j + 1 }
            }
            A2[p, n] = e - 1
            return NA[p] = n
        }
        function key(i, name) { return (OWN[i] != "" && index(" " FPAR[OWN[i]] " ", " " name " ")) ? OWN[i] SUBSEP name : SUBSEP name }
        function exempt(i) { return TLOC[i] in OK }
        # A substr() that may cut a character: a literal length of 1 to 3; a computed length that is not
        # measured (RSTART, RLENGTH, length(), index(), or a variable ever set from one); or the tail
        # from length() of the same string.
        function measured(a, b,   j) {
            for (j = a; j <= b; j++) if (TK[j] == "RSTART" || TK[j] == "RLENGTH" || TK[j] == "length" || TK[j] == "index" || TT[j] == "id" && MEAS[key(j, TK[j])]) return 1
            return 0
        }
        function source(i,   n, j, v, q, s1, s2) {
            n = args(i + 1); q = i + 1
            if (n == 3) {
                if (A1[q, 3] == A2[q, 3] && TT[A1[q, 3]] == "num") { v = TK[A1[q, 3]] + 0; return v >= 0 && v <= 3 }
                return !measured(A1[q, 3], A2[q, 3])
            }
            if (n == 2) {
                s1 = ""; for (j = A1[q, 1]; j <= A2[q, 1]; j++) s1 = s1 " " TK[j]
                for (j = A1[q, 2]; j <= A2[q, 2]; j++) if (TK[j] == "length") {
                    if (TK[j + 1] != "(" || TK[j + 2] == ")") return s1 == " $ 0"
                    s2 = ""; for (v = j + 2; v < closer(j + 1); v++) s2 = s2 " " TK[v]
                    if (s1 == s2) return 1
                }
            }
            return 0
        }
        # Whether the value of the expression in tokens a..b may hold bytes of a tainted string. A
        # comparison, a match, "in", && or || yields 0 or 1, and a ternary yields one of its arms; those
        # results hold no bytes. The taint itself is never cleared.
        function tainted(a, b,   j, d, asg, q, bool, t, e, n) {
            while (a < b && TK[a] == "(" && closer(a) == b) { a++; b-- }
            d = 0; asg = 0; q = 0; bool = 0
            for (j = a; j <= b; j++) {
                t = TK[j]
                if (t == "(" || t == "[") { d++; continue }
                if (t == ")" || t == "]") { d--; continue }
                if (d) continue
                if (!asg && (t == "=" || t == "+=" || t == "-=" || t == "*=" || t == "/=" || t == "%=" || t == "^=")) asg = j
                else if (!q && t == "?") q = j
                else if (t == "||" || t == "&&" || t == "in" || t == "~" || t == "!~" || t == "==" || t == "!=" || t == "<" || t == "<=" || t == ">" || t == ">=") bool = 1
            }
            if (asg) return TK[asg] == "=" && tainted(asg + 1, b)
            if (q) {
                d = 0; n = 0
                for (j = q + 1; j <= b; j++) {
                    t = TK[j]
                    if (t == "(" || t == "[") d++
                    else if (t == ")" || t == "]") d--
                    else if (!d && t == "?") n++
                    else if (!d && t == ":" && n-- == 0) break
                }
                return tainted(q + 1, j - 1) || tainted(j + 1, b)
            }
            if (bool) return 0
            for (j = a; j <= b; j++) {
                t = TK[j]
                if (t == "(") { if (tainted(j + 1, closer(j) - 1)) return 1; j = closer(j); continue }
                if (t == "$") { if (DOL) return 1; if (TK[j + 1] == "(") j = closer(j + 1); else j++; continue }
                if (TT[j] != "id" || (t in KW)) continue
                if (TK[j + 1] == "(") {
                    e = closer(j + 1)
                    if (t == "substr") { if (source(j)) return 1; n = args(j + 1); if (n && tainted(A1[j + 1, 1], A2[j + 1, 1])) return 1 }
                    else if (t == "sprintf" || t == "toupper" || t == "tolower") { if (tainted(j + 2, e - 1)) return 1 }
                    else if (t in FR) return 1
                    j = e; continue
                }
                if (TK[j + 1] == "[") { if (TA[key(j, t)]) return 1; j = closer(j + 1); continue }
                if (TV[key(j, t)]) return 1
            }
            return 0
        }
        function setv(k) { if (!TV[k]) { TV[k] = 1; CHANGED = 1 } }
        function seta(k) { if (!TA[k]) { TA[k] = 1; CHANGED = 1 } }
        function setk(k) { if (!TK2[k]) { TK2[k] = 1; CHANGED = 1 } }
        function setdol() { if (!DOL) { DOL = 1; CHANGED = 1 } }
        function stmtend(i,   j, dep) {   # last token of the expression starting at i
            dep = 0
            for (j = i; j <= NT; j++) {
                if (TK[j] == "(" || TK[j] == "[") dep++
                else if (TK[j] == ")" || TK[j] == "]") { if (dep == 0) return j - 1; dep-- }
                else if (dep == 0 && (TT[j] == "nl" || TK[j] == ";" || TK[j] == "}" || TK[j] == "{" || TK[j] == ",")) return j - 1
            }
            return NT
        }
        # One pass of taint propagation over program CURP.
        function propagate(   i, j, e, n, m, b, pp, fn, name) {
            for (i = 1; i <= NT; i++) {
                if (exempt(i)) continue
                if (TK[i] == "=") {
                    e = stmtend(i + 1); b = tainted(i + 1, e)
                    if (TT[i - 1] == "id" && TK[i - 2] != "$") { if (b) setv(key(i - 1, TK[i - 1])) }
                    else if (TK[i - 1] == "]") {
                        j = opener(i - 1)
                        if (TT[j - 1] == "id") { if (b) seta(key(j - 1, TK[j - 1])); if (tainted(j + 1, i - 2)) setk(key(j - 1, TK[j - 1])) }
                    }
                    if (b && (TK[i - 2] == "$" || TK[i - 1] == ")" && TK[opener(i - 1) - 1] == "$")) setdol()
                    continue
                }
                if (TT[i] == "id" && TK[i + 1] == "[" && tainted(i + 2, closer(i + 1) - 1)) setk(key(i, TK[i]))
                if (TK[i] == "for" && TK[i + 1] == "(" && TT[i + 2] == "id" && TK[i + 3] == "in" && TT[i + 4] == "id" && TK[i + 5] == ")") {
                    if (TK2[key(i + 4, TK[i + 4])]) setv(key(i + 2, TK[i + 2]))
                }
                if (TK[i] == "split" && TK[i + 1] == "(") {
                    n = args(i + 1)
                    if (n >= 2 && A1[i + 1, 2] == A2[i + 1, 2] && TT[A1[i + 1, 2]] == "id") {
                        name = key(A1[i + 1, 2], TK[A1[i + 1, 2]])
                        if (tainted(A1[i + 1, 1], A2[i + 1, 1]) || n == 3 && (tainted(A1[i + 1, 3], A2[i + 1, 3]) || TK[A1[i + 1, 3]] == "\"\"" && A1[i + 1, 3] == A2[i + 1, 3])) seta(name)
                    }
                }
                if ((TK[i] == "sub" || TK[i] == "gsub") && TK[i + 1] == "(" && args(i + 1) >= 2 && tainted(A1[i + 1, 2], A2[i + 1, 2])) {
                    if (NA[i + 1] == 2 || TK[A1[i + 1, 3]] == "$") setdol()
                    else if (TT[A1[i + 1, 3]] == "id") {
                        j = A1[i + 1, 3]
                        if (TK[j + 1] == "[") seta(key(j, TK[j])); else setv(key(j, TK[j]))
                    }
                }
                if (TT[i] == "id" && TK[i + 1] == "(" && (TK[i] in FPAR) && TK[i - 1] != "function") {
                    fn = TK[i]; n = args(i + 1); m = split(FPAR[fn], pp, " ")
                    for (j = 1; j <= n && j <= m; j++) {
                        if (tainted(A1[i + 1, j], A2[i + 1, j])) setv(fn SUBSEP pp[j])
                        if (A1[i + 1, j] == A2[i + 1, j] && TT[A1[i + 1, j]] == "id") {   # an array, both ways
                            name = key(A1[i + 1, j], TK[A1[i + 1, j]])
                            if (TA[name]) seta(fn SUBSEP pp[j]); if (TA[fn SUBSEP pp[j]]) seta(name)
                            if (TK2[name]) setk(fn SUBSEP pp[j]); if (TK2[fn SUBSEP pp[j]]) setk(name)
                        }
                    }
                }
                if (TK[i] == "return" && OWN[i] != "" && tainted(i + 1, stmtend(i + 1)) && !(OWN[i] in FR)) { FR[OWN[i]] = 1; CHANGED = 1 }
            }
        }
        function hit(i,   w) {
            if (exempt(i)) return
            w = TLOC[i]
            if (!(w in HIT)) { HIT[w] = 1; HORD[++NHIT] = w }
        }
        function stopleft(t) { return t == "~" || t == "!~" || t == "in" || t == "&&" || t == "||" || t == "?" || t == ":" || t == "," || t == ";" || t == "{" || t == "}" || t == "=" || t == "+=" || t == "-=" || t == "*=" || t == "/=" || t == "%=" || t == "^=" || t == "return" || t == "print" || t == "printf" || t == "if" || t == "while" || t == "do" || t == "else" || t == "" }
        function stopright(t) { return t == "~" || t == "!~" || t == "in" || t == "&&" || t == "||" || t == "?" || t == ":" || t == "," || t == ";" || t == "{" || t == "}" || t == "" }
        function sinks(   i, j, a, b, dep, n, p, name) {
            for (i = 1; i <= NT; i++) {
                if (TK[i] == "~" || TK[i] == "!~") {
                    dep = 0
                    for (j = i - 1; j >= 1; j--) {
                        if (TK[j] == ")" || TK[j] == "]") dep++
                        else if (TK[j] == "(" || TK[j] == "[") { if (dep == 0) break; dep-- }
                        else if (dep == 0 && (TT[j] == "nl" || stopleft(TK[j]))) break
                    }
                    a = j + 1; dep = 0
                    for (j = i + 1; j <= NT; j++) {
                        if (TK[j] == "(" || TK[j] == "[") dep++
                        else if (TK[j] == ")" || TK[j] == "]") { if (dep == 0) break; dep-- }
                        else if (dep == 0 && (TT[j] == "nl" || stopright(TK[j]))) break
                    }
                    b = j - 1
                    if (tainted(a, i - 1) || tainted(i + 1, b)) hit(i)
                    continue
                }
                if (TT[i] == "id" && TK[i + 1] == "(" && TK[i - 1] != "function") {
                    name = TK[i]
                    if (name == "match" || name == "sub" || name == "gsub" || name == "split" || name == "toupper" || name == "tolower") {
                        n = args(i + 1)
                        for (j = 1; j <= n; j++) if (!(name ~ /sub$/ && j == 2) && !(name == "split" && j == 2) && tainted(A1[i + 1, j], A2[i + 1, j])) { hit(i); break }
                        if ((name == "sub" || name == "gsub") && n == 2 && DOL) hit(i)
                    }
                    continue
                }
                if (TK[i] == "=" && (TK[i - 1] == "FS" || TK[i - 1] == "RS") && tainted(i + 1, stmtend(i + 1))) { hit(i); continue }
                if (TT[i] == "re" && DOL && TK[i - 1] != "~" && TK[i - 1] != "!~") {
                    dep = 0
                    for (p = i - 1; p >= 1; p--) {
                        if (TK[p] == ")" || TK[p] == "]") dep++
                        else if (TK[p] == "(" || TK[p] == "[") { if (dep == 0) break; dep-- }
                        else if (dep == 0 && (TT[p] == "nl" || TK[p] == ";" || TK[p] == "{" || TK[p] == "}")) { p = 0; break }
                    }
                    if (p < 1 || !(TK[p - 1] == "match" || TK[p - 1] == "sub" || TK[p - 1] == "gsub" || TK[p - 1] == "split")) hit(i)
                }
            }
        }
        function analyse(k,   i, j, e, pass, n) {
            CURP = k; tokprog(k)
            split("", MEAS); split("", NA); split("", A1); split("", A2); split("", FPAR); split("", OWN); split("", TV); split("", TA); split("", TK2); split("", FR); DOL = 0
            for (i = 1; i <= NT; i++) if (TK[i] == "function" && TT[i + 1] == "id" && TK[i + 2] == "(") {
                e = closer(i + 2); s = ""
                for (j = i + 3; j < e; j++) if (TT[j] == "id") s = s " " TK[j]
                FPAR[TK[i + 1]] = s
                for (j = e + 1; j <= NT && TK[j] != "{"; j++) ;
                n = closer(j); for (m = j; m <= n; m++) OWN[m] = TK[i + 1]
            }
            for (i = 1; i <= NT; i++) if ((TK[i] == "=" || TK[i] == "+=" || TK[i] == "-=") && TT[i - 1] == "id" && measured(i + 1, stmtend(i + 1))) MEAS[key(i - 1, TK[i - 1])] = 1
            for (pass = 1; pass <= 30; pass++) { CHANGED = 0; propagate(); if (!CHANGED) break }
            sinks()
        }

        BEGIN { split("if while for return in print printf getline do else delete function next exit", kwl, " "); for (i in kwl) KW[kwl[i]] = 1 }
        # Fail closed: a file that ends inside a quote, $( ), ( ) or a here-document was not fully read.
        function lost() { if (NFILE && (CD > 0 || ST[0] != "N" || PAR[0] > 0 || HDEL != "" || HPEND != "")) { HIT[FNAME SUBSEP "EOF"] = 1; HORD[++NHIT] = FNAME SUBSEP "EOF" } }
        FNR == 1 { lost(); FNAME = FILENAME; FIDX[FNAME] = ++NFILE; lexreset() }
        {
            RAW[FNAME, FNR] = $0
            lexline($0, FNR)
        }
        END {
            lost()
            # Each awk program as awk sees it: the program word, its shell variables expanded.
            for (np = 1; np <= NPW; np++) {
                NP++; PLN[NP] = 0
                for (p = 1; p <= PWN[np]; p++) ppiece(NP, PWT[np, p], PWX[np, p], PWF[np], PWL[np, p])
            }
            # Shell variables that define awk functions are also read on their own.
            for (v in VN) if (VN[v] > 0) {
                s = ""; for (p = 1; p <= VN[v]; p++) s = s VX[v, p]
                split(v, vv, SUBSEP)
                if (index(s, "function ")) { NP++; PLN[NP] = 0; pvar(NP, vv[2], vv[1]) }
            }
            for (k = 1; k <= NP; k++) analyse(k)
            for (i = 1; i <= NHIT; i++) {   # in file and line order
                split(HORD[i], w, SUBSEP); HF[i] = FIDX[w[1]]; HL[i] = (w[2] == "EOF") ? 1e9 : w[2] + 0
                for (j = i; j > 1 && (HF[j - 1] > HF[j] || HF[j - 1] == HF[j] && HL[j - 1] > HL[j]); j--) {
                    t = HORD[j]; HORD[j] = HORD[j - 1]; HORD[j - 1] = t; t = HF[j]; HF[j] = HF[j - 1]; HF[j - 1] = t; t = HL[j]; HL[j] = HL[j - 1]; HL[j - 1] = t
                }
            }
            for (i = 1; i <= NHIT; i++) { split(HORD[i], w, SUBSEP); print w[1] ":" w[2] ": " (w[2] == "EOF" ? "scan lost track" : RAW[w[1], w[2]]) }
        }
    ' "$@"
}

it "no script runs a regex over a substr() result or a few characters cut by substr()"
SCAN="$(mktemp -d)"; track_tmp "$SCAN"
cat > "$SCAN/planted.sh" <<'SH'
awk '
function isws(ch) { return ch ~ /[[:space:]]/ }
function prev(s, i) { return i > 1 ? substr(s, i - 1, 1) : "" }
{
    if (substr(s, i, 1) ~ /x/) n++
    pre = (i == 1) ? "" : substr(s, i - 1, 1); if (pre !~ /[a-z]/) n++
    cc = c = substr(s, i, 1)
    if ((cc) ~ /x/ || isws(c)) n++
    while ((d = substr(s, i, 1)) ~ /y/) i++
    if (sub(/x/, "", c) || toupper(c) == "X" || split(c, part, /y/) > 1) n++
    if (substr (s, i, 1) \
        ~ /x/) n++
    two = substr(s, i, 2); if (match(two, /->/)) n++
    ch[i] = substr(s, i, 1); e = ch[i]; if (e ~ /x/) n++
    m = split(s, chars, ""); if (chars[1] ~ /x/) n++
    x = substr(s, i, 1) ""; if (x ~ /x/) n++
    y = "" substr(s, i, 1); if (match(y, /y/)) n++
    if (c == "\t") c = " "
    if (c ~ /[[:space:]]/) n++
    if (prev(s, i) ~ /[a-z]/) n++
    if (substr(s, i, 1) ~ /z/) n++  # awk-bytes-ok:
}'
first='function first(s) { return substr(s, 1, 1) }'
n="$(printf '%s\n' "$s" | awk "$first"' { if (first($0) ~ /x/) n++ }')"
awk "{ if (substr(\$0, length(\$0)) ~ /x/) n++ }"
(( m = 1 << 2 ))
awk '{ if (substr($0, 1, 1) ~ /x/) n++ }'
printf '%s\n' $'it\'s'
awk '{ if (substr($0, 1, 1) ~ /x/) n++ }'
awk '{ if (substr($0, 1, 1) ~ /w/) print "# awk-bytes-ok: x" }'
SH
cat > "$SCAN/clean.sh" <<'SH'
awk '{
    c = substr(s, i, 1); if (c == "(" || index("ABC_", c)) n++
    while ((d = substr(s, i, 1)) != "" && index(" \t", d)) i++
    # if (substr(s, i, 1) ~ /a comment/) n++
    k = mysubstr(s, i, 1); if (k ~ /not the built-in/) n++
    if (split(s, part, /[[:space:]]/) > 1) s = part[1]
    base = (substr(t, 1, 1) == "/") ? "" : dir; if (base ~ /\/$/) n++
    ok = substr(s, 1, 1) == "#"; if (ok ~ /1/) n++
    p = index(s, c); w = substr(s, 1, p - 1); if (w ~ /x/ || p ~ /1/) n++
    tok = substr(s, RSTART, RLENGTH); if (tok ~ /^P/) n++
    t = t c  # awk-bytes-ok: t takes every byte of s, in order
    if (t ~ /^x/) n++
}'
awk -F '|' '{ c = $2; if (c ~ /^ *Tier/) n++ }'  # never write substr(s, i, 1) ~ /x/
echo "substr(s, i, 1) ~ is unsafe"
cat <<'EOF'
awk '{ if (substr($0, 1, 1) ~ /x/) n++ }'
EOF
SH
assert_eq "planted.sh:2 planted.sh:5 planted.sh:6 planted.sh:8 planted.sh:9 planted.sh:10 planted.sh:12 planted.sh:13 planted.sh:14 planted.sh:15 planted.sh:16 planted.sh:17 planted.sh:19 planted.sh:20 planted.sh:21 planted.sh:24 planted.sh:25 planted.sh:27 planted.sh:29 planted.sh:30" \
    "$(cd "$SCAN" && regex_on_substr planted.sh | cut -d: -f1,2 | tr '\n' ' ' | sed 's/ $//')" \
    "the scan finds direct, variable, array, ternary, chained, concatenated, reassigned, parameter, return, continued, spliced and builtin uses"
cat > "$SCAN/lost.sh" <<'SH'
awk '{ print }' <<'EOF'
awk '{ if (substr($0, 1, 1) ~ /x/) n++ }'
SH
assert_eq "lost.sh:EOF: scan lost track" "$(cd "$SCAN" && regex_on_substr lost.sh clean.sh)" "a file the scan cannot read to its end fails the scan"
assert_eq "" "$(cd "$SCAN" && regex_on_substr clean.sh)" "comparisons, index(), measured cuts, comments, strings, other programs, here-documents and justified lines pass"
scripts=(); while IFS= read -r f; do scripts+=("$f"); done < <(cd "$PK_ROOT" && find scripts -type f -name '*.sh' | sort)
assert_eq "" "$(cd "$PK_ROOT" && regex_on_substr "${scripts[@]}")" "every script under scripts/ passes the scan"

it "status, doctor and bounds read arrows, dashes and accents beside IDs, links and names"
MB="$(make_inited_project)"; track_tmp "$MB"
cd "$MB" || exit 1
export PRDKIT_TODAY=2026-10-17
mkdir -p specs/product specs/architecture specs/changes docs tests
cat > specs/product.md <<'MD'
# Demo — product

- **R-01 Greet users** (validated): a greeting; [notes](../docs/café.md "Notes"), [old](../docs/café-old.md "Old").
MD
cat > specs/architecture.md <<'MD'
# Demo — architecture

| Part | Purpose | Maturity | Owns data | Serves | Spec |
|------|---------|----------|-----------|--------|------|
| P1 Web | serves pages | validated | none | J-01 | none |
| P2 Store | keeps greetings | validated | greetings | J-02 | none |
| P3 Admin | edits greetings | validated | none | J-03 | none |
MD
printf '# Demo — environments\n\n| Environment | For |\n|---|---|\n| TEST | early access |\n' > specs/architecture/environments.md
printf '# Demo — lifecycle\n\n**Now**: MVP\n\n## MVP\n\n- **Environment**: TEST—early access.\n\n## Private preview\n\n- **Environment**: STAGING—invited users.\n\n## Public preview\n\n- **Environment**: TEST\n' > specs/product/lifecycle.md
printf '# Demo — qualities\n\n- **Q-01 Fast greeting** (hypothesis): p95 under 1 s. Journeys: J-01–J-02.\n- **Q-02 Admin audit** (hypothesis): logged. Journeys: J-03.\n' > specs/product/qualities.md
printf '# Notes\n' > docs/café.md
printf 'def test_greeting():  # proves R-01—and R-09—the old one\n    pass\nR-08—a line that starts with an ID\n' > tests/test_greeting.py
printf '# Change: pages\n\n**Opened**: 2026-10-16 · **Parts**: P1–P2 · **Journeys**: J-01–J-02 · **Tier**: T1\n' > specs/changes/007-pages.md
printf '# Owner inbox\n\n2026-10-02 owner "Pick the colour" → open\n' > specs/inbox.md
git add -A >/dev/null; git commit -qm spec >/dev/null
run bash .prdkit/scripts/bash/status.sh
assert_eq 0 "$STATUS" "status exits 0"
assert_eq 1 "$(printf '%s\n' "$OUTPUT" | grep -cFx '  2026-10-02 owner, 15 days: "Pick the colour"')" "a one-line inbox item with an arrow, its words exactly"
run bash .prdkit/scripts/bash/doctor.sh
assert_eq 0 "$STATUS" "doctor exits 0"
assert_contains "$OUTPUT" "Owner inbox: 1 item(s) awaiting agent processing" "doctor reads the same owner direction"
assert_contains "$OUTPUT" "ID R-09 is cited at tests/test_greeting.py:1" "an ID between em dashes is cited"
assert_contains "$OUTPUT" "ID J-02 is cited at specs/product/qualities.md:3" "an ID after an en dash is cited"
assert_contains "$OUTPUT" "ID R-08 is cited at tests/test_greeting.py:3" "an ID at the start of a line is cited"
assert_contains "$OUTPUT" "Link at specs/product.md:3 points to docs/café-old.md, which does not exist" "a link target with an accent ends at its space"
assert_not_contains "$OUTPUT" "docs/café.md" "the link to an existing file resolves"
assert_not_contains "$OUTPUT" "the MVP stage" "an environment followed by an em dash is named"
assert_contains "$OUTPUT" "Environments: the Private preview stage at specs/product/lifecycle.md:11 runs in none" "the check reads on past it"
assert_not_contains "$OUTPUT" "the Public preview stage" "a value that is only the environment name names it"
run bash .prdkit/scripts/bash/bounds.sh 007-pages
assert_eq 0 "$STATUS" "bounds exits 0"
assert_contains "$OUTPUT" "(in scope: P1 P2 J-01 J-02)" "en-dash ranges of parts and journeys"
assert_contains "$OUTPUT" "- Q-01 Fast greeting" "an item citing an en-dash range"
assert_not_contains "$OUTPUT" "Q-02" "an item outside the ranges"
assert_not_contains "$OUTPUT" "Not in the parts table" "every part in the ranges is defined"

finish
