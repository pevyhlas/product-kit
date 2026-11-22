#!/usr/bin/env bash
# shellcheck disable=SC2016 # GitHub expressions and fixture shell scripts are literal data.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

it "the shard planner uses largest-first balancing and never drops untimed suites"
fixture="$(mktemp -d)" || exit 1
track_tmp "$fixture"
cp "$TESTS_DIR/run.sh" "$fixture/run.sh" || exit 1
cat > "$fixture/suite-weights.txt" <<'WEIGHTS'
test_a.sh 100   1
test_b.sh  70 100
test_c.sh  45  70
WEIGHTS
printf '%s\n' test_a.sh test_b.sh test_c.sh test_new.sh > "$fixture/native-suites.txt"
for name in a b c new; do
    cat > "$fixture/test_$name.sh" <<'SUITE'
name="${0##*/}"
printf '%s:%s\n' "$name" "${1:-}" >> "$CALLS"
[ "$name" != test_a.sh ]
SUITE
done

run bash "$fixture/run.sh" --shard 1/2 --list
assert_eq 0 "$STATUS" "planning succeeds without executing the suites"
assert_eq $'test_a.sh\ntest_new.sh' "$OUTPUT" "Linux shard 1 gets the untimed suite"
# Stop here against a runner without --list, so real planning below cannot launch real suites.
[ "$OUTPUT" = $'test_a.sh\ntest_new.sh' ] || finish
run bash "$fixture/run.sh" --shard 2/2 --list
assert_eq 0 "$STATUS" "Linux shard 2 planning succeeds"
assert_eq $'test_b.sh\ntest_c.sh' "$OUTPUT" "largest remaining weights go to the lightest bin"
run bash "$fixture/run.sh" --native --shard 1/2 --list
assert_eq 0 "$STATUS" "native shard planning succeeds"
assert_eq $'test_b.sh\ntest_a.sh' "$OUTPUT" "native weights and native fallback change assignment"

run env CALLS="$fixture/calls" bash "$fixture/run.sh" --shard 1/2 -v
assert_eq 1 "$STATUS" "a failing suite fails the shard"
assert_eq $'test_a.sh:-v\ntest_new.sh:-v' "$(cat "$fixture/calls")" "only selected suites run, including those after failure"
elapsed="$(printf '%s\n' "$OUTPUT" | sed -nE 's/^Elapsed: (test_[a-z]+\.sh) [0-9]+s$/\1/p')"
assert_eq $'test_a.sh\ntest_new.sh' "$elapsed" "elapsed seconds appear for failing and passing suites"
run env CALLS="$fixture/calls" bash "$fixture/run.sh"
assert_eq 1 "$STATUS" "the unsharded run still reports failure"
assert_eq $'test_a.sh:-v\ntest_new.sh:-v\ntest_a.sh:\ntest_b.sh:\ntest_c.sh:\ntest_new.sh:' \
    "$(cat "$fixture/calls")" "the default runs every discovered suite in glob order"

it "invalid plans and broken allowlists cannot silently pass"
for invalid in '' 0/2 3/2 1/0 01/2 1//2 1/99999999999999999999; do
    run bash "$fixture/run.sh" --shard "$invalid" --list
    assert_eq 2 "$STATUS" "reject invalid shard: '$invalid'"
done
printf '%s\n' test_b.sh >> "$fixture/native-suites.txt"
run bash "$fixture/run.sh" --native --shard 1/4 --list
assert_eq 1 "$STATUS" "reject duplicate allowlist entries"
printf '%s\n' test_missing.sh > "$fixture/native-suites.txt"
run bash "$fixture/run.sh" --native --shard 1/4 --list
assert_eq 1 "$STATUS" "reject missing allowlist entries"

