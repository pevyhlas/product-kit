#!/usr/bin/env bash
# Upgrade preflight, recovery, and retirement of old kit-owned files.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
use_gh_stub
source "$PK_ROOT/scripts/install-lib.sh"

# Run the whole suite with BSD's zero-byte restriction, including the existing
# byte-zero managed sections, resolved aliases and interrupted-install fixtures.
BSD_HEAD="$(mktemp -d)"; track_tmp "$BSD_HEAD"
BSD_REAL_HEAD="$(command -v head)"; export BSD_REAL_HEAD
BSD_HEAD_ZERO_LOG="$BSD_HEAD/zero-calls"; export BSD_HEAD_ZERO_LOG
: > "$BSD_HEAD_ZERO_LOG"
cat > "$BSD_HEAD/head" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -c ] && [ "${2:-}" = 0 ]; then
    printf 'head -c 0\n' >> "$BSD_HEAD_ZERO_LOG"
    echo 'head: illegal byte count -- 0' >&2
    exit 1
fi
if [ "${1:-}" = -c ] && [ "${BSD_HEAD_READ_FAIL:-false}" = true ]; then
    echo 'head: injected read failure' >&2
    exit 73
fi
exec "$BSD_REAL_HEAD" "$@"
EOF
chmod +x "$BSD_HEAD/head"
export PATH="$BSD_HEAD:$PATH"

commit_fixture() { git -C "$PROJ" add -A && git -C "$PROJ" commit -qm "$1" || exit 1; }
trusted_tip() {
    git -C "$PROJ" update-ref refs/remotes/origin/main HEAD
    git -C "$PROJ" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}
make_transition_seed() {
    PROJ="$(make_inited_project --copy)"; track_tmp "$PROJ"
    PROJ="$(cd "$PROJ" && pwd -P)"
    git -C "$PROJ" remote add origin https://github.com/owner/repo.git
    # Keep the installed fixture at 1.5 even when the source already identifies as 2.0.
    sed 's/^version: .*/version: 1.5.0/' "$PROJ/.prdkit/.manifest" > "$PROJ/manifest.next" &&
        mv "$PROJ/manifest.next" "$PROJ/.prdkit/.manifest" || exit 1
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
# Build the common starting history once. Every case changes its own full copy,
# including its own .git directory, ignored files, and installed kit.
TRANSITION_SEED=
transition_project() {
    if [ -z "$TRANSITION_SEED" ]; then
        make_transition_seed || exit 1
        TRANSITION_SEED="$PROJ"
    fi
    PROJ="$(mktemp -d)" || exit 1
    track_tmp "$PROJ"
    PROJ="$(cd "$PROJ" && pwd -P)" || exit 1
    cp -Rp "$TRANSITION_SEED/." "$PROJ/" || exit 1
}
upgrade() { run bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade "$@"; }
retry_marker() {
    printf 'phase: %s\npath: %s\nsource-version: %s\n' "${2:-file}" "${1:-.claude/commands/prdkit.md}" "${3:-2.0.0}" > "$PROJ/.prdkit/.install-state"
}
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

it 'BSD byte-prefix reads handle zero and propagate actual read failures'
printf x > "$BSD_HEAD/one-byte"
run head -c 0 "$BSD_HEAD/one-byte"
assert_eq 1 "$STATUS" 'the shim really rejects GNU-compatible head -c 0'
assert_contains "$OUTPUT" 'illegal byte count -- 0' 'BSD rejection reproduced on Linux'
: > "$BSD_HEAD_ZERO_LOG"
run install_head_bytes 0 "$BSD_HEAD/one-byte"
assert_eq 0 "$STATUS" 'install-lib reads an empty prefix of a one-byte file portably'
assert_eq '' "$OUTPUT" 'an empty prefix emits no bytes'
run install_head_bytes 0 "$BSD_HEAD/missing"
if [ "$STATUS" -ne 0 ]; then _ok 'zero-length reads still reject missing input'; else _no 'missing input was accepted as empty evidence'; fi
# shellcheck disable=SC2016 # The child shell expands its own positional arguments.
run env BSD_HEAD_READ_FAIL=true bash -c 'source "$1/scripts/install-lib.sh"; install_head_bytes 1 "$2"' _ "$PK_ROOT" "$BSD_HEAD/one-byte"
assert_eq 73 "$STATUS" 'positive head read errors propagate without an empty fallback'
assert_eq x "$(cat "$BSD_HEAD/one-byte")" 'byte-prefix reads preserve input bytes'

it 'P1 refuses staged, unstaged and untracked work before any target mutation'
for kind in staged unstaged untracked; do
    transition_project
    case "$kind" in
        staged) printf edit >> "$PROJ/AGENTS.md"; git -C "$PROJ" add AGENTS.md ;;
        unstaged) printf edit >> "$PROJ/AGENTS.md" ;;
        untracked) printf edit > "$PROJ/unrelated" ;;
    esac
    BEFORE="$(git -C "$PROJ" status --porcelain --untracked-files=all)"
    upgrade --dry-run
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
    upgrade --dry-run
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

