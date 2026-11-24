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
#                   unmodified templates/memory, add new files, remove unedited
#                   retired files (except memory) and list kept ones. Consumer edits to
#                   templates/memory are preserved and listed; edits to kit-owned
#                   commands/scripts are reported by --check and refused on upgrade.
#   --with NAME     Also install an optional subsystem (agent-tiers: render-agents.sh and the
#                   neutral agent-definition template). The manifest records the choice and
#                   later runs keep it; a project that uses agent tiers (.prdkit/agents/*.md
#                   or a vendored .prdkit/agent-library/) keeps them without the flag
#   --without NAME  Stop installing an optional subsystem; --upgrade removes its files.
#                   Refused while the project still uses it
#   --check         Read-only drift report against the install manifest (no changes)
#   --force         Overwrite project-owned templates/memory from Product-Kit (use with care)
#   --target DIR    Target project root (default: current git root, else cwd)
#   -h, --help      Show this help
#
# The installer records what it ships in .prdkit/.manifest: the kit version,
# selected harnesses, the command install mode, and the pristine sha256 of every
# installed file. The manifest lets --check and --upgrade distinguish outdated
# files from consumer edits.
#
# Invariants:
# --upgrade has no direct install destination under specs/. Preflight
# refuses destinations resolving into specs/changes/ and customized
# overwrite/delete destinations. A supported root-file alias (such as a symlinked
# AGENTS.md) can still direct edits to its target elsewhere under specs/.
# Keep customized conffiles by default; never write through their symlinks.
#
# Threat model:
# Include overlapping installers, pre-existing path aliases and interrupted writes.
# Serialize the write phase and retain a progress marker for same-source recovery;
# an upgrade can be partial and does not roll back as a unit. Do not assume safety
# against a hostile source or a writer changing checkout paths during the upgrade.

set -euo pipefail

