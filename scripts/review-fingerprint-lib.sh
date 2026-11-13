#!/usr/bin/env bash
# review-fingerprint-lib.sh — the content fingerprint a review verdict is bound to. Source after
# common.sh and spec-lib.sh. Read-only, local Git only, Bash 3.2 and POSIX awk.
#
# A change's content is its delta from where it leaves the base (the unique merge base of the
# base and the revision) to the revision, outside its own record and log. The canonical stream
# is one chunk per changed path, in Git's path order:
#   T <old mode> <new mode>\t<path>    a regular file edited in place whose blobs hold no NUL,
#                                     followed by its hunks: each @@ line is printed as "@@"
#                                     (line numbers and function headings dropped), every other
#                                     line verbatim, so a base edit more than 3 lines away
#                                     leaves it unchanged
#   R <old mode> <new mode> <old id> <new id> <status>\t<path>
#                                     anything else (an add, a delete, a binary file, a link,
#                                     a submodule, a type change), bound to exact objects
# Tag lines start with "T " or "R " or "@@", hunk lines with a space, +, - or \, so the encoding
# is prefix-free. The fingerprint is fp1:<sha256 of the stream>; an empty stream is "no change".
# shellcheck disable=SC2034 # REVIEW_* values are read by the scripts that source this library

REVIEW_FP_EMPTY=fp1:e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
# The L0/L1 spec the owner approves: their fingerprint is the change's content over these only.
REVIEW_L01_PATHSPECS=(':(top,literal)specs/product.md' ':(top,literal)specs/product'
    ':(top,literal)specs/architecture.md' ':(top,literal)specs/architecture'
    ':(top,literal)specs/SPEC.md' ':(top,literal)specs/decisions')
REVIEW_FP_ERROR=""; REVIEW_MB=""; REVIEW_FP=""

review_sha256() { # stdin -> 64 lowercase hex
    local out
    if command -v sha256sum >/dev/null 2>&1; then out="$(sha256sum)" || return 1
    elif command -v shasum >/dev/null 2>&1; then out="$(shasum -a 256)" || return 1
    elif command -v openssl >/dev/null 2>&1; then out="$(openssl dgst -sha256 -r)" || return 1
    else REVIEW_FP_ERROR="no SHA-256 tool (sha256sum, shasum or openssl) is installed"; return 1
    fi
    out="${out%%[!0-9a-f]*}"
    [ "${#out}" -eq 64 ] || { REVIEW_FP_ERROR="the SHA-256 tool printed no digest"; return 1; }
    printf '%s\n' "$out"
}

review_is_fp() { [[ "$1" =~ ^fp1:[0-9a-f]{64}$ ]]; }

# Sets REVIEW_MB (and prints it), or REVIEW_FP_ERROR and returns 1: no merge base, or more than
# one (a criss-cross history), leaves the change's start ambiguous, so it fails closed.
review_merge_base() { # root base rev
    local all
    REVIEW_MB=""
    all="$(GIT_NO_REPLACE_OBJECTS=1 git -C "$1" merge-base --all "$2" "$3" 2>/dev/null)" || all=""
    local base="${2#refs/remotes/}" rev="$3"
    case "$rev" in *[!0-9a-f]*) ;; *) [ "${#rev}" -ne 40 ] || rev="${rev:0:12}" ;; esac
    case "$all" in
        "") REVIEW_FP_ERROR="$rev shares no history with $base, so the change's start cannot be found"; return 1 ;;
        *$'\n'*) REVIEW_FP_ERROR="$rev and $base have more than one merge base (a criss-cross history), so the change's start is ambiguous; merge $base into the branch again to give it one"; return 1 ;;
    esac
    REVIEW_MB="$all"
    printf '%s\n' "$all"
}

_review_nul_free() { # root blob -> success when the blob holds no NUL byte
    local size kept
    size="$(GIT_NO_REPLACE_OBJECTS=1 git -C "$1" cat-file -s "$2" 2>/dev/null)" || return 2
    kept="$(GIT_NO_REPLACE_OBJECTS=1 git -C "$1" cat-file blob "$2" 2>/dev/null | tr -d '\000' | wc -c | tr -d ' ')" || return 2
    [ "$size" = "$kept" ]
}