it 'upgrading a receipt-gated installation leaves its data alone and reports retirement once'
transition_project
sed 's/^version: 1.5.0$/version: 2.0.0/' "$PROJ/.prdkit/.manifest" > "$PROJ/manifest.next"
mv "$PROJ/manifest.next" "$PROJ/.prdkit/.manifest"
mkdir -p "$PROJ/specs/changes"
printf '# Record\n## State\n**Review**: legacy FAIL\n' > "$PROJ/specs/changes/001-work.md"
old=.prdkit/scripts/bash/review-receipts-lib.sh
printf '# retired library\n' > "$PROJ/$old"
printf '%s  %s\n' "$(install_hash_stream < "$PROJ/$old")" "$old" >> "$PROJ/.prdkit/.manifest"
mkdir -p "$PROJ/.prdkit/cache/receipts"
printf 'historical review record\n' > "$PROJ/.prdkit/cache/receipts/old"
commit_fixture installed; trusted_tip
printf '2.0.1\n' > "$PROJ/.product-kit/VERSION"; commit_fixture pin
upgrade
assert_eq 0 "$STATUS" "$OUTPUT"
assert_contains "$(cat "$PROJ/.prdkit/.manifest")" 'version: 2.0.1'
assert_contains "$(cat "$PROJ/specs/changes/001-work.md")" '**Review**: legacy FAIL'

assert_contains "$OUTPUT" 'Existing review receipts are ignored; you may delete them.'
assert_eq 'historical review record' "$(cat "$PROJ/.prdkit/cache/receipts/old")"
assert_eq absent "$([ -e "$PROJ/$old" ] && echo present || echo absent)"
commit_fixture upgrade
upgrade
assert_eq 0 "$STATUS" "$OUTPUT"
assert_not_contains "$OUTPUT" 'Existing review receipts'