# --- Resolve Product-Kit source root (the directory containing this script's parent) ---
# pwd -P everywhere: TARGET can arrive physical (git rev-parse) while these are
# logical; on macOS /var vs /private/var then breaks the relative-symlink prefix match.
SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PK_ROOT="$(CDPATH="" cd "$SCRIPT_DIR/.." && pwd -P)"
source "$SCRIPT_DIR/install-lib.sh"
source "$SCRIPT_DIR/spec-lib.sh"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/install-upgrade-lib.sh"

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
WITH_RAW=""
WITHOUT_RAW=""
REMOVE_OPTIONS_FILES=""
IGNORE_ENTRIES=".prdkit/cache/ .worktrees/ .prdkit/.install-lock .prdkit/.install-state"

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
        --with|--without)
            opt_flag="$1"
            shift
            [ $# -gt 0 ] || { echo "Error: $opt_flag requires a value (agent-tiers)" >&2; exit 2; }
            if [ "$opt_flag" = --with ]; then WITH_RAW="$WITH_RAW $1"; else WITHOUT_RAW="$WITHOUT_RAW $1"; fi
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
if [ "$INITIAL_MANIFEST" != absent ] && ! install_manifest_format "$MANIFEST"; then
    echo 'Invalid .prdkit/.manifest: expected LF text with unique version, harnesses, mode (copy or symlink), options (none or agent-tiers), and SHA-256 entries for installed kit paths; nothing was written.' >&2
    exit 1
fi
install_state_fingerprint() {
    local state="$PRDKIT_DIR/.install-state"
    if [ -f "$state" ] && [ ! -L "$state" ]; then install_hash_stream < "$state"
    else echo absent; fi
}
INITIAL_INSTALL_STATE="$(install_state_fingerprint)"

# --- Resolve install harnesses -----------------------------------------------
# Product-Kit's core is markdown + bash, so commands can be installed for more
# than one agent CLI. Verified per-harness targets:
#   claude   → .claude/commands/           (slash commands)
#   opencode → .opencode/commands/         (slash commands)
#   codex    → AGENTS.md managed section   (Codex custom prompts are global-only,
#              never per-project, so its install is the AGENTS.md fallback)
#   agents   → AGENTS.md managed section   (any AGENTS.md-reading harness)
KNOWN_HARNESSES="claude opencode codex agents"

spec_require_layout "$TARGET" || exit 1

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

# --- Resolve optional subsystems ----------------------------------------------
# The core install is the same for every project; an optional subsystem installs only when the
# consumer asks for it (--with), an earlier install recorded it (`options:` in the manifest), or
# the project already uses it. agent-tiers-lib.sh stays core, because doctor and the
# adoption gate check the tier map in agents.md.
KNOWN_OPTIONS="agent-tiers"
OPTIONS=""
has_option() {
    case " $OPTIONS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}
option_used() { # name -> 0 when the project's files already depend on the subsystem
    local def
    case "$1" in
        agent-tiers)
            [ -d "$TARGET/.prdkit/agent-library" ] && return 0
            for def in "$TARGET"/.prdkit/agents/*.md; do [ -f "$def" ] && return 0; done
            return 1 ;;
    esac
    return 1
}
# Kit files that belong to an optional subsystem, by kit-relative path: 0 when the file is core
# or its subsystem is selected for this install.
RECORDED_OPTIONS=""
if [ -f "$MANIFEST" ] && grep -q '^options: ' "$MANIFEST"; then
    RECORDED_OPTIONS="$(grep '^options: ' "$MANIFEST" | head -n 1)"
    RECORDED_OPTIONS="${RECORDED_OPTIONS#options: }"
    [ "$RECORDED_OPTIONS" != none ] || RECORDED_OPTIONS=""
fi
for opt in $WITH_RAW $WITHOUT_RAW; do
    case " $KNOWN_OPTIONS " in *" $opt "*) ;; *)
        echo "Error: unknown optional subsystem '$opt' (known: $KNOWN_OPTIONS)." >&2; exit 2 ;;
    esac
done
for opt in $KNOWN_OPTIONS; do
    with=false; without=false
    case " $WITH_RAW " in *" $opt "*) with=true ;; esac
    case " $WITHOUT_RAW " in *" $opt "*) without=true ;; esac
    if $with && $without; then
        echo "Error: --with $opt and --without $opt contradict each other." >&2; exit 2
    fi
    if $without; then
        if option_used "$opt"; then
            echo "Error: --without $opt would remove files this project uses (.prdkit/agents/*.md or .prdkit/agent-library/)." >&2
            echo "       Remove those first, or keep the subsystem." >&2
            exit 2
        fi
        if $UPGRADE; then
            previous_options="$RECORDED_OPTIONS"
            # If interrupted after manifest publication, the committed manifest
            # still describes the option whose removal the retry must verify.
            if [ -f "$PRDKIT_DIR/.install-state" ] && spec_objects_local "$TARGET"; then
                previous_options="$(GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1 \
                    git -C "$TARGET" cat-file blob HEAD:.prdkit/.manifest |
                    awk '/^options: / { print substr($0, 10) }')" || exit 1
            fi
            case " $previous_options " in *" $opt "*)
                REMOVE_OPTIONS_FILES=".prdkit/scripts/bash/render-agents.sh .prdkit/templates/agent-definition-template.md" ;;
            esac
        fi
        continue
    fi
    case " $RECORDED_OPTIONS " in *" $opt "*) with=true ;; esac
    if $with || option_used "$opt"; then OPTIONS="${OPTIONS:+$OPTIONS }$opt"; fi
done

# The previous install's command mode wins unless --copy/--symlink is passed
# explicitly, so an upgrade never silently flips an install between copies and symlinks.
if ! $MODE_EXPLICIT && [ -f "$MANIFEST" ]; then
    if grep -q '^mode: symlink$' "$MANIFEST"; then
        MODE_COPY=false
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
    local src
    for src in "$PK_ROOT"/commands/prdkit*.md "$PK_ROOT"/workflows/*.md \
        "$PK_ROOT"/scripts/*.sh "$PK_ROOT"/scripts/{agents-section,outcome-checkpoint}.md "$PK_ROOT"/templates/*.md; do
        [ -e "$src" ] || continue
        install_file_targets "${src#"$PK_ROOT"/}" "$HARNESSES" "$OPTIONS" "$src"$'\t' || return 1
    done
}
# A process-substitution reader sees only EOF if its producer fails mid-list.
# Finish the mapping once, before any target writes, and use that same list for every pass.
KIT_FILES="$(list_kit_files)" && [ -n "$KIT_FILES" ] || {
    echo 'Cannot enumerate kit files; nothing was written.' >&2
    exit 1
}
RETIRED_ENTRIES=""
PREVIOUS_MANIFEST=""
PREVIOUS_SYMLINK=false
RESUMING_UPGRADE=false
if [ "$INITIAL_MANIFEST" != absent ]; then
    if $UPGRADE && ! $CHECK; then
        spec_objects_local "$TARGET" || { echo 'Cannot check the installation without fetching missing objects; nothing was written.' >&2; exit 1; }
        export GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1
    fi
    if $UPGRADE && ! $CHECK && [ -f "$PRDKIT_DIR/.install-state" ] && [ ! -L "$PRDKIT_DIR/.install-state" ]; then
        # Publication may already have dropped the entries; recover against the committed manifest.
        PREVIOUS_MANIFEST="$(upgrade_committed_manifest)" || {
            echo 'Cannot read a valid committed install manifest for recovery; nothing was written.' >&2
            exit 1
        }
        RESUMING_UPGRADE=true
    else
        PREVIOUS_MANIFEST="$(cat "$MANIFEST")" || exit 1
    fi
    if grep -qxF 'mode: symlink' <<< "$PREVIOUS_MANIFEST"; then PREVIOUS_SYMLINK=true; fi
    RETIRED_ENTRIES="$(LC_ALL=C awk -F '\t' -v optional="$REMOVE_OPTIONS_FILES" '
        BEGIN { n=split(optional, paths, " "); for (i=1; i<=n; i++) current[paths[i]]=1 }
        !manifest && !NF { manifest=1; next }
        !manifest { current[$2]=1; next }
        /^(version|harnesses|mode|options|agents-section): / || $0 ~ /^[[:space:]]*$/ { next }
        { path=substr($0, 67); if (!(path in current)) { if (seen[path]++) bad=1; print } }
        END { exit bad }
    ' <<< "$KIT_FILES"$'\n\n'"$PREVIOUS_MANIFEST")" || {
        echo 'Invalid .prdkit/.manifest: duplicate retired path or unreadable inventory; nothing was written.' >&2
        exit 1
    }
    if [ -n "$RETIRED_ENTRIES" ] && ! $CHECK && ! $UPGRADE; then
        echo 'The install manifest contains retired kit files. Review them with --check, then run with --upgrade from a clean checkout; nothing was written.' >&2
        exit 1
    fi
fi

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
    target="$(readlink "$file" && printf x)" || return 1
    target="${target%$'\nx'}"
    case "$target" in /*) ;; *) target="$(dirname "$file")/$target" ;; esac
    [ "${target##*/}" = "${file##*/}" ] || return 1
    dir="$(cd "$(dirname "$target")" 2>/dev/null && pwd -P)" || return 1
    kitdir="$(cd "$PK_ROOT/commands" 2>/dev/null && pwd -P)" || return 1
    [ "$dir" = "$kitdir" ]
}

# The previous release, when present in the kit's own local checkout, can tell
# us whether a copied source was executable. Shell helpers always got chmod +x.
retired_expected_mode() {
    local rel="$1" src entry
    case "$rel" in
        .prdkit/scripts/bash/*.sh) echo 100755; return 0 ;;
        .prdkit/scripts/bash/*) src="scripts/${rel##*/}" ;;
        .prdkit/templates/*) src="templates/${rel##*/}" ;;
        .prdkit/workflows/*) src="workflows/${rel##*/}" ;;
        .claude/commands/*|.opencode/commands/*) src="commands/${rel##*/}" ;;
        *) echo 100644; return 0 ;;
    esac
    if [ -n "$PREVIOUS_KIT_TREE" ] && entry="$(GIT_NO_LAZY_FETCH=1 GIT_NO_REPLACE_OBJECTS=1 \
        git -C "$PK_ROOT" ls-tree "$PREVIOUS_KIT_TREE" -- ":(top,literal)$src" 2>/dev/null)"; then
        if [[ "$entry" = '100755 blob '* ]]; then echo 100755; return 0; fi
    fi
    echo 100644
}

