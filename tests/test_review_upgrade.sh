#!/usr/bin/env bash
# The 2.0 review transition uses committed, local history and the host stub only.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
use_gh_stub

commit_fixture() { git -C "$PROJ" add -A && git -C "$PROJ" commit -qm "$1" || exit 1; }
trusted_tip() {
    git -C "$PROJ" update-ref refs/remotes/origin/main HEAD
    git -C "$PROJ" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}
transition_project() {
    PROJ="$(make_inited_project --copy)"; track_tmp "$PROJ"
    PROJ="$(cd "$PROJ" && pwd -P)"
    git -C "$PROJ" remote add origin https://github.com/owner/repo.git
    # Release ownership stays with the maintainer; a fixture explicitly models the 2.0 source.
    printf '2.0.0\n' > "$PROJ/.product-kit/VERSION"
    cat > "$PROJ/.prdkit/memory/constitution.md" <<'EOF'
# Constitution
- **Rigor**: full
EOF
    cat > "$PROJ/.prdkit/memory/config.md" <<'EOF'
# Configuration
## Configuration
- review-host: github
- review-publishers: bot:1001
- review-owner: user:1003
- review-publisher-isolation: required
EOF
    printf '\n## Review registry\n| Identity | Role |\n|---|---|\n| code | reviewer |\n| security | reviewer |\n' >> "$PROJ/.prdkit/memory/agents.md"
    commit_fixture policy; trusted_tip
}
upgrade() { run bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade "$@"; }
# Hash every filesystem entry, including ignored/untracked entries, links and empty
# directories. Git metadata is not checkout content. No traversal through symlinks.
tree_snapshot() (
    local root="$1" paths rows path mode
    [ -e "$root" ] || [ -L "$root" ] || { printf 'absent\n'; return; }
    paths="$(mktemp)"; rows="$(mktemp)" || return 1
    trap 'rm -f "$paths" "$rows"' EXIT
    cd "$root" || return 1
    find . -name .git -prune -o -print0 > "$paths" || return 1
    while IFS= read -r -d '' path; do
        # shellcheck disable=SC2012 # Only the fixed permission/type field, never a filename, is parsed.
        mode="$(LC_ALL=C ls -ld "$path" | awk '{ print $1 }')" || return 1
        { printf '%s\000%s\000' "$path" "$mode"
          if [ -L "$path" ]; then readlink "$path"
          elif [ -f "$path" ]; then cat "$path"; fi
        } | git hash-object --stdin >> "$rows" || return 1
    done < "$paths"
    LC_ALL=C sort "$rows" | git hash-object --stdin
)
unchanged() {
    assert_eq "$BEFORE" "$(git -C "$PROJ" status --porcelain --untracked-files=all)" 'refusal leaves all target paths unchanged'
    if [ -e "$PROJ/.prdkit/.install-state" ]; then _no 'no phase marker created'; else _ok 'no phase marker created'; fi
}

it 'migration flags are explicit and only available on a 2.0 source'
transition_project
run bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --migrate-reviews
assert_eq 2 "$STATUS" 'migration needs --upgrade'
printf '1.5.0\n' > "$PROJ/.product-kit/VERSION"
upgrade --migrate-reviews; assert_eq 2 "$STATUS" 'old kit refuses migration'
for flags in '--dry-run' '--json' '--check --migrate-reviews'; do
    # Deliberate splitting: these are fixture option lists, not paths.
    # shellcheck disable=SC2086
    upgrade $flags
    assert_eq 2 "$STATUS" "invalid option combination: $flags"
done

it 'P1 refuses staged, unstaged and untracked work before any target mutation'
for kind in staged unstaged untracked; do
    transition_project
    case "$kind" in
        staged) printf edit >> "$PROJ/AGENTS.md"; git -C "$PROJ" add AGENTS.md ;;
        unstaged) printf edit >> "$PROJ/AGENTS.md" ;;
        untracked) printf edit > "$PROJ/unrelated" ;;
    esac
    BEFORE="$(git -C "$PROJ" status --porcelain --untracked-files=all)"
    upgrade --migrate-reviews --dry-run
    assert_eq 1 "$STATUS" "$kind refuses"
    assert_contains "$OUTPUT" 'P1:' 'checkout diagnosis'
    unchanged
done