it 'a same-source retry accepts rendered command bytes but no unrelated work'
for kind in pristine unrelated edited staged outside wrong-source mode; do
    transition_project
    printf '\nNew version\n' >> "$PROJ/.product-kit/commands/prdkit.md"
    commit_fixture source
    cp "$PROJ/.product-kit/commands/prdkit.md" "$PROJ/.claude/commands/prdkit.md"
    retry_marker
    case "$kind" in
        unrelated) printf edit > "$PROJ/unrelated" ;;
        edited) printf edit >> "$PROJ/.claude/commands/prdkit-inbox.md" ;;
        staged) git -C "$PROJ" add .claude/commands/prdkit.md ;;
        outside) printf '\nOutside edit\n' >> "$PROJ/AGENTS.md" ;;
        wrong-source) retry_marker .claude/commands/prdkit.md file 2.0.1 ;;
        mode) chmod +x "$PROJ/.claude/commands/prdkit.md" ;;
    esac
    upgrade --dry-run
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
        if [ "$attempt" = retry ]; then retry_marker; fi
        before_manifest="$(cat "$PROJ/.prdkit/.manifest")"
        before_command="$(cat "$PROJ/.claude/commands/prdkit.md")"
        before_status="$(git -C "$PROJ" status --porcelain --untracked-files=all)"
        if [ -f "$PROJ/.prdkit/.install-state" ]; then before_state="$(cat "$PROJ/.prdkit/.install-state")"; else before_state=absent; fi
        upgrade
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
upgrade
assert_eq 0 "$STATUS" 'outdated but pristine is safe'
assert_contains "$(cat "$PROJ/.claude/commands/prdkit.md")" 'New pristine command' 'command refreshed'
it 'real interrupted installs retry only validated same-source states under upgrade'
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
for phase in template published template-unignored; do
    transition_project
    if [ "$phase" = template-unignored ]; then
        grep -vxF '.prdkit/.install-state' "$PROJ/.gitignore" > "$PROJ/ignore.next"
        mv "$PROJ/ignore.next" "$PROJ/.gitignore"
    fi
    printf '\nNew command bytes\n' >> "$PROJ/.product-kit/commands/prdkit.md"
    printf '\nNew template bytes\n' >> "$PROJ/.product-kit/templates/change-template.md"
    commit_fixture source
    run env PATH="$FAULTS:$PATH" FAULT_ROOT="$PROJ" FAULT_PHASE="${phase%-unignored}" bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade
    assert_eq 1 "$([ "$STATUS" -ne 0 ] && echo 1 || echo 0)" "$phase fails at a real boundary"
    assert_contains "$OUTPUT" 'Incomplete install' 'interruption stays explicit'
    assert_contains "$(cat "$PROJ/.claude/commands/prdkit.md")" 'New command bytes' 'tracked command really was replaced'
    assert_file "$PROJ/.prdkit/.install-state" 'same-source marker retained'
    if [ "$phase" = template-unignored ]; then assert_contains "$(git -C "$PROJ" status --porcelain)" '?? .prdkit/.install-state' 'retry really encounters an unignored marker'; fi
    upgrade
    assert_eq 0 "$STATUS" "real same-source retry ($phase): $OUTPUT"
    assert_contains "$(cat "$PROJ/.prdkit/templates/change-template.md")" 'New template bytes' 'retry installs complete target'
    assert_eq '' "$(cat "$GH_STUB_DIR/requests")" 'upgrade and retry need no host access'
done
it 'a symlink-mode retry after manifest publication renders the same complete manifest'
transition_project
run bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade --symlink
assert_eq 0 "$STATUS" "$OUTPUT"
commit_fixture symlinks
printf '\nNew symlink-source bytes\n' >> "$PROJ/.product-kit/commands/prdkit.md"
commit_fixture source
run env PATH="$FAULTS:$PATH" FAULT_ROOT="$PROJ" FAULT_PHASE=published bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade
assert_eq 1 "$([ "$STATUS" -ne 0 ] && echo 1 || echo 0)" 'publication really interrupted'
upgrade
assert_eq 0 "$STATUS" "$OUTPUT"
assert_symlink "$PROJ/.claude/commands/prdkit.md" 'retry keeps command mode'

it 'retry refuses an outside-managed edit even when it matches awk newline normalization'
transition_project
printf '\nOutside bytes without final newline' >> "$PROJ/AGENTS.md"
commit_fixture outside
printf '\n' >> "$PROJ/AGENTS.md"
retry_marker
upgrade --dry-run
assert_eq 1 "$STATUS" 'outside bytes must equal HEAD exactly'
assert_contains "$OUTPUT" 'outside the managed section' 'outside-byte diagnosis'

