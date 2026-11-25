#!/usr/bin/env bash
# Read-only evidence from the installed consumer's working tree.
set -euo pipefail
export LC_ALL=C
SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/spec-lib.sh"
source "$SCRIPT_DIR/spec-focused-lib.sh"

usage() {
    cat <<'USAGE'
Usage: role-digest.sh [--extra FILE]... [--config FILE] <role>
  Read .prdkit/memory/constitution.md (required) and .prdkit/memory/agents.md.
  Then read paths listed in .prdkit/memory/role-digest.conf (or --config FILE),
  followed by --extra paths in flag order. Missing optional files are listed.
  Config has one literal path per line; blank lines and lines starting # are ignored.
  Paths are relative to the consumer root and must not traverse symlinks.
  Quote multiword roles. Matching is literal, ASCII case-insensitive and whole-word.
  Output is local working-tree evidence, not a verdict or approval.
USAGE
}
die() { printf 'role-digest.sh: %s\n' "$*" >&2; exit 2; }
bad_usage() { usage >&2; exit 2; }

config=.prdkit/memory/role-digest.conf
explicit_config=false
extras=()
role=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --help|-h) usage; exit 0 ;;
        --extra)
            [ -n "${2:-}" ] || bad_usage
            extras+=("$2"); shift ;;
        --config)
            ! "$explicit_config" && [ -n "${2:-}" ] || bad_usage
            config="$2"; explicit_config=true; shift ;;
        --)
            shift
            [ "$#" -eq 1 ] && [ -z "$role" ] || bad_usage
            role="$1"; break ;;
        -*) bad_usage ;;
        *) [ -z "$role" ] && [ -n "$1" ] || bad_usage; role="$1" ;;
    esac
    shift
done
[[ "$role" == *[![:space:]]* && "$role" != *[[:cntrl:]]* ]] || bad_usage

root="$(get_repo_root)" || die 'Cannot locate consumer root.'
require_consumer_root "$root" role-digest.sh
scratch="$(mktemp -d)" || die 'Cannot allocate digest scratch directory.'
trap 'rm -f "$scratch/input" "$scratch/config" "$scratch/section" "$scratch/digest" "$scratch/inputs"; rmdir "$scratch"' EXIT

snapshot_input() { # repository-relative path, snapshot destination; return 1 only if absent
    local path="$1" component="$1" file="$root/$1"
    case "/$path/" in *//*|*/../*|*/./*) die "Not a plain repository-relative path: $path" ;; esac
    [[ "$path" != *[[:cntrl:]]* ]] || die 'Control characters in input paths are unsupported.'
    while :; do
        [ ! -L "$root/$component" ] || die "Symlink in input path: $path"
        [[ "$component" == */* ]] || break
        component="${component%/*}"
        if [ -e "$root/$component" ] && [ ! -d "$root/$component" ]; then
            die "Non-directory parent in input path: $path"
        fi
    done
    [ -e "$file" ] || return 1
    [ -f "$file" ] || die "Not a regular input file: $path"
    if ! cat "$file" > "$2" || ! cmp -s "$file" "$2"; then
        die "Incomplete input snapshot: $path"
    fi
}

record_input() { # path, snapshot (empty if absent)
    local blob=absent
    if [ -n "$2" ]; then
        blob="$(git -C "$root" hash-object --no-filters -- "$2")" || die "Cannot hash input: $1"
    fi
    printf '  %s\t%s\n' "$blob" "$1" >> "$scratch/inputs" || die 'Cannot write input inventory.'
}

digest_input() { # path, required|optional
    local path="$1" snapshot="$scratch/input" lines bytes ranges first last heading blob
    if ! snapshot_input "$path" "$snapshot"; then
        [ "$2" = optional ] || die "Missing required input: $path"
        record_input "$path" ''
        return
    fi
    verify_lf_file "$snapshot" ||
        die "Invalid input text: $path (expected non-empty LF-terminated text; inspect the raw source, --raw for specs)."
    if ! lines="$(wc -l < "$snapshot")" || ! bytes="$(wc -c < "$snapshot")"; then
        die "Cannot measure input: $path"
    fi
    if ! ranges="$(spec_focused "$snapshot" role-ranges "$role" "$lines" "$bytes")"; then
        die "$path: ${ranges:-Could not read focused sections; use --raw for specs or open this file directly.}"
    fi
    record_input "$path" "$snapshot"
    [ -n "$ranges" ] || return 0
    while IFS=$'\t' read -r first last heading; do
        sed -n "${first},${last}p" "$snapshot" > "$scratch/section" || die "Cannot extract section: $path:$first-$last"
        blob="$(git -C "$root" hash-object --no-filters -- "$scratch/section")" ||
            die "Cannot hash section: $path:$first-$last"
        {
            printf 'Section: %s:%s-%s | %s | content_blob=%s\n' "$path" "$first" "$last" "$heading" "$blob"
            cat "$scratch/section"
            printf '\n'
        } >> "$scratch/digest"
        found=true
    done <<< "$ranges"
}

# Stage the complete digest so a refusal in a later input cannot publish partial evidence.
found=false
printf 'Role digest: %s\n\n' "$role" > "$scratch/digest"
digest_input .prdkit/memory/constitution.md required
digest_input .prdkit/memory/agents.md optional
if snapshot_input "$config" "$scratch/config"; then
    verify_lf_file "$scratch/config" allow-empty ||
        die "Invalid config text: $config (expected LF-terminated paths)."
    record_input "$config" "$scratch/config"
    while IFS= read -r path; do
        case "$path" in ''|\#*) continue ;; esac
        digest_input "$path" optional
    done < "$scratch/config"
else
    record_input "$config" ''
fi
for path in ${extras[@]+"${extras[@]}"}; do digest_input "$path" optional; done
if ! "$found"; then printf 'Empty digest: no sections cite this role.\n\n' >> "$scratch/digest"; fi
printf 'Inputs (working-tree Git blobs):\n' >> "$scratch/digest"
cat "$scratch/digest" "$scratch/inputs"