it 'P2 uses exactly the gate Rigor grammar and gives the prescribed repair'
for rigor in none two light/full full: 'full,' fullx; do
    transition_project
    case "$rigor" in
        none) printf '# Constitution\n' > "$PROJ/.prdkit/memory/constitution.md" ;;
        two) printf -- '- **Rigor**: light\n- **Rigor**: full\n' > "$PROJ/.prdkit/memory/constitution.md" ;;
        *) printf -- '- **Rigor**: %s medium blocks\n' "$rigor" > "$PROJ/.prdkit/memory/constitution.md" ;;
    esac
    commit_fixture rigor; trusted_tip
    BEFORE="$(git -C "$PROJ" status --porcelain --untracked-files=all)"
    upgrade --migrate-reviews --dry-run
    assert_eq 1 "$STATUS" "$rigor refuses"
    assert_contains "$OUTPUT" 'must hold exactly one Rigor line' 'exact parser diagnosis'
    assert_contains "$OUTPUT" 'full — medium blocks' 'repair uses a space, not a colon'
    assert_contains "$OUTPUT" 'merge that in its own PR first' 'fix trusted policy first'
    if [ "$rigor" = full: ]; then
        assert_contains "$OUTPUT" 'Found: "- **Rigor**: full: medium blocks"' 'exact prescribed offending-line text'
    fi
    unchanged
    upgrade
    assert_eq 0 "$STATUS" 'plain upgrade warns, does not impose migration Rigor prerequisite'
    assert_contains "$OUTPUT" 'must hold exactly one Rigor line' 'plain upgrade warning'
    run bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --check
    assert_contains "$OUTPUT" 'must hold exactly one Rigor line' 'check warning'
done

it 'P3 refuses missing and malformed trusted policy, not a branch-local proposed fix'
for key in review-host review-publishers review-owner review-publisher-isolation; do
    for value in missing invalid; do
        transition_project
        VALID_POLICY="$(cat "$PROJ/.prdkit/memory/config.md")"
        awk -v key="$key" -v value="$value" 'index($0,"- " key ":")==1 { if(value=="invalid") print "- " key ": invalid"; next } { print }' \
            "$PROJ/.prdkit/memory/config.md" > "$PROJ/config.next"
        mv "$PROJ/config.next" "$PROJ/.prdkit/memory/config.md"
        commit_fixture policy; trusted_tip
        upgrade --migrate-reviews --dry-run
        assert_eq 1 "$STATUS" "$key $value refuses"
        assert_contains "$OUTPUT" 'P3:' 'trusted policy diagnosis'
        assert_contains "$OUTPUT" 'Merge all four well-formed receipt policy keys' 'merge-first instruction'
        printf '%s\n' "$VALID_POLICY" > "$PROJ/.prdkit/memory/config.md"
        commit_fixture proposed
        upgrade --migrate-reviews --dry-run
        assert_eq 1 "$STATUS" 'branch-local proposed repair is not trusted policy'
        assert_contains "$OUTPUT" 'P3:' 'policy_at still governs after a local fix'
    done
done

it 'P4 refuses committed record changes relative to the trusted tip'
transition_project
mkdir -p "$PROJ/specs/changes"
printf '# Record\n## State\n' > "$PROJ/specs/changes/001-work.md"
commit_fixture record
upgrade --migrate-reviews --dry-run
assert_eq 1 "$STATUS" 'record edit refuses'
assert_contains "$OUTPUT" 'P4:' 'records-untouched diagnosis'

it 'plain upgrade requires explicit acceptance while trusted or checkout records hold active 1.x lines'
for source in trusted checkout; do
    transition_project
    mkdir -p "$PROJ/specs/changes"
    printf '# Record\n## State\n**Review**: round 1 · old · code · PASS · 0 critical, 0 high, 0 medium, 0 low · text\n' > "$PROJ/specs/changes/001-work.md"
    commit_fixture record
    if [ "$source" = trusted ]; then trusted_tip; fi
    BEFORE="$(git -C "$PROJ" status --porcelain --untracked-files=all)"
    upgrade
    assert_eq 1 "$STATUS" "$source lines refuse"
    assert_contains "$OUTPUT" 'specs/changes/001-work.md' 'record named'
    assert_contains "$OUTPUT" '2.0 stops counting 1.x PASS verdicts' 'explicit transition instruction'
    unchanged
done

it 'a same-source retry accepts rendered command bytes but no unrelated work'
for kind in pristine unrelated edited staged outside wrong-source mode; do
    transition_project
    printf '\nNew version\n' >> "$PROJ/.product-kit/commands/prdkit.md"
    commit_fixture source
    cp "$PROJ/.product-kit/commands/prdkit.md" "$PROJ/.claude/commands/prdkit.md"
    printf 'source-version: 2.0.0\nphase: file\n' > "$PROJ/.prdkit/.install-state"
    case "$kind" in
        unrelated) printf edit > "$PROJ/unrelated" ;;
        edited) printf edit >> "$PROJ/.claude/commands/prdkit-inbox.md" ;;
        staged) git -C "$PROJ" add .claude/commands/prdkit.md ;;
        outside) printf '\nOutside edit\n' >> "$PROJ/AGENTS.md" ;;
        wrong-source) printf 'source-version: 2.0.1\n' > "$PROJ/.prdkit/.install-state" ;;
        mode) chmod +x "$PROJ/.claude/commands/prdkit.md" ;;
    esac
    upgrade --migrate-reviews --dry-run
    if [ "$kind" = pristine ]; then assert_eq 0 "$STATUS" 'validated rendered intermediate state accepted'
    else assert_eq 1 "$STATUS" "$kind still refuses"; fi
