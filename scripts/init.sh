#!/usr/bin/env bash
#
# Product-Kit bootstrap — install the /prdkit-* commands, templates, scripts, and
# .prdkit structure into a project.
#
# Usage (from your project root):
#   bash .product-kit/scripts/init.sh [options]
#
# Options:
#   --copy          Install command files as copies (the default): they work in any
#                   checkout, change worktrees and CI included
#   --symlink       Install command files as relative symlinks into the kit instead; they
#                   resolve only where the kit is checked out (a new change worktree needs
#                   its submodule initialized). The recorded mode wins on later runs; pass
#                   --copy or --symlink to switch
#   --harness LIST  Harness(es) to install commands for: claude|opencode|codex|agents|all
#                   (repeatable; comma- and/or space-separated; an unknown name is an
#                   error; default: the manifest's recorded set, else claude,agents plus
#                   auto-detected harnesses). On an existing install the list must keep
#                   every recorded harness: dropping one is refused (see docs/harnesses.md)
#   --upgrade       Refresh kit-owned files (commands + scripts, always), auto-update
#                   unmodified templates/memory, add new files. Consumer edits to
#                   templates/memory are preserved and listed; edits to kit-owned
#                   commands/scripts are overwritten (and called out in the output).
#   --check         Read-only drift report against the install manifest (no changes)
#   --force         Overwrite project-owned templates/memory from Product-Kit (use with care)
#   --target DIR    Target project root (default: current git root, else cwd)
#   -h, --help      Show this help
#
# The installer records what it ships in .prdkit/.manifest: the kit version,
# selected harnesses, the command install mode, and the pristine sha256 of every
# installed file. That
# manifest is what lets --check and --upgrade tell an outdated file (safe to
# refresh) apart from one the consumer edited (never touched without --force).

set -euo pipefail

# --- Resolve Product-Kit source root (the directory containing this script's parent) ---
# pwd -P everywhere: TARGET can arrive physical (git rev-parse) while these are
# logical; on macOS /var vs /private/var then breaks the relative-symlink prefix match.
SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PK_ROOT="$(CDPATH="" cd "$SCRIPT_DIR/.." && pwd -P)"
source "$SCRIPT_DIR/install-lib.sh"
source "$SCRIPT_DIR/spec-lib.sh"

PK_VERSION="unknown"
[ -f "$PK_ROOT/VERSION" ] && PK_VERSION="$(head -n 1 "$PK_ROOT/VERSION" | tr -d '[:space:]')"

# --- Defaults ---
MODE_COPY=true
MODE_EXPLICIT=false
UPGRADE=false
CHECK=false
FORCE=false
TARGET=""
HARNESS_RAW=""

while [ $# -gt 0 ]; do
    case "$1" in
        --copy) MODE_COPY=true; MODE_EXPLICIT=true ;;
        --symlink) MODE_COPY=false; MODE_EXPLICIT=true ;;
        --upgrade) UPGRADE=true ;;
        --check) CHECK=true ;;
        --force) FORCE=true ;;
        --harness)
            shift
            [ $# -gt 0 ] || { echo "Error: --harness requires a value (claude|opencode|codex|agents|all)" >&2; exit 2; }
            HARNESS_RAW="$HARNESS_RAW,$1"
            ;;
        --target)
            shift
            [ $# -gt 0 ] || { echo "Error: --target requires a directory" >&2; exit 1; }
            TARGET="$1"
            ;;
        -h|--help)
            sed -n '2,/^#   -h, --help/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "Error: unknown option '$1' (use --help)" >&2; exit 1 ;;
    esac
    shift
done

# --- Resolve target project root ---
if [ -z "$TARGET" ]; then
    if git -C "$PWD" rev-parse --show-toplevel >/dev/null 2>&1; then
        TARGET="$(git -C "$PWD" rev-parse --show-toplevel)"
    else
        TARGET="$PWD"
    fi
fi
TARGET="$(CDPATH="" cd "$TARGET" && pwd -P)"

if [ "$TARGET" = "$PK_ROOT" ]; then
    echo "Error: target is the Product-Kit repo itself. Run this from your project root." >&2
    exit 1
fi

CMD_DIR="$TARGET/.claude/commands"
OC_CMD_DIR="$TARGET/.opencode/commands"
PRDKIT_DIR="$TARGET/.prdkit"
TPL_DIR="$PRDKIT_DIR/templates"
MEM_DIR="$PRDKIT_DIR/memory"
SCRIPT_OUT="$PRDKIT_DIR/scripts/bash"
MANIFEST="$PRDKIT_DIR/.manifest"
INITIAL_MANIFEST=absent
[ ! -f "$MANIFEST" ] || INITIAL_MANIFEST="$(install_hash_stream < "$MANIFEST")"

# --- Resolve install harnesses -----------------------------------------------
# Product-Kit's core is markdown + bash, so commands can be installed for more
# than one agent CLI. Verified per-harness targets:
#   claude   → .claude/commands/           (slash commands)
#   opencode → .opencode/commands/         (slash commands)
#   codex    → AGENTS.md managed section   (Codex custom prompts are global-only,
#              never per-project, so its install is the AGENTS.md fallback)
#   agents   → AGENTS.md managed section   (any AGENTS.md-reading harness)
KNOWN_HARNESSES="claude opencode codex agents"