# Only regular files and installer command links can be unedited; never hash through a symlink.
retired_file_state() { # relative path, recorded hash
    local rel="$1" rec="$2" file="$TARGET/$1" cur mode=100644
    if [ -L "$file" ]; then
        case "$rel" in
            .claude/commands/*|.opencode/commands/*)
                if $PREVIOUS_SYMLINK && is_kit_command_link "$file"; then echo unedited; return 0; fi ;;
        esac
    elif [ ! -e "$file" ]; then echo absent; return 0
    elif [ -f "$file" ] && [[ "$rel" != .prdkit/memory/* ]]; then
        if [ -x "$file" ]; then mode=100755; fi
        if [ "$mode" = "$(retired_expected_mode "$rel")" ]; then
            cur="$(hash_file "$file")" || return 1
            if [ "$cur" = "$rec" ]; then echo unedited; return 0; fi
        fi
    fi
    echo kept
}

retired_overlaps_current() {
    local dest="$TARGET/$1" src rel
    while IFS=$'\t' read -r src rel; do
        if [ "$dest" -ef "$TARGET/$rel" ]; then return 0; fi
    done <<< "$KIT_FILES"
    return 1
}

retired_recorded_hash() {
    local entry
    while IFS= read -r entry; do
        if [ "${entry#*  }" = "$1" ]; then printf '%s\n' "${entry%%  *}"; return 0; fi
    done <<< "$RETIRED_ENTRIES"
    return 1
}

# --- Containment ---------------------------------------------------------------
# Every write and deletion stays inside TARGET. Manifest paths are data from a file a pull
# request can edit, so one becomes a filesystem operand only when it names the exact layout the
# kit installs (a single file name, never a `/` or `..` segment); case patterns are no check,
# since `*` also matches `/`. A directory the installer writes into must be a real directory
# inside TARGET, and a kit-owned file is replaced rather than written through a symlink.

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

# Retired commands can belong to an unselected harness. Check all ancestors
# before looking at a retired file, even when its directory isn't being installed.
retired_parent_problem() {
    local parent="${1%/*}"
    if [[ "$parent" = */* ]] && retired_parent_problem "$parent"; then return 0; fi
    managed_dir_problem "$parent"
}

