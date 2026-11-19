#!/usr/bin/env bash
# Small, explicit installation fixture: independent of the installer mapping under test.
source "$PK_ROOT/scripts/install-lib.sh"
source "$PK_ROOT/scripts/spec-lib.sh"

source_fixture() {
    FIXTURE="$(mktemp -d)" || exit 1
    track_tmp "$FIXTURE"
    FIXTURE="$(CDPATH='' cd "$FIXTURE" && pwd -P)"
    KIT="$FIXTURE/.product-kit"
    mkdir -p "$KIT/scripts" "$KIT/commands" "$KIT/workflows" "$KIT/templates"
    for file in check-adoption.sh common.sh install-lib.sh install-source-lib.sh spec-lib.sh spec-navigation-lib.sh agent-tiers-lib.sh agents-section.md; do
        cp "$PK_ROOT/scripts/$file" "$KIT/scripts/$file" || exit 1
    done
    printf '1.5.0\n' > "$KIT/VERSION"
    printf '# Command\n' > "$KIT/commands/prdkit.md"
    printf '# Workflow\n' > "$KIT/workflows/work.md"
    printf '# Config\n## Configuration\n' > "$KIT/templates/config-template.md"
    git -C "$KIT" init -q
    git -C "$KIT" config user.name test
    git -C "$KIT" config user.email t@example.com
    git -C "$KIT" add -A
    git -C "$KIT" commit -qm source || exit 1
    KIT_PIN="$(git -C "$KIT" rev-parse HEAD)"
    git -C "$FIXTURE" init -q
    git -C "$FIXTURE" config user.name test
    git -C "$FIXTURE" config user.email t@example.com
    mkdir -p "$FIXTURE/.prdkit/scripts/bash" "$FIXTURE/.prdkit/workflows" \
        "$FIXTURE/.prdkit/templates" "$FIXTURE/.prdkit/memory" "$FIXTURE/.claude/commands"
    for file in "$KIT"/scripts/*; do
        cp "$file" "$FIXTURE/.prdkit/scripts/bash/"
        case "$file" in *.sh) chmod +x "$FIXTURE/.prdkit/scripts/bash/${file##*/}" ;; esac
    done
    cp "$KIT/commands/prdkit.md" "$FIXTURE/.claude/commands/"
    cp "$KIT/workflows/work.md" "$FIXTURE/.prdkit/workflows/"
    cp "$KIT/templates/config-template.md" "$FIXTURE/.prdkit/templates/"
    cp "$KIT/templates/config-template.md" "$FIXTURE/.prdkit/memory/config.md"
    cp "$KIT/scripts/agents-section.md" "$FIXTURE/AGENTS.md"
    {
        printf 'version: 1.5.0\nharnesses: claude agents\nmode: copy\noptions: none\n'
        printf 'agents-section: %s\n' "$(install_hash_stream < "$KIT/scripts/agents-section.md")"
        for file in "$FIXTURE"/.prdkit/scripts/bash/* "$FIXTURE"/.prdkit/workflows/* \
            "$FIXTURE"/.prdkit/templates/* "$FIXTURE"/.prdkit/memory/* "$FIXTURE"/.claude/commands/*; do
            printf '%s  %s\n' "$(install_hash_stream < "$file")" "${file#"$FIXTURE"/}"
        done
    } > "$FIXTURE/.prdkit/.manifest"
    git -C "$FIXTURE" update-index --add --cacheinfo "160000,$KIT_PIN,.product-kit"
    fixture_commit
    CHECKER="$FIXTURE/.prdkit/scripts/bash/check-adoption.sh"
}

fixture_commit() {
    git -C "$FIXTURE" add -A
    git -C "$FIXTURE" commit -qm case --allow-empty || exit 1
}

fixture_check() { run bash "$CHECKER" --require-source --json "$@"; }
fixture_reject() {
    fixture_check "$@"
    # shellcheck disable=SC2153 # STATUS is assigned by run() in tests/lib.sh.
    assert_eq 1 "$STATUS" 'invalid installation is refused'
    assert_contains "$OUTPUT" '"source_verification":"failed"' 'never source verified'
}

# Raw state, not porcelain. Includes records, full indexes/configs/refs/object inventories,
# bytes, types and permission bits in both nested repositories. Hashing never stores objects.
fixture_snapshot() (
    local root="$1" paths rows path mode
    paths="$(mktemp)"; rows="$(mktemp)" || return 1
    trap 'rm -f "$paths" "$rows"' EXIT
    cd "$root" || return 1
    find . -print0 > "$paths" || return 1
    while IFS= read -r -d '' path; do
        # shellcheck disable=SC2012 # Read only the fixed type/permission field.
        mode="$(LC_ALL=C ls -ld "$path" | awk '{print $1}')" || return 1
        { printf '%s\000%s\000' "$path" "$mode"
          if [ -L "$path" ]; then readlink "$path"
          elif [ -f "$path" ]; then cat "$path"; fi
        } | "$REAL_GIT" hash-object --stdin >> "$rows" || return 1
    done < "$paths"
    LC_ALL=C sort "$rows" | "$REAL_GIT" hash-object --stdin
)