done
it 'ignored and committed customized commands refuse before the first mutation, also on retry'
for kind in ignored committed retired managed; do
    for attempt in first retry; do
        transition_project
        case "$kind" in
            ignored)
                printf '\n.claude/commands/prdkit.md\n' >> "$PROJ/.gitignore"
                git -C "$PROJ" rm --cached -q .claude/commands/prdkit.md
                commit_fixture ignore
                printf '\nUser command\n' >> "$PROJ/.claude/commands/prdkit.md" ;;
            committed)
                printf '\nUser command\n' >> "$PROJ/.claude/commands/prdkit.md"
                commit_fixture customization ;;
            retired)
                printf 'Pristine retired helper\n' > "$PROJ/.prdkit/scripts/bash/retired.sh"
                printf '%s  .prdkit/scripts/bash/retired.sh\n' "$( (sha256sum "$PROJ/.prdkit/scripts/bash/retired.sh" 2>/dev/null || shasum -a 256 "$PROJ/.prdkit/scripts/bash/retired.sh") | cut -d' ' -f1)" >> "$PROJ/.prdkit/.manifest"
                printf 'Customized helper\n' > "$PROJ/.prdkit/scripts/bash/retired.sh"
                commit_fixture customization ;;
            managed)
                mv "$PROJ/AGENTS.md" "$PROJ/CLAUDE.md"
                ln -s CLAUDE.md "$PROJ/AGENTS.md"
                sed 's/## Product-Kit workflow/## Custom workflow/' "$PROJ/CLAUDE.md" > "$PROJ/agents.next"
                mv "$PROJ/agents.next" "$PROJ/CLAUDE.md"
                commit_fixture customization ;;
        esac
        if [ "$attempt" = retry ]; then printf 'source-version: 2.0.0\n' > "$PROJ/.prdkit/.install-state"; fi
        before_manifest="$(cat "$PROJ/.prdkit/.manifest")"
        before_command="$(cat "$PROJ/.claude/commands/prdkit.md")"
        before_status="$(git -C "$PROJ" status --porcelain --untracked-files=all)"
        if [ -f "$PROJ/.prdkit/.install-state" ]; then before_state="$(cat "$PROJ/.prdkit/.install-state")"; else before_state=absent; fi
        upgrade --migrate-reviews
        assert_eq 1 "$STATUS" "$kind customization refuses on $attempt upgrade"
        assert_contains "$OUTPUT" 'nothing was written' 'refusal precedes mutation'
        assert_eq "$before_manifest" "$(cat "$PROJ/.prdkit/.manifest")" 'manifest untouched'
        assert_eq "$before_command" "$(cat "$PROJ/.claude/commands/prdkit.md")" 'early command untouched'
        assert_eq "$before_status" "$(git -C "$PROJ" status --porcelain --untracked-files=all)" 'entire target status unchanged'
        if [ -f "$PROJ/.prdkit/.install-state" ]; then after_state="$(cat "$PROJ/.prdkit/.install-state")"; else after_state=absent; fi
        assert_eq "$before_state" "$after_state" 'no marker is created or advanced before refusal'
    done
done

