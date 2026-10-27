#!/usr/bin/env bash
# Force overlap after numbering but before branch creation in two linked worktrees.
# A private-copy mutation proves that a per-worktree lock admits duplicate numbers.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

REAL_GIT="$(command -v git)"; REAL_SLEEP="$(command -v sleep)"
export REAL_GIT REAL_SLEEP

wait_marker() {
    local n=0
    while [ ! -f "$1" ] && [ ! -f "${2:-$1}" ]; do
        n=$((n + 1)); [ "$n" -le 200 ] || return 1
        "$REAL_SLEEP" 0.1
    done
}

for mode in common private; do
    it "$mode lock: automatic numbering under linked-worktree contention"
    repo="$(make_inited_project)"; track_tmp "$repo"
    repo="$(cd "$repo" && pwd -P)"
    git -C "$repo" add -A && git -C "$repo" commit -qm installed
    sync="$(mktemp -d)"; track_tmp "$sync"
    export NUMBER_TEST_SYNC="$sync"
    for worker in a b; do
        git -C "$repo" worktree add -q -b "worker-$worker" "$sync/$worker"
        if [ "$mode" = private ]; then
            script="$sync/$worker/.prdkit/scripts/bash/new-change.sh"
            # Only mutate the lock's base selection; leave worktree detection intact.
            sed '/^acquire_number_lock()/,/^}/s/--git-common-dir/--git-dir/' "$script" > "$script.tmp"
            mv "$script.tmp" "$script"
        fi
    done
    mkdir "$sync/bin"
    cat > "$sync/bin/git" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = checkout ] && [ "${2:-}" = -q ] && [ "${3:-}" = -b ]; then
    : > "$NUMBER_TEST_SYNC/$NUMBER_TEST_WORKER.ready"
    n=0
    while [ ! -f "$NUMBER_TEST_SYNC/$NUMBER_TEST_WORKER.release" ]; do
        n=$((n + 1)); [ "$n" -le 200 ] || exit 88
        "$REAL_SLEEP" 0.1
    done
fi
exec "$REAL_GIT" "$@"
EOF
    cat > "$sync/bin/sleep" <<'EOF'
#!/usr/bin/env bash
# This is the helper's lock wait, not the test's synchronization loop.
: > "$NUMBER_TEST_SYNC/$NUMBER_TEST_WORKER.blocked"
exec "$REAL_SLEEP" "$@"
EOF
    chmod +x "$sync/bin/git" "$sync/bin/sleep"
    (cd "$sync/a" && env PATH="$sync/bin:$PATH" NUMBER_TEST_WORKER=a PRDKIT_NUMBER_LOCK_WAIT=20 \
        bash .prdkit/scripts/bash/new-change.sh --json --short-name alpha alpha) > "$sync/a.out" 2>&1 &
    pid_a=$!
    if wait_marker "$sync/a.ready"; then _ok 'A chose a number before B starts'; else _no 'A never reached branch creation'; fi
    (cd "$sync/b" && env PATH="$sync/bin:$PATH" NUMBER_TEST_WORKER=b PRDKIT_NUMBER_LOCK_WAIT=20 \
        bash .prdkit/scripts/bash/new-change.sh --json --short-name beta beta) > "$sync/b.out" 2>&1 &
    pid_b=$!
    if wait_marker "$sync/b.ready" "$sync/b.blocked"; then _ok 'B reached the contention boundary'; else _no 'B never reached contention'; fi
    if [ "$mode" = common ]; then
        assert_file "$sync/b.blocked" 'B waited on the common lock while A had no branch yet'
        assert_eq absent "$([ -f "$sync/b.ready" ] && echo present || echo absent)" 'B cannot choose a number early'
    else
        assert_file "$sync/b.ready" 'negative control entered with a stale number'
    fi
    : > "$sync/a.release"
    status_a=0; wait "$pid_a" || status_a=$?
    : > "$sync/b.release"
    status_b=0; wait "$pid_b" || status_b=$?
    assert_eq 0 "$status_a" "A completed: $(cat "$sync/a.out")"
    assert_eq 0 "$status_b" "B completed: $(cat "$sync/b.out")"
    a="$(sed -n 's/.*"CHANGE_ID":"\([^"]*\)".*/\1/p' "$sync/a.out")"
    b="$(sed -n 's/.*"CHANGE_ID":"\([^"]*\)".*/\1/p' "$sync/b.out")"
    assert_eq 001-alpha "$a" 'first branch identity'
    if [ "$mode" = common ]; then
        assert_eq 002-beta "$b" 'common lock assigns distinct automatic identities'
    else
        assert_eq 001-beta "$b" 'negative control reproduces duplicate numeric identity'
    fi
    for worker in a b; do
        id="$a"; [ "$worker" = a ] || id="$b"
        assert_eq "$id" "$(git -C "$sync/$worker" branch --show-current)" 'branch matches output'
        assert_file "$sync/$worker/specs/changes/$id.md" 'record matches output'
        assert_eq absent "$([ -d "$sync/$worker/.worktrees" ] && echo present || echo absent)" 'no nested worktree'
    done
    assert_eq '' "$(find "$repo/.git" -name 'prdkit-change-number.lock*' -print)" 'all lock files cleaned up'
done
finish