harness_valid() {
    case " $KNOWN_HARNESSES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

HARNESSES=""
add_harness() {
    case " $HARNESSES " in *" $1 "*) return 0 ;; esac
    HARNESSES="${HARNESSES:+$HARNESSES }$1"
}
has_harness() {
    case " $HARNESSES " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

# Recorded harness set of an existing install (empty on a fresh one).
RECORDED_HARNESSES=""
if [ -f "$MANIFEST" ] && grep -q '^harnesses: ' "$MANIFEST"; then
    RECORDED_HARNESSES="$(grep '^harnesses: ' "$MANIFEST" | head -n 1)"
    RECORDED_HARNESSES="${RECORDED_HARNESSES#harnesses: }"
fi

if [ -n "$HARNESS_RAW" ]; then
    # Names separate on commas and/or whitespace. An unknown name fails the run: a typo
    # (or a list glued together without separators) must not silently install less.
    for h in $(printf '%s' "$HARNESS_RAW" | tr ',' ' '); do
        if [ "$h" = "all" ]; then
            for k in $KNOWN_HARNESSES; do add_harness "$k"; done
        elif harness_valid "$h"; then
            add_harness "$h"
        else
            echo "Error: unknown harness '$h' (known: claude, opencode, codex, agents, all; separate several with commas or spaces)." >&2
            echo "       Unlisted AGENTS.md-reading harnesses are served by 'agents'." >&2
            exit 2
        fi
    done
    [ -n "$HARNESSES" ] || { echo "Error: --harness names no harness (claude|opencode|codex|agents|all)" >&2; exit 2; }
    # An explicit list must keep every harness the install records: the manifest drives
    # --check, doctor and the adoption gate, so a dropped harness would leave its command
    # files unrecorded rather than removed. Removing a harness is a deliberate reinstall.
    has_harness codex && add_harness agents
    dropped=""
    for h in $RECORDED_HARNESSES; do
        harness_valid "$h" || continue
        has_harness "$h" || dropped="${dropped:+$dropped, }$h"
    done
    if [ -n "$dropped" ]; then
        echo "Error: --harness '$(printf '%s' "${HARNESS_RAW#,}" | tr ',' ' ')' would drop $dropped, which .prdkit/.manifest records (harnesses: $RECORDED_HARNESSES)." >&2
        echo "       Pass the full list, e.g. --harness $(printf '%s' "$RECORDED_HARNESSES" | tr ' ' ','), or omit --harness to keep the recorded set." >&2
        echo "       Removing a harness is a reinstall decision: see 'Removing a harness' in docs/harnesses.md." >&2
        exit 2
    fi
else
    # A previous install's harness set (recorded in the manifest) wins, so
    # --upgrade and --check keep serving the harnesses the consumer chose.
    if [ -n "$RECORDED_HARNESSES" ]; then
        for h in $RECORDED_HARNESSES; do
            harness_valid "$h" && add_harness "$h"
        done
    else
        add_harness claude
        add_harness agents
        # Auto-detect harnesses already present in the target project — only on
        # a fresh install with no recorded choice; a manifest-recorded set is
        # never widened behind the consumer's back (pass --harness to change it).
        if [ -d "$TARGET/.opencode" ] || [ -e "$TARGET/opencode.json" ] || [ -e "$TARGET/opencode.jsonc" ]; then
            add_harness opencode
        fi
        [ -d "$TARGET/.codex" ] && add_harness codex
    fi
fi
[ -n "$HARNESSES" ] || { add_harness claude; add_harness agents; }
# Codex has no per-project command mechanism — its install is the AGENTS.md section.
has_harness codex && add_harness agents

# The previous install's command mode wins unless --copy/--symlink is passed
# explicitly, so an upgrade never silently flips an install between copies and symlinks.
# Pre-0.10 manifests recorded no mode; infer it from the installed files (any regular
# copy means copies; otherwise an installed symlink means symlinks).
if ! $MODE_EXPLICIT && [ -f "$MANIFEST" ]; then
    if grep -q '^mode: symlink$' "$MANIFEST"; then
        MODE_COPY=false
    elif ! grep -q '^mode: ' "$MANIFEST"; then
        saw_copy=false; saw_link=false
        for probe in "$TARGET/.claude/commands/prdkit.md" "$TARGET/.opencode/commands/prdkit.md"; do
            if [ -L "$probe" ]; then saw_link=true
            elif [ -e "$probe" ]; then saw_copy=true; fi
        done
        if ! $saw_copy && $saw_link; then MODE_COPY=false; fi
    fi
fi

# --- Helpers -----------------------------------------------------------------

# sha256 of a file's content. Follows symlinks, so a symlinked command hashes
# its target content. sha256sum (Linux) with a shasum fallback (macOS).
hash_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

# Emit every file the kit installs as "<kit-source><TAB><path-relative-to-target>".
# This single list drives installation, the manifest, and --check, so the three
# can never disagree about what "installed" means.
list_kit_files() {
    local src base pair
    for src in "$PK_ROOT"/commands/prdkit*.md; do
        [ -e "$src" ] || continue
        if has_harness claude; then
            printf '%s\t%s\n' "$src" ".claude/commands/$(basename "$src")"
        fi
        if has_harness opencode; then
            printf '%s\t%s\n' "$src" ".opencode/commands/$(basename "$src")"
        fi
    done
    for src in "$PK_ROOT"/workflows/*.md; do
        [ -e "$src" ] || continue
        printf '%s\t%s\n' "$src" ".prdkit/workflows/$(basename "$src")"
    done
    for src in "$PK_ROOT"/scripts/*.sh; do
        [ -e "$src" ] || continue
        base="$(basename "$src")"
        [ "$base" = "init.sh" ] && continue   # the bootstrap itself is never installed
        printf '%s\t%s\n' "$src" ".prdkit/scripts/bash/$base"
    done
    for src in "$PK_ROOT"/templates/*.md; do
        [ -e "$src" ] || continue
        printf '%s\t%s\n' "$src" ".prdkit/templates/$(basename "$src")"
    done
    # Memory files are seeded from these templates.
    for pair in \
        "constitution-template.md:constitution.md" \
        "agents-template.md:agents.md" \
        "task-ledger-template.md:task-ledger.md" \
        "config-template.md:config.md"
    do
        src="$PK_ROOT/templates/${pair%%:*}"
        [ -e "$src" ] || continue
        printf '%s\t%s\n' "$src" ".prdkit/memory/${pair##*:}"
    done
}

# Pristine hash recorded in the manifest for a relative path (empty if none).
recorded_hash() {
    local line h p
    [ -f "$MANIFEST" ] || return 0
    while IFS= read -r line; do
        case "$line" in
            version:*|harnesses:*) continue ;;
        esac
        h="${line%%  *}"
        p="${line#*  }"
        if [ "$p" = "$1" ]; then
            printf '%s\n' "$h"
            return 0
        fi
    done < "$MANIFEST"
    return 0
}

# True when an installed file diverges from the pristine hash recorded at install
# time — i.e. the consumer edited it. Used to warn before --upgrade overwrites a
# kit-owned command/script. Returns false on a fresh install (no recorded hash),
# for a symlinked command (hashing follows the link to the kit source), and when
# the file already matches the kit version.
file_locally_edited() {
    local rel="$1" src="$2" dest="$TARGET/$1" cur kit rec
    [ -e "$dest" ] || return 1
    cur="$(hash_file "$dest")"
    kit="$(hash_file "$src")"
    [ "$cur" = "$kit" ] && return 1
    rec="$(recorded_hash "$rel")"
    [ -n "$rec" ] && [ "$cur" != "$rec" ]
}

# True when a command symlink points at the same-named file in the kit's commands/
# directory, in the absolute or relative form this script writes, dangling or not.
is_kit_command_link() {
    local file="$1" target dir kitdir
    target="$(readlink "$file")" || return 1
    case "$target" in /*) ;; *) target="$(dirname "$file")/$target" ;; esac
    [ "$(basename "$target")" = "$(basename "$file")" ] || return 1
    dir="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || return 1
    kitdir="$(cd "$PK_ROOT/commands" 2>/dev/null && pwd -P)" || return 1
    [ "$dir" = "$kitdir" ]
}

# --- Containment ---------------------------------------------------------------
# Every write and deletion stays inside TARGET. Manifest paths are data from a file a pull
# request can edit, so one becomes a filesystem operand only when it names the exact layout the
# kit installs (a single file name, never a `/` or `..` segment); case patterns are no check,
# since `*` also matches `/`. A directory the installer writes into must be a real directory
# inside TARGET, and a kit-owned file is replaced rather than written through a symlink.
NAME_RE='[A-Za-z0-9_][A-Za-z0-9_.-]*'
KIT_FILE_RE="^\\.prdkit/(scripts/bash/$NAME_RE\\.sh|workflows/$NAME_RE\\.md|templates/$NAME_RE\\.md)\$"
INSTALLED_RE="^(\\.(claude|opencode)/commands/$NAME_RE\\.md|\\.prdkit/memory/$NAME_RE\\.md)\$"

# Physical path of a file, following a chain of symlinks (no readlink -f or realpath, which
# macOS lacks). Fails for an unresolvable directory or a chain longer than 40 links.
physical_path() {
    local path="$1" link n=0 dir
    while [ -L "$path" ]; do
        n=$((n + 1)); [ "$n" -le 40 ] || return 1
        link="$(readlink "$path")" || return 1
        case "$link" in /*) path="$link" ;; *) path="$(dirname "$path")/$link" ;; esac
    done
    dir="$(CDPATH="" cd -P -- "$(dirname "$path")" 2>/dev/null && pwd -P)" || return 1
    printf '%s/%s\n' "$dir" "$(basename "$path")"
}

# Prints why an existing directory the installer writes into is unsafe (a symlink, not a
# directory, or resolving outside TARGET) and returns 0; returns 1 when it is safe or absent.
managed_dir_problem() {
    local path="$TARGET/$1" phys
    if [ -L "$path" ]; then printf '%s is a symlink\n' "$1"; return 0; fi
    [ -e "$path" ] || return 1
    if [ ! -d "$path" ]; then printf '%s is not a directory\n' "$1"; return 0; fi
    phys="$(CDPATH="" cd -P -- "$path" 2>/dev/null && pwd -P)" || { printf '%s cannot be resolved\n' "$1"; return 0; }
    case "$phys/" in "$TARGET"/*) return 1 ;; esac
    printf '%s resolves outside the target (%s)\n' "$1" "$phys"
    return 0
}

# Where an in-place edit of a root file (AGENTS.md, .gitignore) lands: the file itself, or, for
# a symlink (AGENTS.md -> CLAUDE.md is common), its physical target while that stays inside
# TARGET. Fails for a link that leads outside TARGET or cannot be resolved.
root_file_path() {
    local path="$TARGET/$1"
    if [ ! -L "$path" ]; then printf '%s\n' "$path"; return 0; fi
    path="$(physical_path "$path")" || return 1
    case "$path" in "$TARGET"/*) printf '%s\n' "$path" ;; *) return 1 ;; esac
}

# Kit-named commands installed in a harness command directory that the current kit no
# longer ships (retired or formerly disabled/unsupported entry points). They would keep
# loading into every session's command listing. Emits "<rel>\t<remove|keep>": remove when
# the previous manifest recorded the file or it is a symlink into the kit's commands/
# directory (kit-installed); keep, with a warning, for anything else the kit cannot prove it
# installed (an unrecorded regular file or a user's own symlink).
list_retired_commands() {
    local dir file name rel
    for dir in .claude/commands .opencode/commands; do
        [ -d "$TARGET/$dir" ] || continue
        # A command directory that is not a real directory inside TARGET is never cleaned (the
        # install refuses it for a selected harness before writing anything).
        if managed_dir_problem "${dir%/*}" >/dev/null || managed_dir_problem "$dir" >/dev/null; then continue; fi
        for file in "$TARGET/$dir"/prdkit*.md; do
            { [ -e "$file" ] || [ -L "$file" ]; } || continue
            name="$(basename "$file")"
            [ -e "$PK_ROOT/commands/$name" ] && continue
            rel="$dir/$name"
            if { [ -L "$file" ] && is_kit_command_link "$file"; } || [ -n "$(recorded_hash "$rel")" ]; then
                printf '%s\tremove\n' "$rel"
            else
                printf '%s\tkeep\n' "$rel"
            fi
        done
    done
}

# Kit-owned scripts/workflows and templates that the previous manifest recorded but the
# current kit no longer ships (for example a retired helper). Emits "<rel>\t<remove|keep>":
# kit-owned files and templates still matching their recorded hash are removed; an edited
# template is project-owned content and is kept with a warning, as is a symlinked one. A
# manifest path outside the installed layout is ignored with a warning, never touched.
list_retired_kit_files() {
    local line rel src
    [ -f "$MANIFEST" ] || return 0
    while IFS= read -r line; do
        case "$line" in version:*|harnesses:*|mode:*|agents-section:*|'') continue ;; esac
        rel="${line#*  }"
        if ! [[ $rel =~ $KIT_FILE_RE ]]; then
            [[ $rel =~ $INSTALLED_RE ]] ||
                printf 'Warning: ignoring a .prdkit/.manifest entry outside the installed layout: %s\n' "$rel" >&2
            continue
        fi
        case "$rel" in
            .prdkit/scripts/bash/*) src="$PK_ROOT/scripts/${rel##*/}" ;;
            .prdkit/workflows/*) src="$PK_ROOT/workflows/${rel##*/}" ;;
            *) src="$PK_ROOT/templates/${rel##*/}" ;;
        esac
        { [ ! -e "$src" ] && [ -f "$TARGET/$rel" ]; } || continue
        case "$rel" in
            .prdkit/templates/*)
                if [ ! -L "$TARGET/$rel" ] && [ "$(hash_file "$TARGET/$rel")" = "${line%%  *}" ]; then printf '%s\tremove\n' "$rel"
                else printf '%s\tkeep\n' "$rel"; fi ;;
            *) printf '%s\tremove\n' "$rel" ;;
        esac
    done < "$MANIFEST"
}

# Project files that reference a kit file this kit does not ship (a retired 0.x helper, template
# or workflow): "<file>\t<name>". CI workflows always; in a git work tree, every other tracked
# file too (project scripts, tests and harness settings), except prose (*.md), recorded diffs
# and specs/. A reference, outside a # comment, is a kit path to a file the kit does not ship
# that is gone from the project or was installed by the kit (the manifest records it; a
# template the project added is its own), or a retired helper's name as a quoted string (a
# script that builds the path). The installer never edits these files.
KIT_PATH_RE='(\.prdkit/(scripts/bash|templates|workflows)|\.product-kit/(scripts|templates|workflows))/[A-Za-z0-9_.-]+\.(sh|md)'
RETIRED_HELPERS='artifact-lib.sh check-artifacts.sh check-canon.sh check-implement-gates.sh
check-prerequisites.sh check-signoff.sh cleanup-feature.sh create-new-feature.sh
evidence-fingerprint.sh evidence-lib.sh parts-lib.sh record-analysis.sh resolve-context.sh
review-scope-lib.sh review-scope.sh setup-plan.sh status-lib.sh update-agent-context.sh'
kit_file_retired() { # installed or kit path -> 0 when the kit does not ship it and it is the kit's
    local kit="${1#.prdkit/}"
    kit="${kit#.product-kit/}"; kit="${kit/#scripts\/bash\//scripts/}"
    [ -e "$PK_ROOT/$kit" ] && return 1
    case "$1" in .product-kit/*) return 0 ;; esac
    [ ! -e "$TARGET/$1" ] && return 0
    [ -f "$MANIFEST" ] && awk -v rel="$1" 'substr($0, index($0, "  ") + 2) == rel { found = 1 } END { exit !found }' "$MANIFEST"
}
list_retired_ci_calls() {
    local file rel ref name alt quoted
    alt="$(printf '%s' "$RETIRED_HELPERS" | tr -s ' \n' '||' | sed 's/[.]/\\./g')"
    quoted="[\"']($alt)[\"']"
    {
        for file in "$TARGET"/.github/workflows/*.yml "$TARGET"/.github/workflows/*.yaml; do
            [ -f "$file" ] && printf '%s\0' "${file#"$TARGET"/}"
        done
        if git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
            set -- . ':(exclude).prdkit' ':(exclude).product-kit' ':(exclude)specs' ':(exclude)*.md' \
                ':(exclude)*.patch' ':(exclude)*.diff'
            git -C "$TARGET" grep -z -I -l -E -e "$KIT_PATH_RE" -e "$quoted" -- "$@" 2>/dev/null || true
        fi
    } | LC_ALL=C sort -z -u | while IFS= read -r -d '' rel; do
        [ -f "$TARGET/$rel" ] || continue
        { grep -vE '^[[:space:]]*#' "$TARGET/$rel" 2>/dev/null || true; } | {
            { grep -oE "$KIT_PATH_RE|$quoted" || true; } | while IFS= read -r ref; do
                case "$ref" in
                    \"*|\'*) name="${ref#?}"; name="${name%?}"; [ "$name" = "${rel##*/}" ] || printf '%s\n' "$name" ;;
                    *) ! kit_file_retired "$ref" || printf '%s\n' "${ref##*/}" ;;
                esac
            done
        } | LC_ALL=C sort -u | while IFS= read -r name; do printf '%s\t%s\n' "$rel" "$name"; done
    done
    return 0
}