it 'pristine outdated commands still upgrade'
transition_project
printf '\nNew pristine command\n' >> "$PROJ/.product-kit/commands/prdkit.md"
commit_fixture source
upgrade --migrate-reviews
assert_eq 0 "$STATUS" 'outdated but pristine is safe'
assert_contains "$(cat "$PROJ/.claude/commands/prdkit.md")" 'New pristine command' 'command refreshed'
it 'transition report reuses the scan for default records and open trusted-base PRs, without writes or POST'
transition_project
use_gh_stub
mkdir -p "$PROJ/specs/changes"
CLEAN='0 critical, 0 high, 0 medium, 0 low'
FAIL="**Review**: round 1 · old · code · FAIL · $CLEAN · text"
PASS="**Review**: round 2 · old · code · PASS · $CLEAN · text"
printf '# Record\n## State\n%s\n%s\n' "$FAIL" "$PASS" > "$PROJ/specs/changes/001-merged-open.md"
commit_fixture inherited; trusted_tip
BASE_BRANCH="$(git -C "$PROJ" symbolic-ref --short HEAD)"
git -C "$PROJ" checkout -qb 002-open
printf '# Open\n## State\n%s\n**Review**: round 2 · old · security · PASS · %s · text\n' "${FAIL%text}open-text" "$CLEAN" > "$PROJ/specs/changes/002-open.md"
commit_fixture open
OPEN_HEAD="$(git -C "$PROJ" rev-parse HEAD)"
fx_pr 7 "$OPEN_HEAD" '{"head":{"ref":"002-open"}}'
fx_pr 8 "$OPEN_HEAD" '{"base":{"ref":"untrusted"}}'
git -C "$PROJ" checkout -q "$BASE_BRANCH"
printf 'specs/changes/local-only/\n' >> "$PROJ/.git/info/exclude"
mkdir -p "$PROJ/specs/changes/local-only/empty"
printf 'Untracked ignored bytes\000remain\n' > "$PROJ/specs/changes/local-only/data"
ln -s data "$PROJ/specs/changes/local-only/link"
BEFORE="$(git -C "$PROJ" status --porcelain --untracked-files=all)"
RECORDS_BEFORE="$(tree_snapshot "$PROJ/specs/changes")"
upgrade --migrate-reviews --dry-run --json
assert_eq 0 "$STATUS" "$OUTPUT"
REPORT="$OUTPUT"
assert_eq prdkit.review-transition.v1 "$(printf '%s' "$REPORT" | jq -r .schema)" 'JSON report schema'
assert_eq 1 "$(printf '%s' "$REPORT" | jq .totals.records_with_blockers)" '1.x-cleared FAIL still reported'
assert_eq 1 "$(printf '%s' "$REPORT" | jq .totals.blockers_per_reviewer.code)" 'totals by reviewer'
assert_eq 1 "$(printf '%s' "$REPORT" | jq .totals.open_prs)" 'only trusted-base open PRs listed'
assert_eq 2 "$(printf '%s' "$REPORT" | jq .totals.reviews_owed)" 'one fresh review per owed reviewer'
assert_eq 1 "$(printf '%s' "$REPORT" | jq '.records[0].pass_lines')" 'PASS lines counted, never converted'
assert_eq 3 "$(printf '%s' "$REPORT" | jq '.records[0].legacy_blockers[0].line')" 'raw blob line number'
assert_eq 'legacy FAIL' "$(printf '%s' "$REPORT" | jq -r '.records[0].legacy_blockers[0].reason')" 'same gate reason'
assert_eq '["code","security"]' "$(printf '%s' "$REPORT" | jq -c '.open_prs[0].reviews_owed')" 'FAIL clearer and PASS reviewer owe native reviews'
assert_eq 1 "$(printf '%s' "$REPORT" | jq '.open_prs[0].legacy_blockers|length')" 'open PR history scanned'
assert_not_contains "$(cat "$GH_STUB_DIR/requests")" POST 'report never posts'
assert_eq "$RECORDS_BEFORE" "$(tree_snapshot "$PROJ/specs/changes")" 'JSON report leaves every record entry unchanged'
unchanged
upgrade --migrate-reviews --dry-run
assert_eq 0 "$STATUS" "$OUTPUT"
assert_contains "$OUTPUT" 'Record specs/changes/001-merged-open.md' 'text report names record'
assert_contains "$OUTPUT" 'code at line 3: legacy FAIL' 'text report names reviewer, raw line and reason'
assert_contains "$OUTPUT" 'Open PR #7' 'text report names PR'
assert_not_contains "$(cat "$GH_STUB_DIR/requests")" POST 'text report never posts'
assert_eq "$RECORDS_BEFORE" "$(tree_snapshot "$PROJ/specs/changes")" 'text report leaves every record entry unchanged'
unchanged

it 'API failure is reported, not an upgrade blocker'
run env GH_STUB_OFFLINE=true bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade --migrate-reviews --dry-run --json
assert_eq 0 "$STATUS" "$OUTPUT"
assert_contains "$OUTPUT" 'host API is unavailable' 'API omission explicit'
assert_not_contains "$(cat "$GH_STUB_DIR/requests")" POST 'unavailable report never posts'

it 'a missing local PR head is an unavailable scan, not a claim of zero blockers'
fx_pr 7 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa '{"head":{"ref":"002-open"}}'
upgrade --migrate-reviews --dry-run --json
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq false "$(printf '%s' "$OUTPUT" | jq '.open_prs[0].scan_available')" 'absent local head explicit'
assert_contains "$OUTPUT" 'fetch this PR head' 'report never fetches implicitly'