# Plan from validated manifest rows. A missing tracked file counts as previous
# installer work only when pre-unlink evidence survived in the progress marker.
plan_retirement() {
    local entry rel rec state git_root version index_entry
    if [ -n "$RETIRED_ENTRIES" ]; then
        version="$(LC_ALL=C awk '/^version: / { print substr($0, 10) }' <<< "$PREVIOUS_MANIFEST")" || return 1
        if [ "$(git -C "$PK_ROOT" rev-parse --show-toplevel 2>/dev/null)" = "$PK_ROOT" ] &&
            git check-ref-format "refs/tags/v$version" && spec_objects_local "$PK_ROOT"; then
            PREVIOUS_KIT_TREE="$(GIT_NO_LAZY_FETCH=1 GIT_NO_REPLACE_OBJECTS=1 \
                git -C "$PK_ROOT" rev-parse --verify --quiet "refs/tags/v$version^{tree}")" || PREVIOUS_KIT_TREE=""
        fi
    fi
    if $RESUMING_UPGRADE; then
        RETIRED_PROOFS="$(upgrade_retirement_proofs)" || {
            echo 'P1: invalid retired-file evidence in .prdkit/.install-state; nothing was written.' >&2
            return 1
        }
    fi
    [ -n "$RETIRED_ENTRIES" ] || return 0
    git_root="$(git -C "$TARGET" rev-parse --show-toplevel 2>/dev/null)" || git_root=""
    while IFS= read -r entry; do
        rel="${entry#*  }"; rec="${entry%%  *}"
        if $CHECK && retired_parent_problem "$rel" >/dev/null; then state=kept
        elif retired_overlaps_current "$rel"; then continue
        else state="$(retired_file_state "$rel" "$rec")" || return 1; fi
        case "$state" in
            unedited) RETIRED_REMOVE+=("$rel") ;;
            kept) RETIRED_KEEP+=("$rel") ;;
            absent)
                index_entry=""
                if [ "$git_root" = "$TARGET" ]; then
                    # Avoid expanding a sparse index on old Git in a partial clone.
                    spec_objects_local "$TARGET" || return 1
                    index_entry="$(GIT_NO_LAZY_FETCH=1 GIT_NO_REPLACE_OBJECTS=1 \
                        git -C "$TARGET" ls-files -t -- ":(top,literal)$rel")" || return 1
                fi
                if [[ "$index_entry" = 'S '* ]]; then RETIRED_SPARSE+=("$entry")
                elif retirement_proof_recorded "$entry"; then RETIRED_DELETED+=("$rel")
                else RETIRED_ABSENT+=("$rel")
                fi ;;
        esac
    done <<< "$RETIRED_ENTRIES"
}
PREVIOUS_KIT_TREE=""; RETIRED_PROOFS=""
RETIRED_REMOVE=(); RETIRED_KEEP=(); RETIRED_ABSENT=(); RETIRED_DELETED=(); RETIRED_SPARSE=()