it 'retry accepts a rendered managed section, including a resolved root-file target'
for mode in regular alias; do
    transition_project
    if [ "$mode" = alias ]; then mv "$PROJ/AGENTS.md" "$PROJ/CLAUDE.md"; ln -s CLAUDE.md "$PROJ/AGENTS.md"; fi
    sed 's/## Product-Kit workflow/## Product-Kit workflow upgraded/' "$PROJ/.product-kit/scripts/agents-section.md" > "$PROJ/source.next"
    mv "$PROJ/source.next" "$PROJ/.product-kit/scripts/agents-section.md"
    commit_fixture source
    sed 's/## Product-Kit workflow/## Product-Kit workflow upgraded/' "$PROJ/AGENTS.md" > "$PROJ/agents.next"
    cat "$PROJ/agents.next" > "$PROJ/AGENTS.md"; rm "$PROJ/agents.next"
    retry_marker
    upgrade --dry-run
    assert_eq 0 "$STATUS" "$mode rendered section: $OUTPUT"
done

it 'a real managed-section replacement preserves a suffix without a final newline through retry'
transition_project
printf '\nOutside bytes without final newline' >> "$PROJ/AGENTS.md"
sed 's/## Product-Kit workflow/## Product-Kit workflow upgraded/' "$PROJ/.product-kit/scripts/agents-section.md" > "$PROJ/source.next"
mv "$PROJ/source.next" "$PROJ/.product-kit/scripts/agents-section.md"
commit_fixture source
run env PATH="$FAULTS:$PATH" FAULT_ROOT="$PROJ" FAULT_PHASE=published bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade
assert_eq 1 "$([ "$STATUS" -ne 0 ] && echo 1 || echo 0)" 'managed section was installed before interruption'
assert_eq e "$(tail -c 1 "$PROJ/AGENTS.md")" 'consumer final byte was not normalized'
upgrade
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
run env PATH="$GIT_FAULT:$PATH" bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade --dry-run
assert_eq 1 "$STATUS" 'object failure refuses despite valid-looking output'
assert_contains "$OUTPUT" 'cannot be read completely' 'object failure is not absence or valid policy'

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
    upgrade
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
    run bash "$EXTERNAL/scripts/init.sh" --target "$PROJ" --upgrade --dry-run --symlink
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
    upgrade
    assert_eq 1 "$STATUS" "$root record collision refuses"
    assert_contains "$OUTPUT" "Root-file edit $root overlaps protected specs/changes/" 'root and protected record roles named'
    assert_eq "$before" "$(tree_snapshot "$PROJ")" 'record collision mutates no target path'
    assert_eq "$records_before" "$(tree_snapshot "$PROJ/specs/changes")" 'all record entries preserved'