it 'missing gh leaves the default-branch report available with a note'
TOOLS="$(mktemp -d)"; track_tmp "$TOOLS"
for tool in bash dirname basename git head tail tr awk sed grep cat mktemp rm mkdir mv cp chmod ln readlink cut cmp sort jq wc sha256sum shasum; do
    tool_path="$(command -v "$tool")" || continue
    ln -s "$tool_path" "$TOOLS/$tool"
done
run env PATH="$TOOLS" bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade --migrate-reviews --dry-run --json
assert_eq 0 "$STATUS" "$OUTPUT"
assert_contains "$OUTPUT" 'gh is missing' 'missing host tool noted'
assert_eq 1 "$(printf '%s' "$OUTPUT" | jq .totals.records_with_blockers)" 'default records still complete'
unchanged

it 'installing migration writes kit files only and never publishes or changes a record'
RECORDS_BEFORE="$(tree_snapshot "$PROJ/specs/changes")"
upgrade --migrate-reviews
assert_eq 0 "$STATUS" "$OUTPUT"
assert_not_contains "$(cat "$GH_STUB_DIR/requests")" POST 'install never posts'
assert_eq "$RECORDS_BEFORE" "$(tree_snapshot "$PROJ/specs/changes")" 'install leaves all record paths, types and bytes unchanged'
it 'check and doctor list records with 1.x blockers, but not clean PASS-only records'
commit_fixture upgraded
mkdir -p "$PROJ/specs/changes"
printf '# Clean\n## State\n%s\n' "$PASS" > "$PROJ/specs/changes/003-clean.md"
commit_fixture clean
run bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --check
assert_contains "$OUTPUT" 'Legacy 1.x blocking lines: specs/changes/001-merged-open.md (code: legacy FAIL)' 'check lists standing legacy debt'
assert_not_contains "$OUTPUT" 'Legacy 1.x blocking lines: specs/changes/003-clean.md' 'clean PASS is not a blocker'
run bash "$PROJ/.prdkit/scripts/bash/doctor.sh" --json
assert_contains "$OUTPUT" 'Legacy 1.x blocking lines: specs/changes/001-merged-open.md' 'doctor JSON advisory names record'
assert_not_contains "$OUTPUT" 'Legacy 1.x blocking lines: specs/changes/003-clean.md' 'doctor never turns PASS into a blocker'
assert_not_contains "$(cat "$GH_STUB_DIR/requests")" POST 'diagnostics do not publish'
it 'real interrupted installs retry only validated same-source states under both upgrade flags'
REAL_MV="$(command -v mv)"; REAL_RM="$(command -v rm)"; export REAL_MV REAL_RM
FAULTS="$(mktemp -d)"; track_tmp "$FAULTS"
cat > "$FAULTS/mv" <<'EOF'
#!/usr/bin/env bash
if [ "${!#}" = "$FAULT_ROOT/.prdkit/templates/change-template.md" ] && [ "$FAULT_PHASE" = template ]; then exit 73; fi
exec "$REAL_MV" "$@"
EOF
cat > "$FAULTS/rm" <<'EOF'
#!/usr/bin/env bash
if [ "${!#}" = "$FAULT_ROOT/.prdkit/.install-state" ] && [ "$FAULT_PHASE" = published ]; then exit 74; fi
exec "$REAL_RM" "$@"
EOF
chmod +x "$FAULTS/mv" "$FAULTS/rm"
for flag in plain migrate; do
    for phase in template published; do
        transition_project
        printf '\nNew command bytes\n' >> "$PROJ/.product-kit/commands/prdkit.md"
        printf '\nNew template bytes\n' >> "$PROJ/.product-kit/templates/change-template.md"
        commit_fixture source
        args=(); [ "$flag" != migrate ] || args=(--migrate-reviews)
        run env PATH="$FAULTS:$PATH" FAULT_ROOT="$PROJ" FAULT_PHASE="$phase" bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade "${args[@]}"
        assert_eq 1 "$([ "$STATUS" -ne 0 ] && echo 1 || echo 0)" "$phase fails at a real boundary"
        assert_contains "$OUTPUT" 'Incomplete install' 'interruption stays explicit'
        assert_contains "$(cat "$PROJ/.claude/commands/prdkit.md")" 'New command bytes' 'tracked command really was replaced'
        assert_file "$PROJ/.prdkit/.install-state" 'same-source marker retained'
        upgrade "${args[@]}"
        assert_eq 0 "$STATUS" "real same-source retry ($flag/$phase): $OUTPUT"
        assert_contains "$(cat "$PROJ/.prdkit/templates/change-template.md")" 'New template bytes' 'retry installs complete target'
        assert_not_contains "$(cat "$GH_STUB_DIR/requests")" POST 'interruption/retry never posts'
    done