# --- --check: read-only drift report ----------------------------------------
if $CHECK; then
    incomplete=false
    if [ -e "$PRDKIT_DIR/.install-state" ] || [ -L "$PRDKIT_DIR/.install-state" ]; then
        incomplete=true
        echo 'Incomplete install: .prdkit/.install-state records an unfinished write phase; retry the same source with --upgrade.'
    fi
    if [ ! -f "$MANIFEST" ]; then
        echo "No manifest at .prdkit/.manifest — reinstall or upgrade to generate one:"
        echo "  bash .product-kit/scripts/init.sh --upgrade"
        exit 1
    fi
    echo "Product-Kit check — kit version $PK_VERSION, installed $(head -n 1 "$MANIFEST")"
    echo

    OUTDATED=()
    MODIFIED=()
    KITMOD=()
    NEWFILES=()
    CUSTOMIZED=()
    while IFS=$'\t' read -r src rel; do
        installed="$TARGET/$rel"
        if [ ! -e "$installed" ]; then
            NEWFILES+=("$rel")
            continue
        fi
        cur="$(hash_file "$installed")"
        kit="$(hash_file "$src")"
        [ "$cur" = "$kit" ] && continue
        rec="$(recorded_hash "$rel")"
        if [ -n "$rec" ] && [ "$cur" = "$rec" ]; then
            OUTDATED+=("$rel")
        else
            # Memory files are seeded once and expected to be customized by
            # every consumer — report them informationally, not as drift.
            case "$rel" in
                .prdkit/memory/*) CUSTOMIZED+=("$rel") ;;
                .claude/commands/*|.opencode/commands/*|.prdkit/scripts/bash/*|.prdkit/workflows/*)
                    # Kit-owned: --upgrade overwrites these, so do not claim they
                    # are preserved. Reported as a distinct bucket below.
                    KITMOD+=("$rel|$src") ;;
                *)                MODIFIED+=("$rel|$src") ;;
            esac
        fi
    done < <(list_kit_files)

    RETIRED=()
    while IFS=$'\t' read -r rel action; do
        [ -n "$rel" ] && RETIRED+=("$rel|$action")
    done < <(list_retired_commands)
    RETIRED_FILES=()
    while IFS=$'\t' read -r rel action; do
        [ -n "$rel" ] && RETIRED_FILES+=("$rel|$action")
    done < <(list_retired_kit_files)

    RETIRED_CI=()
    while IFS=$'\t' read -r rel name; do
        [ -n "$rel" ] && RETIRED_CI+=("$rel: $name")
    done < <(list_retired_ci_calls)

    if has_harness agents; then
        if managed="$(managed_agents_section "$TARGET/AGENTS.md")"; then
            if [ "$managed" != "$(render_agents_section)" ]; then
                # Unedited since install (it matches the recorded hash): the kit ships a newer one.
                rec="$(install_manifest_value "$MANIFEST" agents-section 2>/dev/null || true)"
                if [ -n "$rec" ] && [ "$(printf '%s\n' "$managed" | install_hash_stream)" = "$rec" ]; then
                    OUTDATED+=("AGENTS.md managed section")
                else
                    KITMOD+=("AGENTS.md managed section|")
                fi
            fi
        else NEWFILES+=("AGENTS.md managed section (missing or malformed)"); fi
    fi

    drift=0
    $incomplete && drift=1
    if [ ${#OUTDATED[@]} -gt 0 ]; then
        drift=1
        echo "OUTDATED — unmodified since install, kit ships a newer version (--upgrade refreshes these):"
        for rel in "${OUTDATED[@]}"; do echo "  $rel"; done
        echo
    fi
    if [ ${#MODIFIED[@]} -gt 0 ]; then
        drift=1
        echo "MODIFIED — edited since install (--upgrade preserves these; review with diff):"
        for entry in "${MODIFIED[@]}"; do
            rel="${entry%%|*}"
            src="${entry#*|}"
            echo "  $rel"
            echo "    diff $TARGET/$rel $src"
        done
        echo
    fi
    if [ ${#KITMOD[@]} -gt 0 ]; then
        drift=1
        echo "KIT-OWNED EDITS — commands/scripts you changed since install. These are kit-owned, so"
        echo "--upgrade will OVERWRITE them with the kit version (your edits are NOT preserved). Back up"
        echo "the change, or express project-specific behavior in .prdkit/memory/constitution.md instead:"
        for entry in "${KITMOD[@]}"; do
            rel="${entry%%|*}"
            src="${entry#*|}"
            echo "  $rel"
            if [ -n "$src" ]; then echo "    diff $TARGET/$rel $src"
            else echo "    the text between the Product-Kit markers in $TARGET/AGENTS.md"; fi
        done
        echo
    fi
    if [ ${#NEWFILES[@]} -gt 0 ]; then
        drift=1
        echo "NEW — shipped by the kit but not installed (--upgrade adds these):"
        for rel in "${NEWFILES[@]}"; do echo "  $rel"; done
        echo
    fi
    if [ ${#RETIRED[@]} -gt 0 ]; then
        drift=1
        echo "RETIRED — kit-named commands the kit no longer ships (--upgrade removes kit-installed ones):"
        for entry in "${RETIRED[@]}"; do
            if [ "${entry#*|}" = remove ]; then echo "  ${entry%%|*}"
            else echo "  ${entry%%|*} (not recorded as kit-installed; kept — remove it by hand if unused)"; fi
        done
        echo
    fi
    if [ ${#RETIRED_FILES[@]} -gt 0 ]; then
        drift=1
        echo "RETIRED — installed kit files the kit no longer ships (--upgrade removes kit-owned and unmodified ones):"
        for entry in "${RETIRED_FILES[@]}"; do
            if [ "${entry#*|}" = remove ]; then echo "  ${entry%%|*}"
            else echo "  ${entry%%|*} (edited since install; kept — fold or delete it by hand)"; fi
        done
        echo
    fi
    manual=0
    if [ ${#RETIRED_CI[@]} -gt 0 ]; then
        manual=1
        echo "RETIRED — CI workflows and project files that reference kit files the kit no longer ships"
        echo "(--upgrade never edits them; replace or remove each reference, see the kit's docs/migrating-to-1.0.md):"
        for entry in "${RETIRED_CI[@]}"; do echo "  $entry"; done
        echo
    fi
    if [ ${#CUSTOMIZED[@]} -gt 0 ]; then
        echo "CUSTOMIZED — memory files, expected to diverge (informational; --upgrade preserves these):"
        for rel in "${CUSTOMIZED[@]}"; do echo "  $rel"; done
        echo
    fi

    if [ "$drift" -eq 0 ] && [ "$manual" -eq 0 ]; then
        echo "Everything up to date — nothing to do."
        exit 0
    fi
    if [ "$drift" -eq 0 ]; then echo "The install is up to date; fix the references listed above by hand."
    else echo "Run 'bash .product-kit/scripts/init.sh --upgrade' to apply the safe changes."; fi
    exit 1
fi

# --- Install / upgrade -------------------------------------------------------
# Refuse before writing anything when a directory the installer writes into is a symlink, is
# not a directory or resolves outside TARGET, or when a directory sits where the kit installs a
# file. Directories that do not exist yet are created below as real directories.
containment_problems() {
    local rel src dirs=".prdkit .prdkit/scripts .prdkit/scripts/bash .prdkit/templates .prdkit/memory .prdkit/workflows .prdkit/agents"
    if has_harness claude; then dirs="$dirs .claude .claude/commands"; fi
    if has_harness opencode; then dirs="$dirs .opencode .opencode/commands"; fi
    for rel in $dirs; do managed_dir_problem "$rel" || true; done
    while IFS=$'\t' read -r src rel; do
        if [ -d "$TARGET/$rel" ] && [ ! -L "$TARGET/$rel" ]; then printf '%s is a directory where the kit installs a file\n' "$rel"; fi
    done < <(list_kit_files; printf 'manifest\t.prdkit/.manifest\nmanifest\t.prdkit/.manifest.tmp\nstate\t.prdkit/.install-state\nlock\t.prdkit/.install-lock\n')
    [ ! -L "$PRDKIT_DIR/.install-state" ] || printf '.prdkit/.install-state is a symlink\n'
}
PROBLEMS="$(containment_problems)"
if [ -n "$PROBLEMS" ]; then
    echo "Error: refusing to install into $TARGET; nothing was written:" >&2
    printf '%s\n' "$PROBLEMS" | sed 's/^/  /' >&2
    echo "The installer writes only into real directories inside the project. Replace each path above with a real directory (or move it aside), then re-run." >&2
    exit 1
fi

# Serialize writes, with a retained phase marker rather than pretending the whole install is
# atomic. A lock left by SIGKILL is never guessed stale: inspect its owner before removing it.
mkdir -p "$PRDKIT_DIR"
INSTALL_LOCK="$PRDKIT_DIR/.install-lock"
if ! (set -C; printf 'pid: %s\nhost: %s\n' "$$" "$(hostname)" > "$INSTALL_LOCK") 2>/dev/null; then
    echo 'Error: installer write lock exists at .prdkit/.install-lock; another installer may be active. Inspect owner and process before removing an abandoned lock; then retry --upgrade.' >&2
    exit 1
fi
INSTALL_DONE=false; INSTALL_PHASE=preflight; INSTALL_PATH=.prdkit/.manifest
finish_install() {
    local status=$?
    if [ "$status" -ne 0 ] && ! $INSTALL_DONE; then
        printf 'Incomplete install: phase=%s path=%s (exit %s). Earlier files may already be updated; no global rollback was performed.\n' "$INSTALL_PHASE" "$INSTALL_PATH" "$status" >&2
        echo 'Retain the source revision and .prdkit/.install-state, run --check, then retry the same source with --upgrade. A completed manifest publication may already be current.' >&2
    fi
    rm -f "$INSTALL_LOCK"
    return "$status"
}
trap finish_install EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
current_manifest=absent
[ ! -f "$MANIFEST" ] || current_manifest="$(install_hash_stream < "$MANIFEST")"
if [ "$INITIAL_MANIFEST" != "$current_manifest" ]; then
    echo 'Error: manifest changed while preparing the install; retry to resolve current ownership/harness settings.' >&2
    exit 1
fi
record_progress() {
    INSTALL_PHASE="$1"; INSTALL_PATH="$2"
    printf 'phase: %s\npath: %s\nsource-version: %s\n' "$1" "$2" "$PK_VERSION" > "$PRDKIT_DIR/.install-state"
}
record_progress prepare .prdkit

# Stage next to the destination, so a failed copy cannot truncate a conffile and make the
# retry mistake those partial bytes for a user customization. No package-manager dependency.
atomic_copy() (
    src="$1"; dest="$2"
    stage="$(mktemp -d "$dest.prdkit-install.XXXXXX")" || exit 1
    tmp="$stage/payload"
    trap 'rm -rf "$stage"' EXIT
    if [ "${3:-false}" = true ] && [ -f "$dest" ] && [ ! -L "$dest" ]; then
        # cp into an existing conffile used to retain its permissions. Seed staging
        # with that metadata, then replace the bytes without adopting source mode.
        cp -p "$dest" "$tmp" || exit 1
        cp "$src" "$tmp" || exit 1
    else
        # A new file must honor the invoking umask, just like the original cp.
        # The private directory makes creating this previously absent path safe.
        cp "$src" "$tmp" || exit 1
    fi
    [ ! -L "$dest" ] || rm -f "$dest" || exit 1
    mv -f "$tmp" "$dest" || exit 1
)

echo "Product-Kit: $PK_ROOT (version $PK_VERSION)"
echo "Target:     $TARGET"
echo "Harnesses:  $HARNESSES"
echo

# specs/ is project-owned: the installer never creates or edits anything there.
mkdir -p "$TPL_DIR" "$MEM_DIR" "$SCRIPT_OUT" "$PRDKIT_DIR/workflows" "$PRDKIT_DIR/agents"
if has_harness claude; then mkdir -p "$CMD_DIR"; fi
if has_harness opencode; then mkdir -p "$OC_CMD_DIR"; fi

# Conffile-style install for project-owned files (templates, memory).
# Installs/updates $dest and prints one outcome word:
#   added      → was missing, installed
#   refreshed  → overwritten (--force, or unmodified-since-install + kit newer)
#   current    → already identical to the kit version
#   kept       → consumer edited it: preserved untouched
#   symlinked  → a symlink, project-owned: never written through, even with --force
install_conffile() {
    local src="$1" rel="$2" dest="$TARGET/$2" cur kit rec
    if [ -L "$dest" ]; then
        echo symlinked
        return 0
    fi
    if [ ! -e "$dest" ]; then
        atomic_copy "$src" "$dest" true || return 1
        echo added
        return 0
    fi
    if $FORCE; then
        atomic_copy "$src" "$dest" true || return 1
        echo refreshed
        return 0
    fi
    cur="$(hash_file "$dest")"
    kit="$(hash_file "$src")"
    if [ "$cur" = "$kit" ]; then
        echo current
        return 0
    fi
    rec="$(recorded_hash "$rel")"
    if [ -n "$rec" ] && [ "$cur" = "$rec" ]; then
        atomic_copy "$src" "$dest" true || return 1
        echo refreshed
    else
        echo kept
    fi
    return 0
}

linked=0
oc_linked=0
tpl_added=0; tpl_refreshed=0; tpl_current=0; tpl_kept=0
mem_added=0; mem_refreshed=0; mem_current=0; mem_kept=0
CF_MODIFIED=()
CF_SYMLINKED=()
KIT_OVERWRITTEN=()
while IFS=$'\t' read -r src rel; do
    dest="$TARGET/$rel"
    record_progress file "$rel"
    case "$rel" in
        .claude/commands/*|.opencode/commands/*)
            # Commands are kit-owned: always re-copied (or re-linked under --symlink).
            if file_locally_edited "$rel" "$src"; then KIT_OVERWRITTEN+=("$rel"); fi
            if $MODE_COPY; then
                atomic_copy "$src" "$dest"
            else
                # Relative symlink (both command dirs sit two levels under the
                # project root), so a committed link resolves in any checkout that
                # has the kit checked out. Fall back to copy if symlinking fails.
                case "$src" in
                    "$TARGET"/*) link_target="../../${src#"$TARGET"/}" ;;
                    *)           link_target="$src" ;;
                esac
                rm -f "$dest"
                ln -s "$link_target" "$dest" 2>/dev/null || atomic_copy "$src" "$dest"
            fi
            case "$rel" in
                .claude/*) linked=$((linked + 1)) ;;
                *)         oc_linked=$((oc_linked + 1)) ;;
            esac
            ;;
        .prdkit/scripts/bash/*)
            # Workflow scripts are kit-owned: always refreshed, replacing the file (or a
            # symlink in its place) rather than writing through it.
            if file_locally_edited "$rel" "$src"; then KIT_OVERWRITTEN+=("$rel"); fi
            atomic_copy "$src" "$dest"
            chmod +x "$dest"
            ;;
        .prdkit/workflows/*)
            if file_locally_edited "$rel" "$src"; then KIT_OVERWRITTEN+=("$dest"); fi
            atomic_copy "$src" "$dest"
            ;;
        .prdkit/templates/*)
            outcome="$(install_conffile "$src" "$rel")"
            case "$outcome" in
                added)     tpl_added=$((tpl_added + 1)) ;;
                refreshed) tpl_refreshed=$((tpl_refreshed + 1)) ;;
                current)   tpl_current=$((tpl_current + 1)) ;;
                kept)      tpl_kept=$((tpl_kept + 1)); CF_MODIFIED+=("$dest|$src") ;;
                symlinked) tpl_kept=$((tpl_kept + 1)); CF_SYMLINKED+=("$rel") ;;
            esac
            ;;
        .prdkit/memory/*)
            outcome="$(install_conffile "$src" "$rel")"
            case "$outcome" in
                added)     mem_added=$((mem_added + 1)) ;;
                refreshed) mem_refreshed=$((mem_refreshed + 1)) ;;
                current)   mem_current=$((mem_current + 1)) ;;
                kept)      mem_kept=$((mem_kept + 1)); CF_MODIFIED+=("$dest|$src") ;;
                symlinked) mem_kept=$((mem_kept + 1)); CF_SYMLINKED+=("$rel") ;;
            esac
            ;;
    esac
done < <(list_kit_files)

# Remove kit-installed commands the kit no longer ships, so retired entry points stop
# loading into every session. Unrecorded regular files are reported, never deleted.
RETIRED_REMOVED=()
RETIRED_KEPT=()
while IFS=$'\t' read -r rel action; do
    [ -n "$rel" ] || continue
    if [ "$action" = remove ]; then
        record_progress retire "$rel"
        rm -f "$TARGET/$rel"
        RETIRED_REMOVED+=("$rel")
    else
        RETIRED_KEPT+=("$rel")
    fi
done < <(list_retired_commands)
RETIRED_FILES_REMOVED=()
RETIRED_FILES_KEPT=()
while IFS=$'\t' read -r rel action; do
    [ -n "$rel" ] || continue
    if [ "$action" = remove ]; then
        record_progress retire "$rel"
        rm -f "$TARGET/$rel"
        RETIRED_FILES_REMOVED+=("$rel")
    else
        RETIRED_FILES_KEPT+=("$rel")
    fi
done < <(list_retired_kit_files)

# --- AGENTS.md managed section -----------------------------------------------
# For harnesses without a per-project slash-command mechanism (Codex CLI, any
# generic AGENTS.md reader) the install is a clearly delimited section in the
# consumer's AGENTS.md. Re-running only ever rewrites the text between the
# markers; everything outside them belongs to the consumer and is never touched.

# Writes/updates the managed section and prints one outcome word:
# created | updated | current | appended. A symlinked AGENTS.md is edited at its target, which
# keeps the link, while that target stays inside the project; otherwise it is skipped.
write_agents_section() {
    local agents_file sec tmp
    if ! agents_file="$(root_file_path AGENTS.md)"; then
        echo "Warning: AGENTS.md is a symlink that leads outside $TARGET; leaving it untouched." >&2
        echo "skipped (symlink outside the project)"
        return 0
    fi
    sec="$(mktemp)" || return 1
    render_agents_section > "$sec" || { rm -f "$sec"; return 1; }

    if [ ! -e "$agents_file" ]; then
        atomic_copy "$sec" "$agents_file" true || { rm -f "$sec"; return 1; }
        rm -f "$sec"
        echo created
        return 0
    fi
    if grep -qF "$AGENTS_BEGIN" "$agents_file"; then
        # Refuse to rewrite when the end marker is missing: the awk pass below
        # skips from BEGIN to END, so a lone BEGIN would silently swallow every
        # line of consumer content after it.
        if ! grep -qF "$AGENTS_END" "$agents_file"; then
            rm -f "$sec"
            echo "Warning: AGENTS.md has the Product-Kit begin marker but no end marker ($AGENTS_END); leaving it untouched. Restore the end marker (or remove the begin marker) and re-run." >&2
            echo "skipped (end marker missing)"
            return 0
        fi
        if ! managed_agents_section "$agents_file" >/dev/null; then
            rm -f "$sec"
            echo 'Warning: AGENTS.md managed markers are duplicated or out of order; leaving consumer content untouched.' >&2
            echo 'skipped (malformed managed markers)'
            return 0
        fi
        tmp="$(mktemp)" || { rm -f "$sec"; return 1; }
        awk -v b="$AGENTS_BEGIN" -v e="$AGENTS_END" -v f="$sec" '
            $0 == b { while ((getline l < f) > 0) print l; skip = 1; next }
            $0 == e { skip = 0; next }
            !skip   { print }
        ' "$agents_file" > "$tmp" || { rm -f "$tmp" "$sec"; return 1; }
        if [ "$(hash_file "$tmp")" = "$(hash_file "$agents_file")" ]; then
            rm -f "$tmp" "$sec"
            echo current
        else
            atomic_copy "$tmp" "$agents_file" true || { rm -f "$tmp" "$sec"; return 1; }
            rm -f "$tmp" "$sec"
            echo updated
        fi
        return 0
    fi
    # Existing AGENTS.md without our markers: append the section, preserving
    # everything already there (and its final newline, if missing).
    trailing_byte="$(tail -c 1 "$agents_file")"
    tmp="$(mktemp)" || { rm -f "$sec"; return 1; }
    cp -p "$agents_file" "$tmp" || { rm -f "$tmp" "$sec"; return 1; }
    {
        [ -n "$trailing_byte" ] && echo
        echo
        cat "$sec"
    } >> "$tmp" || { rm -f "$tmp" "$sec"; return 1; }
    atomic_copy "$tmp" "$agents_file" true || { rm -f "$tmp" "$sec"; return 1; }
    rm -f "$tmp" "$sec"
    echo appended
    return 0
}

if has_harness claude; then
    echo "✓ Installed $linked /prdkit-* command(s) into .claude/commands/ ($([ "$MODE_COPY" = true ] && echo copied || echo symlinked))"
fi
if has_harness opencode; then
    echo "✓ Installed $oc_linked /prdkit-* command(s) into .opencode/commands/ ($([ "$MODE_COPY" = true ] && echo copied || echo symlinked))"
fi
if ! $MODE_COPY && { has_harness claude || has_harness opencode; }; then
    case "$PK_ROOT" in
        "$TARGET"/*) kit_rel="${PK_ROOT#"$TARGET"/}"
            echo "  Symlinked commands resolve only where $kit_rel is checked out: a new change worktree or"
            echo "  CI checkout needs 'git submodule update --init $kit_rel'. Re-run with --copy to install copies." ;;
        *)  echo "  Symlinked commands resolve only where $PK_ROOT exists. Re-run with --copy to install copies." ;;
    esac
fi
if has_harness agents; then
    record_progress managed-section AGENTS.md
    agents_outcome="$(write_agents_section)"
    echo "✓ AGENTS.md managed section: $agents_outcome"
fi
echo "✓ Installed workflow scripts into .prdkit/scripts/bash/"
echo "✓ Installed neutral agent playbooks into .prdkit/workflows/"
echo "✓ Templates: $tpl_added added, $tpl_refreshed refreshed, $tpl_current current, $tpl_kept preserved (modified)"
echo "✓ Memory: $mem_added seeded, $mem_refreshed refreshed, $mem_current current, $mem_kept preserved (customized)"
if [ ${#CF_MODIFIED[@]} -gt 0 ]; then
    echo "  Modified since install — preserved; review with:"
    for entry in "${CF_MODIFIED[@]}"; do
        echo "    diff ${entry%%|*} ${entry#*|}"
    done
fi
if [ ${#CF_SYMLINKED[@]} -gt 0 ]; then
    echo "⚠ Kept ${#CF_SYMLINKED[@]} symlinked template/memory file(s); the installer never writes through a"
    echo "  symlink, even with --force. Compare each with the kit's version by hand:"
    for rel in "${CF_SYMLINKED[@]}"; do echo "    $rel"; done
fi
if [ ${#RETIRED_REMOVED[@]} -gt 0 ]; then
    echo "✓ Removed ${#RETIRED_REMOVED[@]} retired kit command(s) no longer shipped:"
    for rel in "${RETIRED_REMOVED[@]}"; do echo "    $rel"; done
fi
if [ ${#RETIRED_KEPT[@]} -gt 0 ]; then
    echo "⚠ Kept ${#RETIRED_KEPT[@]} kit-named command(s) the kit does not ship and did not record installing;"
    echo "  they still load in every session — remove them if they are not deliberately project-owned:"
    for rel in "${RETIRED_KEPT[@]}"; do echo "    $rel"; done
fi
if [ ${#RETIRED_FILES_REMOVED[@]} -gt 0 ]; then
    echo "✓ Removed ${#RETIRED_FILES_REMOVED[@]} retired kit file(s) no longer shipped:"
    for rel in "${RETIRED_FILES_REMOVED[@]}"; do echo "    $rel"; done
fi
if [ ${#RETIRED_FILES_KEPT[@]} -gt 0 ]; then
    echo "⚠ Kept ${#RETIRED_FILES_KEPT[@]} edited template(s) the kit no longer ships; fold or delete them by hand:"
    for rel in "${RETIRED_FILES_KEPT[@]}"; do echo "    $rel"; done
fi
if [ ${#KIT_OVERWRITTEN[@]} -gt 0 ]; then
    echo "⚠ Overwrote ${#KIT_OVERWRITTEN[@]} kit-owned file(s) you had edited — commands/scripts are"
    echo "  kit-owned and always refreshed, so your local changes to these were replaced:"
    for rel in "${KIT_OVERWRITTEN[@]}"; do echo "    $rel"; done
    echo "  If a change is still needed, re-apply it upstream or express it in .prdkit/memory/constitution.md."
fi

# --- Seed .gitignore entries for kit-managed local state ---------------------
# .prdkit/ledger/ is the local event spool (unbounded working record, never
# committed); .prdkit/cache/ holds raw evidence (review packages, test output),
# which records link instead of committing; .prdkit/retrospective/ holds optional
# usage-enrichment inputs (agent names, token counts, costs, notes); .worktrees/ is where
# new-change.sh puts isolated change checkouts. Seeding them here means no later command has to mutate a tracked
# .gitignore mid-run (which would dirty the tree it is about to check). A symlinked .gitignore is
# edited at its target only while that stays inside the project.
IGNORE_ENTRIES=".prdkit/ledger/ .prdkit/cache/ .prdkit/retrospective/ .worktrees/ .prdkit/.install-lock .prdkit/.install-state"
record_progress ignore .gitignore
if GITIGNORE="$(root_file_path .gitignore)"; then
    for ignore_entry in $IGNORE_ENTRIES; do
        if ! grep -qxF "$ignore_entry" "$GITIGNORE" 2>/dev/null; then
            if [ -f "$GITIGNORE" ] && [ -s "$GITIGNORE" ] && [ -n "$(tail -c 1 "$GITIGNORE")" ]; then
                echo >> "$GITIGNORE"
            fi
            echo "$ignore_entry" >> "$GITIGNORE"
            echo "✓ Added '$ignore_entry' to .gitignore"
        fi
    done
else
    echo "⚠ .gitignore is a symlink that leads outside the project; left untouched. Ignore these by hand: $IGNORE_ENTRIES"
fi

# --- Write the install manifest ----------------------------------------------
# Records the kit version, harnesses, and one "<sha256>  <path>"
# line per installed file. For a preserved (consumer-edited) file the previously
# recorded pristine hash is carried forward so future runs still detect the edit.
manifest_tmp="$MANIFEST.tmp"
record_progress manifest .prdkit/.manifest
rm -f "$manifest_tmp"
{
    echo "version: $PK_VERSION"
    echo "harnesses: $HARNESSES"
    echo "mode: $([ "$MODE_COPY" = true ] && echo copy || echo symlink)"
    if has_harness agents; then
        printf 'agents-section: %s\n' "$(render_agents_section | install_hash_stream)"
    fi
    while IFS=$'\t' read -r src rel; do
        dest="$TARGET/$rel"
        [ -e "$dest" ] || continue
        cur="$(hash_file "$dest")"
        kit="$(hash_file "$src")"
        if [ "$cur" = "$kit" ]; then
            echo "$kit  $rel"
        else
            rec="$(recorded_hash "$rel")"
            echo "${rec:-$kit}  $rel"
        fi
    done < <(list_kit_files)
} > "$manifest_tmp"
# A symlinked manifest is replaced, never written through or moved into.
[ ! -L "$MANIFEST" ] || rm -f "$MANIFEST"
mv "$manifest_tmp" "$MANIFEST"
rm -f "$PRDKIT_DIR/.install-state"
INSTALL_DONE=true
echo "✓ Manifest written to .prdkit/.manifest"

# A 0.x spec layout keeps working as plain files, but 1.0 workflows need one current canon.
# The installer never edits specs/; the cutover is agent work with the owner (compact.md).
LAYOUT="$(spec_layout "$TARGET")"
case "$LAYOUT" in
    0.x|both)
        echo
        echo "⚠ This project needs a cutover before 1.0 workflows apply: its specs/ still holds"
        echo "  0.x canon (specs/product-spec/, specs/targets/ or specs/features/). specs/ was not"
        echo "  modified. Between changes, with the owner, run /prdkit-init (Cutover in"
        echo "  .prdkit/workflows/compact.md); doctor reports the layout until then."
        ;;
esac
RETIRED_CI_CALLS="$(list_retired_ci_calls)"
if [ -n "$RETIRED_CI_CALLS" ]; then
    echo
    echo "⚠ CI workflows or project files reference kit files this kit no longer ships; those calls"
    echo "  now fail. Replace or remove them (the kit's docs/migrating-to-1.0.md lists the replacements):"
    printf '%s\n' "$RETIRED_CI_CALLS" | while IFS=$'\t' read -r rel name; do echo "    $rel: $name"; done
fi
if [ -f "$MEM_DIR/signoff-requirements.md" ] && grep -qE '^[-*][[:space:]]*gated-paths:' "$MEM_DIR/signoff-requirements.md" 2>/dev/null; then
    echo
    echo "⚠ .prdkit/memory/signoff-requirements.md configures the 0.x CI sign-off gate. 1.0 replaces"
    echo "  check-signoff.sh with check-review.sh, which checks a change's recorded review verdicts;"
    echo "  a CI job that runs check-signoff.sh now fails. Replace it (the kit's docs/ci-gates.md)."
fi

if $UPGRADE; then
    echo
    echo "Upgrade complete (commands re-linked, scripts refreshed, unmodified templates/memory updated, modified templates/memory preserved)."
    echo "Run 'bash .product-kit/scripts/init.sh --check' anytime to see install drift."
    echo "Run /prdkit-status for the current state."
    exit 0
fi

# --- Next steps ---
cat <<EOF

Product-Kit initialized.

Next steps:
  1. Run /prdkit-init for guided adoption using your existing project context
  2. Describe a product outcome with /prdkit
  3. Use /prdkit-status for visibility and /prdkit-doctor for diagnostics

Upgrade later with:
  git submodule update --remote .product-kit && bash .product-kit/scripts/init.sh --upgrade
EOF