done
it 'F6: every dirty local submodule is refused on retry without changing any evidence'
for module_kind in tracked untracked source; do
    transition_project
    MODULE_SOURCE="$(mktemp -d)"; track_tmp "$MODULE_SOURCE"
    if [ "$module_kind" = source ]; then
        cp -R "$PROJ/.product-kit/." "$MODULE_SOURCE/"
        module=.product-kit
    else printf 'Tracked module bytes\n' > "$MODULE_SOURCE/tracked"; module=vendor/probe; fi
    git -C "$MODULE_SOURCE" init -q
    git -C "$MODULE_SOURCE" config user.name test
    git -C "$MODULE_SOURCE" config user.email t@example.com
    git -C "$MODULE_SOURCE" add -A && git -C "$MODULE_SOURCE" commit -qm source || exit 1
    if [ "$module_kind" = source ]; then git -C "$PROJ" rm -qr .product-kit || exit 1; fi
    git -C "$PROJ" -c protocol.file.allow=always submodule add -q "$MODULE_SOURCE" "$module" || exit 1
    commit_fixture submodule; trusted_tip
    case "$module_kind" in
        tracked) printf 'Dirty tracked bytes\n' >> "$PROJ/$module/tracked" ;;
        untracked) printf 'Untracked module bytes\n' > "$PROJ/$module/untracked" ;;
        source) printf '\nUncommitted source command\n' >> "$PROJ/$module/commands/prdkit.md" ;;
    esac
    retry_marker
    assert_contains "$(git -C "$PROJ" status --porcelain --ignore-submodules=none)" "$module" 'porcelain really reports the dirty submodule'
    before="$(tree_snapshot "$PROJ")"
    index_before="$(git hash-object "$PROJ/.git/index")"
    module_index="$(git -C "$PROJ/$module" rev-parse --absolute-git-dir)/index"
    module_index_before="$(git hash-object "$module_index")"
    manifest_before="$(git hash-object "$PROJ/.prdkit/.manifest")"; marker_before="$(git hash-object "$PROJ/.prdkit/.install-state")"
    upgrade
    assert_eq 1 "$STATUS" "$module_kind submodule refuses on retry"
    assert_contains "$OUTPUT" "installer-owned intermediate state: $module" 'P1 refuses the actual porcelain entry'
    assert_eq "$before" "$(tree_snapshot "$PROJ")" 'all checkout and module bytes unchanged'
    assert_eq "$index_before" "$(git hash-object "$PROJ/.git/index")" 'root index bytes unchanged'
    assert_eq "$module_index_before" "$(git hash-object "$module_index")" 'module index bytes unchanged'
    assert_eq "$manifest_before" "$(git hash-object "$PROJ/.prdkit/.manifest")" 'manifest bytes unchanged'
    assert_eq "$marker_before" "$(git hash-object "$PROJ/.prdkit/.install-state")" 'marker bytes unchanged'
done

it 'F6: preserved conffile bytes, type and mode independently exercise P1 content validation'
for kind in bytes type mode; do
    transition_project
    printf '\nRendered command\n' >> "$PROJ/.product-kit/commands/prdkit.md"
    commit_fixture source
    cp "$PROJ/.product-kit/commands/prdkit.md" "$PROJ/.claude/commands/prdkit.md"
    retry_marker
    case "$kind" in
        bytes) printf '\nUser conffile bytes\n' >> "$PROJ/.prdkit/templates/change-template.md" ;;
        type) rm "$PROJ/.prdkit/templates/change-template.md"; ln -s product-template.md "$PROJ/.prdkit/templates/change-template.md" ;;
        mode) chmod +x "$PROJ/.prdkit/templates/change-template.md" ;;
    esac
    before="$(tree_snapshot "$PROJ")"
    upgrade --dry-run
    assert_eq 1 "$STATUS" "$kind mismatch refuses independently of conffile preservation"
    assert_contains "$OUTPUT" 'not a validated intermediate state (bytes, type or mode): .prdkit/templates/change-template.md' 'P1 comparison is the refusal, not the overwrite check'
    assert_eq "$before" "$(tree_snapshot "$PROJ")" 'mismatched conffile remains unchanged'
done

it 'F9: unignored runtime metadata is accepted only as a complete same-source installer marker'
for kind in missing duplicate extra wrong-path executable; do
    transition_project
    grep -vxF '.prdkit/.install-state' "$PROJ/.gitignore" > "$PROJ/ignore.next"
    mv "$PROJ/ignore.next" "$PROJ/.gitignore"
    commit_fixture ignore
    retry_marker
    case "$kind" in
        missing) printf 'source-version: 2.0.0\n' > "$PROJ/.prdkit/.install-state" ;;
        duplicate) printf 'phase: file\n' >> "$PROJ/.prdkit/.install-state" ;;
        extra) printf 'unrelated: data\n' >> "$PROJ/.prdkit/.install-state" ;;
        wrong-path) retry_marker unrelated file ;;
        executable) chmod +x "$PROJ/.prdkit/.install-state" ;;
    esac
    before="$(tree_snapshot "$PROJ")"
    upgrade --dry-run
    assert_eq 1 "$STATUS" "$kind marker refuses"
    assert_contains "$OUTPUT" 'not a valid installer marker' 'metadata-specific refusal'
    assert_eq "$before" "$(tree_snapshot "$PROJ")" 'invalid marker and target bytes unchanged'