done

it 'a symlink-mode retry after manifest publication renders the same complete manifest'
transition_project
run bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade --symlink
assert_eq 0 "$STATUS" "$OUTPUT"
commit_fixture symlinks
printf '\nNew symlink-source bytes\n' >> "$PROJ/.product-kit/commands/prdkit.md"
commit_fixture source
run env PATH="$FAULTS:$PATH" FAULT_ROOT="$PROJ" FAULT_PHASE=published bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade --migrate-reviews
assert_eq 1 "$([ "$STATUS" -ne 0 ] && echo 1 || echo 0)" 'publication really interrupted'
upgrade --migrate-reviews
assert_eq 0 "$STATUS" "$OUTPUT"
assert_symlink "$PROJ/.claude/commands/prdkit.md" 'retry keeps command mode'

it 'retry refuses an outside-managed edit even when it matches awk newline normalization'
transition_project
printf '\nOutside bytes without final newline' >> "$PROJ/AGENTS.md"
commit_fixture outside
printf '\n' >> "$PROJ/AGENTS.md"
printf 'source-version: 2.0.0\n' > "$PROJ/.prdkit/.install-state"
upgrade --migrate-reviews --dry-run
assert_eq 1 "$STATUS" 'outside bytes must equal HEAD exactly'
assert_contains "$OUTPUT" 'outside the managed section' 'outside-byte diagnosis'

it 'retry accepts a rendered managed section, including a resolved root-file target'
for mode in regular alias; do
    transition_project
    if [ "$mode" = alias ]; then mv "$PROJ/AGENTS.md" "$PROJ/CLAUDE.md"; ln -s CLAUDE.md "$PROJ/AGENTS.md"; fi
    sed 's/## Product-Kit workflow/## Product-Kit workflow upgraded/' "$PROJ/.product-kit/scripts/install-lib.sh" > "$PROJ/source.next"
    mv "$PROJ/source.next" "$PROJ/.product-kit/scripts/install-lib.sh"
    commit_fixture source
    sed 's/## Product-Kit workflow/## Product-Kit workflow upgraded/' "$PROJ/AGENTS.md" > "$PROJ/agents.next"
    cat "$PROJ/agents.next" > "$PROJ/AGENTS.md"; rm "$PROJ/agents.next"
    printf 'source-version: 2.0.0\n' > "$PROJ/.prdkit/.install-state"
    upgrade --migrate-reviews --dry-run
    assert_eq 0 "$STATUS" "$mode rendered section: $OUTPUT"
done

it 'a real managed-section replacement preserves a suffix without a final newline through retry'
transition_project
printf '\nOutside bytes without final newline' >> "$PROJ/AGENTS.md"
sed 's/## Product-Kit workflow/## Product-Kit workflow upgraded/' "$PROJ/.product-kit/scripts/install-lib.sh" > "$PROJ/source.next"
mv "$PROJ/source.next" "$PROJ/.product-kit/scripts/install-lib.sh"
commit_fixture source
run env PATH="$FAULTS:$PATH" FAULT_ROOT="$PROJ" FAULT_PHASE=published bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade --migrate-reviews
assert_eq 1 "$([ "$STATUS" -ne 0 ] && echo 1 || echo 0)" 'managed section was installed before interruption'
assert_eq e "$(tail -c 1 "$PROJ/AGENTS.md")" 'consumer final byte was not normalized'
upgrade --migrate-reviews
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq e "$(tail -c 1 "$PROJ/AGENTS.md")" 'retry keeps consumer final byte'

it 'a failed constitution read cannot masquerade as valid Rigor after printing policy bytes'
transition_project
GIT_FAULT="$(mktemp -d)"; track_tmp "$GIT_FAULT"
REAL_GIT="$(command -v git)"; export REAL_GIT
cat > "$GIT_FAULT/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in *' show '*':.prdkit/memory/constitution.md '*) "$REAL_GIT" "$@"; exit 71 ;; esac
exec "$REAL_GIT" "$@"
EOF
chmod +x "$GIT_FAULT/git"
run env PATH="$GIT_FAULT:$PATH" bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade --migrate-reviews --dry-run
assert_eq 1 "$STATUS" 'object failure refuses despite valid-looking output'
assert_contains "$OUTPUT" 'cannot be read completely' 'object failure is not absence or valid policy'