# The canonical stream on stdout. On failure sets REVIEW_FP_ERROR and returns 1; never prints a
# stream that looks valid after a Git error. Call it without a subshell to keep the error text.
review_delta_stream() { # root id base rev [pathspec...]
    local root="$1" id="$2" base="$3" rev="$4" raw meta file om nm oid nid st hunks status
    shift 4
    [ "$#" -gt 0 ] || set -- . ":(top,literal,exclude)specs/changes/$id.md" \
        ':(top,literal,exclude)specs/log.md' ":(top,literal,exclude)specs/log/$id.md"
    review_merge_base "$root" "$base" "$rev" >/dev/null || return 1
    if ! raw="$(LC_ALL=C GIT_NO_REPLACE_OBJECTS=1 git -C "$root" -c core.quotepath=true diff --raw --no-abbrev \
        --no-renames --no-ext-diff --no-textconv --no-color --no-relative --ignore-submodules=none -O/dev/null \
        "$REVIEW_MB" "$rev" -- "$@" 2>/dev/null)"; then
        REVIEW_FP_ERROR="the change's diff from ${REVIEW_MB:0:12} to $rev cannot be read"; return 1
    fi
    [ -n "$raw" ] || return 0
    hunks="$(mktemp)" || { REVIEW_FP_ERROR="no temporary file for the change's diff"; return 1; }
    status=0
    while IFS="$(printf '\t')" read -r meta file; do
        [ -n "$meta" ] || continue
        meta="${meta#:}"
        read -r om nm oid nid st <<< "$meta"
        if [ "$st" = M ] && case "$om" in 100644|100755) true ;; *) false ;; esac &&
            case "$nm" in 100644|100755) true ;; *) false ;; esac; then
            if _review_nul_free "$root" "$oid"; then status=0; else status=$?; fi
            if [ "$status" -eq 0 ]; then
                if _review_nul_free "$root" "$nid"; then status=0; else status=$?; fi
            fi
            if [ "$status" -eq 0 ]; then
                if ! LC_ALL=C GIT_NO_REPLACE_OBJECTS=1 git -C "$root" -c diff.suppressBlankEmpty=false diff --text \
                    --no-color --no-ext-diff --no-textconv --diff-algorithm=myers --indent-heuristic \
                    --inter-hunk-context=0 -U3 "$oid" "$nid" > "$hunks" 2>/dev/null; then
                    status=2; break
                fi
                printf 'T %s %s\t%s\n' "$om" "$nm" "$file"
                LC_ALL=C awk '/^@@/ { seen = 1; print "@@"; next } seen { print }' "$hunks" || { status=2; break; }
                continue
            fi
            [ "$status" -eq 1 ] || break
            status=0
        fi
        printf 'R %s %s %s %s %s\t%s\n' "$om" "$nm" "$oid" "$nid" "$st" "$file"
    done <<< "$raw"
    rm -f "$hunks"
    if [ "$status" -ne 0 ]; then
        REVIEW_FP_ERROR="a changed file's content cannot be read between ${REVIEW_MB:0:12} and $rev"; return 1
    fi
}

# Sets REVIEW_FP (and prints it), or REVIEW_FP_ERROR and returns 1.
review_fingerprint() { # root id base rev [pathspec...]
    local stream digest
    REVIEW_FP=""
    stream="$(mktemp)" || { REVIEW_FP_ERROR="no temporary file for the change's diff"; return 1; }
    if ! review_delta_stream "$@" > "$stream"; then rm -f "$stream"; return 1; fi
    digest="$(review_sha256 < "$stream")" || { rm -f "$stream"; REVIEW_FP_ERROR="${REVIEW_FP_ERROR:-SHA-256 failed}"; return 1; }
    rm -f "$stream"
    REVIEW_FP="fp1:$digest"
    printf '%s\n' "$REVIEW_FP"
}

# The paths whose chunks differ between two streams (files), one per line, sorted: for messages.
review_stream_paths() { # stream-file-a stream-file-b
    { cat "$1"; printf '=\n'; cat "$2"; } | LC_ALL=C awk '
        $0 == "=" && !split_seen { split_seen = 1; side = 2; key = ""; next }
        /^[TR] / { key = substr($0, index($0, "\t") + 1); keys[key] = 1 }
        { if (key != "") { if (side == 2) b[key] = b[key] $0 "\n"; else a[key] = a[key] $0 "\n" } }
        END { for (k in keys) if (a[k] != b[k]) print k }' | LC_ALL=C sort
}