done
it 'F7: a failing second constitution read cannot substitute partial bytes for validated policy'
for fault_output in empty partial; do
    transition_project
    printf -- '# Constitution\n- **Rigor**: full\n- **Rigor**: light\n' > "$PROJ/.prdkit/memory/constitution.md"
    commit_fixture malformed; trusted_tip
    SECOND_READ="$(mktemp -d)"; track_tmp "$SECOND_READ"
    cat > "$SECOND_READ/git" <<'EOF'
#!/usr/bin/env bash
case " $* " in *' show '*':.prdkit/memory/constitution.md '*)
    n=0; [ ! -f "$RIGOR_COUNTER" ] || read -r n < "$RIGOR_COUNTER"
    n=$((n+1)); printf '%s\n' "$n" > "$RIGOR_COUNTER"
    if [ "$n" -eq 2 ]; then
        if [ "$RIGOR_FAULT_OUTPUT" = partial ]; then printf -- '# Constitution\n- **Rigor**: full\n'; fi
        exit 71
    fi ;;
esac
exec "$REAL_GIT" "$@"
EOF
    chmod +x "$SECOND_READ/git"
    before="$(tree_snapshot "$PROJ")"
    run env PATH="$SECOND_READ:$PATH" RIGOR_COUNTER="$SECOND_READ/count" RIGOR_FAULT_OUTPUT="$fault_output" \
        bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade --dry-run
    assert_eq 1 "$STATUS" "$fault_output second-read fault cannot make malformed complete policy pass"
    assert_contains "$OUTPUT" 'must hold exactly one Rigor line' 'validated complete policy, not a second read, decides Rigor'
    assert_eq 1 "$(cat "$SECOND_READ/count")" 'the second constitution read is eliminated'
    assert_eq "$before" "$(tree_snapshot "$PROJ")" 'failed Rigor prerequisite writes nothing'
done
it 'F8: force never authorizes customized 2.0 command, memory or template overwrites'
for kind in committed ignored memory template; do
    for attempt in first retry; do
        transition_project
        case "$kind" in
            committed)
                dest=.claude/commands/prdkit.md
                printf '\nUser command\n' >> "$PROJ/$dest"
                commit_fixture customization ;;
            ignored)
                dest=.claude/commands/prdkit.md
                printf '\n%s\n' "$dest" >> "$PROJ/.gitignore"
                git -C "$PROJ" rm --cached -q "$dest"
                commit_fixture ignore
                printf '\nIgnored user command\n' >> "$PROJ/$dest" ;;
            memory)
                dest=.prdkit/memory/constitution.md
                printf '\nUser policy must survive\n' >> "$PROJ/$dest"
                commit_fixture customization ;;
            template)
                dest=.prdkit/templates/change-template.md
                printf '\nUser template must survive\n' >> "$PROJ/$dest"
                commit_fixture customization ;;
        esac
        if [ "$attempt" = retry ]; then retry_marker; fi
        before="$(tree_snapshot "$PROJ")"
        upgrade --force
        assert_eq 1 "$STATUS" "$kind force overwrite refuses on $attempt"
        assert_contains "$OUTPUT" "Customized overwrite/delete destination: $dest" 'specific customization refusal survives --force'
        assert_contains "$OUTPUT" 'nothing was written' 'force refusal precedes mutation'
        assert_eq "$before" "$(tree_snapshot "$PROJ")" 'force preserves every target entry and byte'
    done
done
assert_eq '' "$(cat "$BSD_HEAD_ZERO_LOG")" 'all upgrade and install-lib paths avoided head -c 0 under the BSD shim'
finish