it 'open PR fresh reviews exclude PASS lines in untouched unrelated default-branch records'
transition_project
use_gh_stub
mkdir -p "$PROJ/specs/changes"
printf '# Unrelated\n## State\n**Review**: round 1 · old · security · PASS · %s · text\n' "$CLEAN" > "$PROJ/specs/changes/003-unrelated.md"
commit_fixture inherited; trusted_tip
BASE_BRANCH="$(git -C "$PROJ" symbolic-ref --short HEAD)"
git -C "$PROJ" checkout -qb 002-open
printf '# Open\n## State\n%s\n' "$PASS" > "$PROJ/specs/changes/002-open.md"
commit_fixture open
fx_pr 7 "$(git -C "$PROJ" rev-parse HEAD)" '{"head":{"ref":"002-open"}}'
git -C "$PROJ" checkout -q "$BASE_BRANCH"
upgrade --migrate-reviews --dry-run --json
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq '["code"]' "$(printf '%s' "$OUTPUT" | jq -c '.open_prs[0].reviews_owed')" 'unrelated inherited PASS creates no review obligation on this PR'

it 'end to end: upgrade, re-review an open 1.x PR, then close a merged-open legacy record'
transition_project
use_gh_stub
mkdir -p "$PROJ/specs/changes"
printf '# Merged open\n**Tier**: T1\n## State\n%s\n%s\n' "$FAIL" "$PASS" > "$PROJ/specs/changes/001-merged-open.md"
commit_fixture inherited; trusted_tip
BASE_BRANCH="$(git -C "$PROJ" symbolic-ref --short HEAD)"
git -C "$PROJ" checkout -qb 002-open
printf '# Open\n**Tier**: T1\n## State\n%s\n**Review**: round 2 · old · security · PASS · %s · text\n' "${FAIL%text}open-text" "$CLEAN" > "$PROJ/specs/changes/002-open.md"
printf implementation > "$PROJ/source.txt"
commit_fixture implementation
fx_pr 7 "$(git -C "$PROJ" rev-parse HEAD)" '{"head":{"ref":"002-open"}}'
git -C "$PROJ" checkout -q "$BASE_BRANCH"
RECORDS_BEFORE="$(tree_snapshot "$PROJ/specs/changes")"
upgrade --migrate-reviews
assert_eq 0 "$STATUS" "$OUTPUT"
assert_not_contains "$(cat "$GH_STUB_DIR/requests")" POST 'the transition itself never posts'
assert_eq "$RECORDS_BEFORE" "$(tree_snapshot "$PROJ/specs/changes")" 'end-to-end upgrade leaves every record entry unchanged'
commit_fixture upgraded; trusted_tip
git -C "$PROJ" checkout -q 002-open
git -C "$PROJ" merge -qm 'merge upgraded default' "$BASE_BRANCH" || exit 1
fx_pr 7 "$(git -C "$PROJ" rev-parse HEAD)" '{"head":{"ref":"002-open"}}'
gate_upgrade_fixture() {
    run bash "$PROJ/.prdkit/scripts/bash/check-review.sh" --repo "$PROJ" --json --pr "https://github.com/owner/repo/pull/$1" "$2"
}
publish_upgrade_fixture() {
    local pr="$1" change="$2" reviewer="$3"; shift 3
    # The publisher entry point is trusted kit source; --repo supplies only local fixture objects.
    run bash "$PK_ROOT/scripts/publish-review.sh" "$change" --repo "$PROJ" --pr "https://github.com/owner/repo/pull/$pr" \
        --reviewer "$reviewer" --verdict PASS --counts 0,0,0,0 --report https://example.invalid/report --head HEAD "$@"
    assert_eq 0 "$STATUS" "$OUTPUT"
}
gate_upgrade_fixture 7 002-open
assert_eq 1 "$STATUS" '1.x PASS is not native coverage'
assert_contains "$OUTPUT" 'legacy blocker' 'open PR legacy FAIL stands'
publish_upgrade_fixture 7 002-open security
gate_upgrade_fixture 7 002-open
assert_eq 1 "$STATUS" 'another reviewer coverage does not clear code FAIL'
assert_eq 1 "$(printf '%s' "$OUTPUT" | jq '[.legacy_blockers[]|select(.cleared==false)]|length')" 'exactly its own legacy blocker remains'
publish_upgrade_fixture 7 002-open code
gate_upgrade_fixture 7 002-open
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq true "$(printf '%s' "$OUTPUT" | jq '.legacy_blockers[0].cleared')" 'full native same-reviewer PASS clears open PR'