it "the actual suite lists are each partitioned exactly once at both shard counts"
LC_ALL=C
export LC_ALL
linux_suites="$(for suite in "$TESTS_DIR"/test_*.sh; do printf '%s\n' "${suite##*/}"; done)"
native_suites="$(grep -vE '^(#|$)' "$TESTS_DIR/native-suites.txt" | sort)"
for platform in linux native; do
    flags=()
    expected="$linux_suites"
    if [ "$platform" = native ]; then
        flags=(--native)
        expected="$native_suites"
    fi
    run "$BASH" "$TESTS_DIR/run.sh" ${flags[@]+"${flags[@]}"} --list
    assert_eq 0 "$STATUS" "$platform unsharded listing succeeds"
    assert_eq "$expected" "$(printf '%s\n' "$OUTPUT" | sort)" "$platform unsharded listing matches its source"
    for count in 2 4; do
        all="$fixture/$platform-$count"
        : > "$all"
        for ((leg = 1; leg <= count; leg++)); do
            run "$BASH" "$TESTS_DIR/run.sh" ${flags[@]+"${flags[@]}"} --list --shard "$leg/$count"
            assert_eq 0 "$STATUS" "$platform $leg/$count planning succeeds"
            [ -z "$OUTPUT" ] || printf '%s\n' "$OUTPUT" >> "$all"
        done
        assert_eq "" "$(sort "$all" | uniq -d)" "$platform $count shards are pairwise disjoint"
        assert_eq "$expected" "$(sort "$all")" "$platform $count shards cover every suite"
    done
done

# Read the checked-in workflow shape and execute the actual aggregate run blocks.
job_body() { # workflow job
    awk -v job="$2" '
        $0 == "  " job ":" { wanted = 1; next }
        wanted && /^  [^ ]/ { exit }
        wanted { print }
    ' "$1"
}
aggregate() {
    run env -i PATH="$PATH" "$@" bash --noprofile --norc -eo pipefail -c "$gate_script"
}

it "the workflows require each matrix leg individually, preserve check names, and fail closed"
for platform in linux native; do
    if [ "$platform" = linux ]; then
        workflow="$PK_ROOT/.github/workflows/ci.yml"
        matrix=test-shards; ids='[1, 2]'; count=2; image=ubuntu-24.04; ceiling=45
        gate='test'; check_name='test'; deps='[test-shards, checks]'
        suite_command='bash tests/run.sh --shard "${{ matrix.shard }}/2"'
    else
        workflow="$PK_ROOT/.github/workflows/ci-macos.yml"
        matrix=native-shards; ids='[1, 2, 3, 4]'; count=4; image=macos-15; ceiling=90
        gate=portable-helpers-macos; check_name='portable helpers (macOS)'; deps='[native-shards]'
        suite_command='/bin/bash tests/run.sh --native --shard "${{ matrix.shard }}/4"'
    fi
    matrix_body="$(job_body "$workflow" "$matrix")"
    gate_body="$(job_body "$workflow" "$gate")"
    assert_eq "    name: $check_name" "$(printf '%s\n' "$gate_body" | grep '^    name:')" "$platform required check name"
    assert_eq "    needs: $deps" "$(printf '%s\n' "$gate_body" | grep '^    needs:')" "$platform aggregate needs every lane"
    assert_eq '    if: ${{ always() }}' "$(grep -E '^[[:space:]]*(- )?if:' "$workflow" || true)" "$platform only the aggregate is conditional and always runs"
    assert_contains "$matrix_body" "    runs-on: $image" "$platform uses its native hosted image"
    assert_contains "$matrix_body" "    timeout-minutes: $ceiling" "$platform retains its timeout ceiling"
    assert_contains "$matrix_body" "      fail-fast: false" "$platform does not cancel siblings after a failure"
    assert_contains "$matrix_body" "        shard: $ids" "$platform declares every shard"
    assert_not_contains "$matrix_body" '    needs:' "$platform matrix has no prerequisite"
    assert_contains "$matrix_body" "$suite_command" "$platform calls the correct runner and shard"
    assert_contains "$matrix_body" '        id: suite' "$platform identifies the suite step"
    assert_contains "$matrix_body" 'export HOME="$scratch/home" TMPDIR="$scratch/tmp"' "$platform sets isolated shard fixture paths"
    assert_contains "$gate_body" 'MATRIX_RESULT: ${{ needs.'"$matrix"'.result }}' "$platform checks the matrix outcome"
    keys=(MATRIX_RESULT)
    if [ "$platform" = linux ]; then
        checks_body="$(job_body "$workflow" checks)"
        assert_contains "$checks_body" '    runs-on: ubuntu-24.04' "Linux checks run on the hosted Linux image"
        assert_not_contains "$checks_body" '    needs:' "Linux checks run in parallel"
        for legacy in adoption_gate doctor lifecycle spec_navigation; do
            assert_contains "$checks_body" "bash tests/test_$legacy.sh" "legacy mawk: $legacy still runs"
        done
        assert_contains "$checks_body" 'run: jq --version' "Linux checks verify jq"
        assert_contains "$checks_body" 'xargs -0 shellcheck --exclude=SC1091' "Linux checks lint all scripts"
        assert_contains "$checks_body" 'git diff --check 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD' "Linux checks cumulative whitespace"
        assert_contains "$gate_body" 'CHECKS_RESULT: ${{ needs.checks.result }}' "Linux aggregate checks the compatibility and lint outcome"
        keys+=(CHECKS_RESULT)
    fi
    for ((leg = 1; leg <= count; leg++)); do
        assert_contains "$matrix_body" "shard-$leg: \${{ matrix.shard == $leg && steps.suite.outcome == 'success' && 'success' || '' }}" \
            "$platform leg $leg publishes its own success marker only"
        assert_contains "$gate_body" "SHARD_$leg: \${{ needs.$matrix.outputs.shard-$leg }}" "$platform aggregate reads the marker from leg $leg"
        keys+=("SHARD_$leg")
    done

    gate_script="$(printf '%s\n' "$gate_body" | awk '/^        run: \|$/ { body = 1; next }
        body && /^          / { sub(/^          /, ""); print; next }
        body { exit }')"
    [ -n "$gate_script" ] || _no "$platform aggregate must have a run block"
    passing=()
    for key in "${keys[@]}"; do passing+=("$key=success"); done
    aggregate "${passing[@]}"
    assert_eq 0 "$STATUS" "$platform aggregate passes when all work succeeded"
    for i in "${!keys[@]}"; do
        for rejected in failure cancelled timed_out skipped ''; do
            altered=("${passing[@]}")
            altered[i]="${keys[i]}=$rejected"
            aggregate "${altered[@]}"
            assert_eq 1 "$STATUS" "$platform aggregate rejects ${keys[i]}='$rejected'"
        done
    done
done

finish