list_sparse_retirements() {
    local entry
    if [ ${#RETIRED_SPARSE[@]} -gt 0 ]; then
        echo 'Retired files kept in the manifest (excluded by sparse checkout; include these paths before upgrading again):'
        for entry in "${RETIRED_SPARSE[@]}"; do printf '  %s\n' "${entry#*  }"; done
    fi
}

retain_sparse_retirement_rows() {
    if [ ${#RETIRED_SPARSE[@]} -gt 0 ]; then printf '%s\n' "${RETIRED_SPARSE[@]}"; fi
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


# --- --check: read-only drift report ----------------------------------------
if $CHECK; then
    incomplete=false
    if [ -e "$PRDKIT_DIR/.install-state" ] || [ -L "$PRDKIT_DIR/.install-state" ]; then
        incomplete=true
        echo 'Incomplete install: .prdkit/.install-state records an unfinished write phase; retry the same source with --upgrade.'
    fi
    if [ ! -f "$MANIFEST" ]; then
        echo "No manifest at .prdkit/.manifest — run init.sh without --upgrade for a new installation."
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
                    # Kit-owned edits are distinct from supported customization.
                    KITMOD+=("$rel|$src") ;;
                *)                MODIFIED+=("$rel|$src") ;;
            esac
        fi
    done <<< "$KIT_FILES"

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
        echo "KIT-OWNED EDITS — managed files or text you changed since install:"
        echo "--upgrade refuses to overwrite these customizations. Reconcile them before upgrading."
        echo "Move project-specific policy to .prdkit/memory/constitution.md where appropriate:"
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
    if [ ${#CUSTOMIZED[@]} -gt 0 ]; then
        echo "CUSTOMIZED — memory files, expected to diverge (informational; --upgrade preserves these):"
        for rel in "${CUSTOMIZED[@]}"; do echo "  $rel"; done
        echo
    fi
    if [ -n "$RETIRED_ENTRIES" ]; then
        drift=1
        plan_retirement || exit 1
        if [ ${#RETIRED_REMOVE[@]} -gt 0 ]; then
            echo "RETIRED — unedited (--upgrade removes these):"
            printf '  %s\n' "${RETIRED_REMOVE[@]}"
        fi
        if [ ${#RETIRED_KEEP[@]} -gt 0 ]; then
            echo "RETIRED — kept (customized, symlinked, memory, or unsafe to inspect):"
            printf '  %s\n' "${RETIRED_KEEP[@]}"
        fi
        if [ ${#RETIRED_ABSENT[@]} -gt 0 ]; then
            echo "RETIRED — already absent (--upgrade drops these manifest entries):"
            printf '  %s\n' "${RETIRED_ABSENT[@]}"
        fi
        list_sparse_retirements
        echo
    fi

    if [ "$drift" -eq 0 ]; then
        echo "Everything up to date — nothing to do."
        exit 0
    fi
    echo "Run 'bash .product-kit/scripts/init.sh --upgrade' to apply the safe changes."
    exit 1
fi

# --- Install / upgrade -------------------------------------------------------
# Refuse before writing anything when a directory the installer writes into is a symlink, is
# not a directory or resolves outside TARGET, or when a directory sits where the kit installs a
# file. Directories that do not exist yet are created below as real directories.
containment_problems() {
    local rel src entry dirs=".prdkit .prdkit/scripts .prdkit/scripts/bash .prdkit/templates .prdkit/memory .prdkit/workflows .prdkit/agents"
    if has_harness claude; then dirs="$dirs .claude .claude/commands"; fi
    if has_harness opencode; then dirs="$dirs .opencode .opencode/commands"; fi
    for rel in $dirs; do managed_dir_problem "$rel" || true; done
    if [ -n "$RETIRED_ENTRIES" ]; then
        while IFS= read -r entry; do
            retired_parent_problem "${entry#*  }" || true
        done <<< "$RETIRED_ENTRIES"
    fi
    while IFS=$'\t' read -r src rel; do
        if [ -d "$TARGET/$rel" ] && [ ! -L "$TARGET/$rel" ]; then printf '%s is a directory where the kit installs a file\n' "$rel"; fi
    done <<< "$KIT_FILES"$'\nmanifest\t.prdkit/.manifest\nmanifest\t.prdkit/.manifest.tmp\nstate\t.prdkit/.install-state\nlock\t.prdkit/.install-lock'
    [ ! -L "$PRDKIT_DIR/.install-state" ] || printf '.prdkit/.install-state is a symlink\n'
    for rel in AGENTS.md .gitignore; do
        [ "$rel" != AGENTS.md ] || has_harness agents || continue
        if src="$(root_file_path "$rel")" && [ -d "$src" ]; then
            printf '%s resolves to a directory where the installer edits a root file\n' "$rel"
        fi
    done
}
PROBLEMS="$(containment_problems | LC_ALL=C sort -u)"
if [ -n "$PROBLEMS" ]; then
    echo "Error: refusing to install into $TARGET; nothing was written:" >&2
    printf '%s\n' "$PROBLEMS" | sed 's/^/  /' >&2
    echo "The installer writes only into real directories inside the project. Replace each path above with a real directory (or move it aside), then re-run." >&2
    exit 1
fi

build_reference_paths() {
    # Exclude exact installed paths, not directories: a consumer can keep a
    # tracked wrapper alongside kit scripts. Use the pre-upgrade manifest.
    local installed_paths rel
    search_paths=(. ':(top,exclude,literal).prdkit/.manifest' ':(top,exclude,literal).product-kit')
    installed_paths="$(LC_ALL=C awk 'length($1) == 64 && $1 ~ /^[0-9a-f]+$/ { print substr($0, 67) }' <<< "$PREVIOUS_MANIFEST")" || return 1
    while IFS= read -r rel; do
        [ -z "$rel" ] || search_paths+=(":(top,exclude,literal)$rel")
    done <<< "$installed_paths"
}

warn_retired_references() {
    local rel references patterns=()
    if [ ${#RETIRED_REMOVE[@]} -gt 0 ]; then
        for rel in "${RETIRED_REMOVE[@]}"; do patterns+=(-e "${rel##*/}"); done
    fi
    if [ ${#RETIRED_DELETED[@]} -gt 0 ]; then
        for rel in "${RETIRED_DELETED[@]}"; do patterns+=(-e "${rel##*/}"); done
    fi
    [ ${#patterns[@]} -gt 0 ] || return 0
    if references="$(git -C "$TARGET" grep --no-color --no-recurse-submodules --no-textconv -n -I -F \
        "${patterns[@]}" -- "${search_paths[@]}")"; then
        printf 'Warning: tracked project files still reference removed retired kit files:\n%s\n' "$references" >&2
    elif [ "$?" -ne 1 ]; then
        echo 'Warning: could not check tracked references to removed retired kit files.' >&2
    fi
}

if $UPGRADE; then
    [ "$INITIAL_MANIFEST" != absent ] || { echo 'No install manifest; run init.sh without --upgrade to install.' >&2; exit 1; }
    plan_retirement || exit 1
    upgrade_destinations_safe || exit 1
    upgrade_checkout_clean || exit 1
    upgrade_no_overwrite || exit 1
    if [ -n "$REMOVE_OPTIONS_FILES" ] || [ ${#RETIRED_REMOVE[@]} -gt 0 ] || [ ${#RETIRED_DELETED[@]} -gt 0 ]; then
        build_reference_paths || exit 1
    fi
    if [ -n "$REMOVE_OPTIONS_FILES" ]; then
        if references="$(git -C "$TARGET" grep --no-color -n -I -E -e 'render-agents\.sh|agent-definition-template\.md' \
            --and --not -e '^[[:space:]]*#' -- "${search_paths[@]}")"; then
            printf 'Error: --without agent-tiers would remove files still referenced by tracked project files. Update these references or keep the subsystem:\n%s\n' "$references" >&2
            exit 1
        elif [ "$?" -ne 1 ]; then
            echo 'Cannot check tracked references before removing agent-tiers; nothing was written.' >&2
            exit 1
        fi
    fi
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
if [ "$INITIAL_INSTALL_STATE" != "$(install_state_fingerprint)" ]; then
    echo 'Error: install state changed while preparing the install; retry with the current recovery marker.' >&2
    exit 1
fi
record_progress() {
    INSTALL_PHASE="$1"; INSTALL_PATH="$2"
    if [ -n "$RETIRED_PROOFS" ]; then
        # Later phases must keep every previous unlink receipt, even across a
        # failed publication. Publish the combined marker before unlinking.
        (
            stage="$(mktemp -d "$PRDKIT_DIR/.install-state.prdkit-install.XXXXXX")" || exit 1
            trap 'rm -rf "$stage"' EXIT
            printf 'phase: %s\npath: %s\nsource-version: %s\n%s\n' "$1" "$2" "$PK_VERSION" "$RETIRED_PROOFS" \
                > "$stage/payload" || exit 1
            mv -f "$stage/payload" "$PRDKIT_DIR/.install-state"
        )
    else
        printf 'phase: %s\npath: %s\nsource-version: %s\n' "$1" "$2" "$PK_VERSION" > "$PRDKIT_DIR/.install-state"
    fi
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

# specs/ is project-owned, not an installation destination.
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
            case "$rel" in *.sh) chmod +x "$dest" ;; esac
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
done <<< "$KIT_FILES"

for rel in $REMOVE_OPTIONS_FILES; do
    dest="$TARGET/$rel"
    if [[ "$rel" = .prdkit/templates/* ]] &&
        { [ -L "$dest" ] || { [ -f "$dest" ] && [ "$(hash_file "$dest")" != "$(recorded_hash "$rel")" ]; }; }; then
        echo "Kept customized optional template: $rel"
    elif [ -e "$dest" ] || [ -L "$dest" ]; then
        record_progress optional "$rel"
        rm -f "$dest"
        echo "Removed optional file: $rel"
    fi
done
if [ ${#RETIRED_REMOVE[@]} -gt 0 ]; then
    removed=()
    for rel in "${RETIRED_REMOVE[@]}"; do
        if retired_overlaps_current "$rel"; then continue; fi
        rec="$(retired_recorded_hash "$rel")"
        state="$(retired_file_state "$rel" "$rec")"
        case "$state" in
            kept) RETIRED_KEEP+=("$rel"); continue ;;
            absent) continue ;;
        esac
        evidence="$(upgrade_retired_head_entry "$rel")"
        # A tracked executable-bit edit must be preserved even when Git was
        # configured to ignore worktree mode differences.
        case "$evidence" in
            'absent '* ) ;;
            '120000 '*) if [ ! -L "$TARGET/$rel" ]; then RETIRED_KEEP+=("$rel"); continue; fi ;;
            "$(retired_expected_mode "$rel") "*) if [ -L "$TARGET/$rel" ]; then RETIRED_KEEP+=("$rel"); continue; fi ;;
            *) RETIRED_KEEP+=("$rel"); continue ;;
        esac
        if ! retirement_proof_recorded "$rec  $rel"; then
            RETIRED_PROOFS="${RETIRED_PROOFS:+$RETIRED_PROOFS$'\n'}retired-file: $evidence $rec  $rel"
        fi
        record_progress retired "$rel"
        rm -f "$TARGET/$rel"
        removed+=("$rel")
        printf 'Removed retired kit file: %s\n' "$rel"
    done
    RETIRED_REMOVE=()
    if [ ${#removed[@]} -gt 0 ]; then RETIRED_REMOVE=("${removed[@]}"); fi
fi

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
        render_agents_replacement "$agents_file" "$sec" "$tmp" || { rm -f "$tmp" "$sec"; return 1; }
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
if [ ${#KIT_OVERWRITTEN[@]} -gt 0 ]; then
    echo "⚠ Overwrote ${#KIT_OVERWRITTEN[@]} kit-owned file(s) you had edited — commands/scripts are"
    echo "  kit-owned and always refreshed, so your local changes to these were replaced:"
    for rel in "${KIT_OVERWRITTEN[@]}"; do echo "    $rel"; done
    echo "  If a change is still needed, re-apply it upstream or express it in .prdkit/memory/constitution.md."
fi

# --- Seed .gitignore entries for kit-managed local state ---------------------
# .prdkit/history/ is consumer-owned and tracked; never ignore .prdkit/ as a whole.
# .prdkit/cache/ holds raw evidence (review packages, test output), which records link instead
# of committing; .worktrees/ is where new-change.sh puts isolated change checkouts.
# Seeding them here means no later command has to mutate a tracked
# .gitignore mid-run (which would dirty the tree it is about to check). A symlinked .gitignore is
# edited at its target only while that stays inside the project.
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
if git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    # Check prospective adds even when existing history is already tracked.
    for history_path in .prdkit/history/log.md .prdkit/history/log/001-example.md .prdkit/history/archive.md; do
        if git -C "$TARGET" check-ignore --no-index -q -- "$history_path"; then
            rule="$(git -C "$TARGET" check-ignore --no-index -v -- "$history_path")" || rule="$history_path"
            printf 'Warning: Git ignores history: %s\n  Narrow this ignore rule to track .prdkit/history/; keep .prdkit/cache/ ignored.\n' "$rule" >&2
        elif [ "$?" -ne 1 ]; then
            printf 'Warning: could not check Git ignore rules for %s; make sure history is tracked and .prdkit/cache/ stays ignored.\n' "$history_path" >&2
        fi
    done
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
    echo "options: ${OPTIONS:-none}"
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
    done <<< "$KIT_FILES"
    retain_sparse_retirement_rows
} > "$manifest_tmp"
# A symlinked manifest is replaced, never written through or moved into.
[ ! -L "$MANIFEST" ] || rm -f "$MANIFEST"
mv "$manifest_tmp" "$MANIFEST"
rm -f "$PRDKIT_DIR/.install-state"
INSTALL_DONE=true
echo "✓ Manifest written to .prdkit/.manifest"

if $UPGRADE; then
    echo
    echo "Upgrade complete (commands re-linked, scripts refreshed, unmodified templates/memory updated, modified templates/memory preserved)."
    if [ ${#RETIRED_KEEP[@]} -gt 0 ]; then
        echo 'Kept retired files (no longer managed; delete them or fold their content into project-owned files):'
        printf '  %s\n' "${RETIRED_KEEP[@]}"
    fi
    list_sparse_retirements
    warn_retired_references
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

To upgrade later, choose a release tag and commit the .product-kit pin in this project first.
Run 'bash .product-kit/scripts/init.sh --check' (drift is expected on a new pin), then
'bash .product-kit/scripts/init.sh --upgrade' from the clean checkout.
EOF