git -C "$PROJ" checkout -q "$BASE_BRANCH"
git -C "$PROJ" checkout -qb 003-close
rm "$PROJ/specs/changes/001-merged-open.md"
printf -- '- 2026-01-01 001-merged-open: closed\n' > "$PROJ/specs/log.md"
commit_fixture closing
fx_pr 9 "$(git -C "$PROJ" rev-parse HEAD)" '{"head":{"ref":"003-close"}}'
gate_upgrade_fixture 9 001-merged-open
assert_eq 1 "$STATUS" '1.x-cleared inherited FAIL still blocks closing'
assert_eq true "$(printf '%s' "$OUTPUT" | jq .record_only)" 'closing has genuinely empty content'
publish_upgrade_fixture 9 001-merged-open code --clears-legacy
gate_upgrade_fixture 9 001-merged-open
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq true "$(printf '%s' "$OUTPUT" | jq '.legacy_blockers[0].cleared')" 'native full PASS permits record-only closing'
it 'F1: root-file aliases cannot exempt customized retired files on first upgrade or retry'
for attempt in first retry; do
    transition_project
    printf 'Pristine retired helper\n' > "$PROJ/.prdkit/scripts/bash/retired.sh"
    pristine="$( (sha256sum "$PROJ/.prdkit/scripts/bash/retired.sh" 2>/dev/null || shasum -a 256 "$PROJ/.prdkit/scripts/bash/retired.sh") | cut -d' ' -f1)"
    printf '%s  .prdkit/scripts/bash/retired.sh\n' "$pristine" >> "$PROJ/.prdkit/.manifest"
    printf 'User content must survive\n' >> "$PROJ/.prdkit/scripts/bash/retired.sh"
    rm "$PROJ/AGENTS.md"
    ln -s .prdkit/scripts/bash/retired.sh "$PROJ/AGENTS.md"
    commit_fixture alias
    if [ "$attempt" = retry ]; then printf 'phase: file\npath: .claude/commands/prdkit.md\nsource-version: 2.0.0\n' > "$PROJ/.prdkit/.install-state"; fi
    before="$(tree_snapshot "$PROJ")"
    upgrade --migrate-reviews
    assert_eq 1 "$STATUS" "$attempt retired collision refuses"
    assert_contains "$OUTPUT" 'Root-file edit AGENTS.md overlaps' 'refusal names root-edit role'
    assert_contains "$OUTPUT" 'retired .prdkit/scripts/bash/retired.sh' 'refusal names recorded deletion role'
    assert_eq "$before" "$(tree_snapshot "$PROJ")" 'entire target tree unchanged'
done

it 'F1: external-source symlink rendering cannot mutate source or target through a root alias'
for root in AGENTS.md .gitignore; do
    transition_project
    EXTERNAL="$(mktemp -d)"; track_tmp "$EXTERNAL"
    cp -R "$PROJ/.product-kit/." "$EXTERNAL/"
    printf '\nExternal source sentinel\n' >> "$EXTERNAL/commands/prdkit.md"
    rm "$PROJ/$root"
    ln -s .claude/commands/prdkit.md "$PROJ/alias-hop"
    ln -s alias-hop "$PROJ/$root"
    commit_fixture alias
    before="$(tree_snapshot "$PROJ")"; source_before="$(tree_snapshot "$EXTERNAL")"
    run bash "$EXTERNAL/scripts/init.sh" --target "$PROJ" --upgrade --migrate-reviews --dry-run --symlink
    assert_eq 1 "$STATUS" "$root command collision refuses before rendering"
    assert_contains "$OUTPUT" "Root-file edit $root overlaps installed .claude/commands/prdkit.md" 'both colliding roles named'
    assert_eq "$before" "$(tree_snapshot "$PROJ")" 'dry-run target tree byte-identical'
    assert_eq "$source_before" "$(tree_snapshot "$EXTERNAL")" 'dry-run external source tree byte-identical'
done

it 'F2: resolved AGENTS and ignore-file writes into records refuse, including multihop aliases'
for root in AGENTS.md .gitignore; do
    transition_project
    mkdir -p "$PROJ/specs/changes"
    printf '# Record\n## State\n' > "$PROJ/specs/changes/001-alias.md"
    rm "$PROJ/$root"
    if [ "$root" = .gitignore ]; then
        ln -s specs/changes/001-alias.md "$PROJ/alias-hop"
        ln -s alias-hop "$PROJ/$root"
    else ln -s specs/changes/001-alias.md "$PROJ/$root"; fi
    commit_fixture alias; trusted_tip
    before="$(tree_snapshot "$PROJ")"; records_before="$(tree_snapshot "$PROJ/specs/changes")"
    upgrade --migrate-reviews
    assert_eq 1 "$STATUS" "$root record collision refuses"
    assert_contains "$OUTPUT" "Root-file edit $root overlaps protected specs/changes/" 'root and protected record roles named'
    assert_eq "$before" "$(tree_snapshot "$PROJ")" 'record collision mutates no target path'
    assert_eq "$records_before" "$(tree_snapshot "$PROJ/specs/changes")" 'all record entries preserved'
done
finish
