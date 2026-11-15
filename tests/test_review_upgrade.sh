#!/usr/bin/env bash
# The 2.0 review transition uses committed, local history and the host stub only.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

commit_fixture() { git -C "$PROJ" add -A && git -C "$PROJ" commit -qm "$1" || exit 1; }
trusted_tip() {
    git -C "$PROJ" update-ref refs/remotes/origin/main HEAD
    git -C "$PROJ" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}
transition_project() {
    PROJ="$(make_inited_project --copy)"; track_tmp "$PROJ"
    PROJ="$(cd "$PROJ" && pwd -P)"
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
    commit_fixture policy; trusted_tip
}
upgrade() { run bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade "$@"; }
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
        awk -v key="$key" -v value="$value" 'index($0,"- " key ":")==1 { if(value=="invalid") print "- " key ": invalid"; next } { print }' \
            "$PROJ/.prdkit/memory/config.md" > "$PROJ/config.next"
        mv "$PROJ/config.next" "$PROJ/.prdkit/memory/config.md"
        commit_fixture policy; trusted_tip
        upgrade --migrate-reviews --dry-run
        assert_eq 1 "$STATUS" "$key $value refuses"
        assert_contains "$OUTPUT" 'P3:' 'trusted policy diagnosis'
        assert_contains "$OUTPUT" 'Merge all four well-formed receipt policy keys' 'merge-first instruction'
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
        upgrade --migrate-reviews
        assert_eq 1 "$STATUS" "$kind customization refuses on $attempt upgrade"
        assert_contains "$OUTPUT" 'nothing was written' 'refusal precedes mutation'
        assert_eq "$before_manifest" "$(cat "$PROJ/.prdkit/.manifest")" 'manifest untouched'
        assert_eq "$before_command" "$(cat "$PROJ/.claude/commands/prdkit.md")" 'early command untouched'
        assert_eq "$before_status" "$(git -C "$PROJ" status --porcelain --untracked-files=all)" 'entire target status unchanged'
    done
done

it 'pristine outdated commands still upgrade'
transition_project
printf '\nNew pristine command\n' >> "$PROJ/.product-kit/commands/prdkit.md"
commit_fixture source
upgrade --migrate-reviews
assert_eq 0 "$STATUS" 'outdated but pristine is safe'
assert_contains "$(cat "$PROJ/.claude/commands/prdkit.md")" 'New pristine command' 'command refreshed'
finish
