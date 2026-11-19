#!/usr/bin/env bash
# Continuing synthetic controls, sourced by the optional suite and its native command.
# Children source an exact caller PREFIX (through the first installation case boundary),
# never a duplicate predicate/reporter or the real installer. No private witness paths.
# shellcheck disable=SC2034 # Observations are consumed by the actual caller/helper.

_tiers_case_fixture() {
    local root="$1" rel
    mkdir -p "$root/.prdkit/scripts/bash" "$root/.prdkit/templates" \
        "$root/.product-kit/scripts" "$root/.product-kit/templates" || return
    for rel in .prdkit/scripts/bash/render-agents.sh .prdkit/templates/agent-definition-template.md \
        .product-kit/scripts/render-agents.sh .product-kit/templates/agent-definition-template.md; do
        printf abc > "$root/$rel" || return
    done
    printf 'options: agent-tiers\n%s  .prdkit/scripts/bash/render-agents.sh\n%s  .prdkit/templates/agent-definition-template.md\n' \
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
        aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "$root/.prdkit/.manifest"
}

_tiers_case_child() {
    local dir="$1" mode="$2" result status rel count=0
    # This is the actual checked-in caller prefix, with the actual helper-load boundary.
    source "$dir/tests/test_optional_subsystems.sh"
    PROJ="$dir/project"
    case "$mode" in
        undefined-callback) unset -f tiers_diag_original_failure ;;
        failing-callback)
            tiers_diag_original_failure() {
                printf '%s\n' PRIVATE_SENTINEL
                printf '%s\n' 'PRIVATE_SENTINEL /private/callback' >&2
                return 23
            } ;;
        substitution-nul)
            # Induced helper failure exercises the enclosing assignment's own Bash
            # warning channel. Normal NUL input separately exercises the real helper.
            _tiers_diag_choice() { printf 'PRIVATE_SENTINEL\000/private/choice'; return 23; } ;;
        invalid-hash)
            sha256sum() { printf '%s\n' PRIVATE_SENTINEL; }
            shasum() { printf '%s\n' PRIVATE_SENTINEL; } ;;
        hash-error)
            sha256sum() { printf '%s\n' PRIVATE_SENTINEL; printf '%s\n' PRIVATE_SENTINEL >&2; return 23; }
            shasum() { sha256sum; } ;;
        read-fault)
            wc() { printf 0; printf '%s\n' PRIVATE_SENTINEL >&2; return 23; } ;;
        pipeline-fault)
            tr() { printf '%s\n' PRIVATE_SENTINEL >&2; return 23; } ;;
        parser-fault)
            awk() { printf '0 0 agent-tiers\n'; printf '%s\n' PRIVATE_SENTINEL >&2; return 23; } ;;
    esac
    if [ "$mode" = hash-tools ]; then
        # Known SHA256("abc"), not another hash implementation as the oracle.
        local digest=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
        if command -v sha256sum >/dev/null 2>&1; then
            result="$(_tiers_diag_hash "$PROJ/.product-kit/scripts/render-agents.sh" 2>/dev/null)"
            assert_eq "$digest" "$result" "diagnostic real available hash tool"
            count=$((count + 1))
        fi
        if command -v shasum >/dev/null 2>&1; then
            mkdir "$dir/shasum-only"
            ln -s "$(command -v shasum)" "$dir/shasum-only/shasum"
            result="$(PATH="$dir/shasum-only" _tiers_diag_hash "$PROJ/.product-kit/scripts/render-agents.sh" 2>/dev/null)"
            assert_eq "$digest" "$result" "diagnostic real shasum fallback"
            count=$((count + 1))
        fi
        [ "$count" -gt 0 ] || _no "diagnostic existing hash tool available"
        mkdir "$dir/no-tools"
        if result="$(PATH="$dir/no-tools" _tiers_diag_hash "$PROJ/.product-kit/scripts/render-agents.sh" 2>/dev/null)"; then
            status=0
        else status=$?; fi
        assert_eq 127 "$status" "diagnostic unavailable hash tools are not success"
        assert_eq "" "$result" "diagnostic unavailable hash has no payload"
        finish
    fi

    grep() {
        # Side channel is a neutral call count, never public fixture data.
        case " ${FUNCNAME[*]} " in
            *" tiers_installed "*)
                printf 'predicate\n' >> "$dir/predicate-calls"
                case "$mode" in grep-error|rows-options|options-none|options-missing|options-duplicate)
                    printf '%s\n' PRIVATE_SENTINEL
                    printf '%s\n' 'PRIVATE_SENTINEL /private/grep' >&2
                    return 2 ;;
                esac ;;
        esac
        command grep "$@"
    }
    STATUS=0; OUTPUT='PRIVATE_SENTINEL /private/first-output'
    [ "$mode" != retention ] || STATUS=23
    tiers_assert_first_install "$PROJ"
    # No installer is run: only overwrite the harness result, as recovery's run() does.
    run bash -c 'printf recovery'
    case "$mode" in healthy|missing-helper|unreadable-helper|nul-choice|substitution-nul|hash-tools) ;;
        *)
            # Exercise the real reporter again with a closed descriptor after the
            # original failure. Delivery may be partial; the existing failure must stay.
            if [ "$mode" = sink-fault ]; then
                if tiers_diag_report "$PROJ" >&-; then status=0; else status=$?; fi
                printf 'sink_status=%s\n' "$status" > "$dir/sink-status"
            fi ;;
    esac
    printf 'pass=%s\nfail=%s\nfirst_status=%s\noriginal_item=%s\noriginal_check=%s\noriginal_status=%s\n' \
        "$_PASS" "$_FAIL" "$TIERS_DIAG_FIRST_STATUS" "$TIERS_DIAG_ORIGINAL_ITEM" \
        "$TIERS_DIAG_ORIGINAL_CHECK" "$TIERS_DIAG_ORIGINAL_STATUS" > "$dir/results"
    if [ "$TIERS_DIAG_FIRST_OUTPUT" = 'PRIVATE_SENTINEL /private/first-output' ]; then
        printf 'retained\n' > "$dir/retained"
    fi
    finish # Expected failed children really exit1; parent must assert it.
}

_tiers_case_has() { # file literal fixed-public-label; never echo failed child content
    if grep -qF "$2" "$1" 2>/dev/null; then _ok "$3"; else _no "$3"; fi
}

_tiers_case_result() {
    if grep -qxF "$2" "$1" 2>/dev/null; then _ok "$3"; else _no "$3"; fi
}

tiers_diag_cases() {
    it "diagnostic controls (synthetic; separate from installation assertions)"
    local work dir mode status size expected_pass expected_fail expected_calls n rel
    work="$(mktemp -d)" || { _no "diagnostic fixture allocated"; return; }
    track_tmp "$work"
    # Preserve the original suite counters separately in verbose and quiet invocations.
    printf 'Installation assertions: %s passed, %s failed\n' "$_PASS" "$_FAIL"
    for mode in healthy substring-choice file-renderer file-template row-renderer row-template retention \
        grep-error rows-options options-none options-missing options-duplicate missing-helper unreadable-helper undefined-callback failing-callback \
        nul-choice substitution-nul read-error read-fault pipeline-fault parser-fault \
        invalid-hash hash-error sink-fault hash-tools; do
        dir="$work/$mode"
        mkdir -p "$dir/tests" || { _no "diagnostic fixture prepared"; return; }
        if ! { cp "$TESTS_DIR/lib.sh" "$dir/tests/lib.sh" &&
            cp "$TESTS_DIR/optional-diagnostics.sh" "$dir/tests/optional-diagnostics.sh" &&
            sed '/^it "a fresh install/,$d' "$TESTS_DIR/test_optional_subsystems.sh" > "$dir/tests/test_optional_subsystems.sh"; }; then
            _no "diagnostic actual caller copied"; return
        fi
        if ! grep -q '^tiers_assert_first_install()' "$dir/tests/test_optional_subsystems.sh" ||
            grep -q '^it ' "$dir/tests/test_optional_subsystems.sh"; then
            _no "diagnostic caller boundary present"; return
        fi
        _tiers_case_fixture "$dir/project" || { _no "diagnostic neutral fixture prepared"; return; }
        case "$mode" in
            file-renderer|retention|undefined-callback|failing-callback|read-fault|pipeline-fault|parser-fault|invalid-hash|hash-error|sink-fault)
                rm "$dir/project/.prdkit/scripts/bash/render-agents.sh" ;;
            file-template) rm "$dir/project/.prdkit/templates/agent-definition-template.md" ;;
            row-renderer)
                grep -v '  .prdkit/scripts/bash/render-agents.sh$' "$dir/project/.prdkit/.manifest" > "$dir/manifest"
                mv "$dir/manifest" "$dir/project/.prdkit/.manifest" ;;
            row-template)
                grep -v '  .prdkit/templates/agent-definition-template.md$' "$dir/project/.prdkit/.manifest" > "$dir/manifest"
                mv "$dir/manifest" "$dir/project/.prdkit/.manifest" ;;
            rows-options)
                printf 'options: PRIVATE_SENTINEL\n%s  .prdkit/scripts/bash/render-agents.sh.extra\n%s  .prdkit/templates/agent-definition-template.md\n%s  .prdkit/templates/agent-definition-template.md\n' \
                    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
                    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
                    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "$dir/project/.prdkit/.manifest" ;;
            substring-choice|options-none|options-missing)
                grep -v '^options: ' "$dir/project/.prdkit/.manifest" > "$dir/manifest"
                case "$mode" in
                    substring-choice) printf 'prefix options: agent-tiers suffix\n' >> "$dir/manifest" ;;
                    options-none) printf 'options: none\n' >> "$dir/manifest" ;;
                esac
                mv "$dir/manifest" "$dir/project/.prdkit/.manifest" ;;
            options-duplicate) printf 'options: agent-tiers\n' >> "$dir/project/.prdkit/.manifest" ;;
            missing-helper) rm "$dir/tests/optional-diagnostics.sh" ;;
            unreadable-helper)
                chmod 000 "$dir/tests/optional-diagnostics.sh"
                # Root can still read chmod000. A directory is a portable source/read
                # error instead; no claim of a root permission-denial reproduction.
                if [ -r "$dir/tests/optional-diagnostics.sh" ]; then
                    rm "$dir/tests/optional-diagnostics.sh"
                    mkdir "$dir/tests/optional-diagnostics.sh"
                fi ;;
            nul-choice) printf 'options: agent-tiers\n\000PRIVATE_SENTINEL\n' > "$dir/project/.prdkit/.manifest" ;;
            read-error) rm "$dir/project/.prdkit/.manifest"; mkdir "$dir/project/.prdkit/.manifest" ;;
        esac
        : > "$dir/predicate-calls"
        if bash "$TESTS_DIR/optional-diagnostics-cases.sh" child "$dir" "$mode" > "$dir/stdout" 2> "$dir/stderr"; then
            status=0
        else status=$?; fi
        # All assertions have bounded public payloads even if a child regresses/leaks.
        expected_pass=2; expected_fail=1; expected_calls=0
        case "$mode" in
            healthy|substring-choice) expected_pass=3; expected_fail=0; expected_calls=2 ;;
            missing-helper|unreadable-helper) expected_pass=2; expected_fail=2; expected_calls=2 ;;
            file-template) expected_calls=1 ;;
            row-renderer) expected_calls=1 ;;
            row-template) expected_calls=2 ;;
            retention) expected_pass=1; expected_fail=2 ;;
            grep-error) expected_calls=1 ;;
            options-none|options-missing) expected_pass=1; expected_fail=2; expected_calls=1 ;;
            options-duplicate) expected_calls=1 ;;
            rows-options) expected_pass=1; expected_fail=2; expected_calls=1 ;;
            nul-choice) expected_pass=1; expected_fail=2; expected_calls=1 ;;
            substitution-nul) expected_calls=2 ;;
            read-error) expected_pass=1; expected_fail=2; expected_calls=1 ;;
            read-fault|pipeline-fault) expected_pass=1; expected_fail=2 ;;
            hash-tools) expected_fail=0 ;;
        esac
        if [ "$expected_fail" -eq 0 ]; then n=0; else n=1; fi
        assert_eq "$n" "$status" "diagnostic $mode child exit"
        size="$(wc -c < "$dir/stderr")"; size="${size//[[:space:]]/}"
        assert_eq 0 "$size" "diagnostic $mode stderr contained"
        if grep -qE 'PRIVATE_SENTINEL|/private/|ignored null byte|command not found|Permission denied' "$dir/stdout" ||
            grep -qF "$work" "$dir/stdout"; then
            _no "diagnostic $mode stdout contained"
        else _ok "diagnostic $mode stdout contained"; fi
        size="$(wc -c < "$dir/stdout")"; size="${size//[[:space:]]/}"
        if [ "$size" -le 4096 ]; then _ok "diagnostic $mode output bounded"; else _no "diagnostic $mode output bounded"; fi
        grep '^optional-diag ' "$dir/stdout" > "$dir/diagnostic" || :
        size="$(wc -c < "$dir/diagnostic")"; size="${size//[[:space:]]/}"
        if [ "$size" -le 2048 ] && ! LC_ALL=C grep -q '[^a-zA-Z0-9_= .-]' "$dir/diagnostic"; then
            _ok "diagnostic $mode facts bounded and allowlisted"
        else _no "diagnostic $mode facts bounded and allowlisted"; fi
        [ "$mode" != hash-tools ] || continue
        _tiers_case_result "$dir/results" "pass=$expected_pass" "diagnostic $mode original pass count"
        _tiers_case_result "$dir/results" "fail=$expected_fail" "diagnostic $mode original fail count"
        _tiers_case_has "$dir/retained" retained "diagnostic $mode first output retained after run"
        size="$(wc -l < "$dir/predicate-calls")"; size="${size//[[:space:]]/}"
        assert_eq "$expected_calls" "$size" "diagnostic $mode short circuit"
        case "$mode" in
            healthy|substring-choice)
                if grep -q '^optional-diag ' "$dir/stdout"; then _no "diagnostic healthy emits no facts"; else _ok "diagnostic healthy emits no facts"; fi ;;
            missing-helper|unreadable-helper)
                _tiers_case_has "$dir/stdout" 'optional-diag status=unavailable stage=load' "diagnostic load failure explicit"
                _tiers_case_has "$dir/stdout" 'optional-diag status=unavailable stage=choice' "diagnostic missing choice cannot pass" ;;
            undefined-callback|failing-callback)
                _tiers_case_has "$dir/stdout" 'optional-diag status=unavailable stage=callback' "diagnostic callback failure explicit" ;;
            nul-choice|substitution-nul)
                _tiers_case_has "$dir/stdout" 'optional-diag status=unavailable stage=choice' "diagnostic malformed choice cannot pass" ;;
            sink-fault)
                _tiers_case_has "$dir/sink-status" 'sink_status=1' "diagnostic sink failure nonzero"
                _tiers_case_has "$dir/results" 'fail=1' "diagnostic sink cannot clear failure" ;;
        esac
        case "$mode" in
            file-renderer|file-template|row-renderer|row-template|retention|grep-error|rows-options|options-none|options-missing|options-duplicate|read-error|read-fault|pipeline-fault|parser-fault|invalid-hash|hash-error|sink-fault)
                size="$(grep -c '^optional-diag .*observed=' "$dir/stdout")"
                assert_eq 4 "$size" "diagnostic $mode all rechecks emitted" ;;
        esac
        case "$mode" in
            retention)
                _tiers_case_has "$dir/stdout" 'upgrade_status=23 output_retained=1' "diagnostic first status23 retained"
                _tiers_case_has "$dir/results" 'first_status=23' "diagnostic first status survives run" ;;
            grep-error|rows-options|options-none|options-missing|options-duplicate)
                _tiers_case_has "$dir/stdout" 'observed=original item=renderer check=manifest status=2 predicate_status=1' "diagnostic original error2 retained"
                _tiers_case_has "$dir/stdout" 'grep_status=0 exact_rows=' "diagnostic later successful recheck distinct" ;;
            row-renderer|row-template)
                _tiers_case_has "$dir/stdout" 'check=manifest status=1 predicate_status=1' "diagnostic original no-match1 distinct" ;;
            file-renderer|file-template)
                rel=renderer
                [ "$mode" != file-template ] || rel=template
                _tiers_case_has "$dir/stdout" "observed=original item=$rel check=file status=1 predicate_status=1" "diagnostic original file and order retained" ;;
        esac
        case "$mode" in
            rows-options)
                _tiers_case_has "$dir/stdout" 'measure_status=0 options=invalid' "diagnostic options allowlisted"
                _tiers_case_has "$dir/stdout" 'grep_status=0 exact_rows=0' "diagnostic substring is not exact row"
                _tiers_case_has "$dir/stdout" 'grep_status=0 exact_rows=2' "diagnostic duplicate exact rows counted" ;;
            options-none)
                _tiers_case_has "$dir/stdout" 'measure_status=0 options=none' "diagnostic none option distinct" ;;
            options-missing|options-duplicate)
                _tiers_case_has "$dir/stdout" 'measure_status=0 options=unavailable' "diagnostic missing or duplicate option unavailable" ;;
            row-renderer)
                _tiers_case_has "$dir/stdout" 'grep_status=1 exact_rows=0' "diagnostic measured zero distinct from unavailable" ;;
            read-error|read-fault|pipeline-fault|parser-fault)
                _tiers_case_has "$dir/stdout" 'options=unavailable' "diagnostic failed measurement unavailable"
                _tiers_case_has "$dir/stdout" 'exact_rows=unavailable' "diagnostic failed rows not zero"
                if grep -q 'measure_status=0' "$dir/stdout"; then _no "diagnostic failed measure nonzero"; else _ok "diagnostic failed measure nonzero"; fi ;;
            invalid-hash)
                _tiers_case_has "$dir/stdout" 'sha256=unavailable hash_status=1' "diagnostic invalid hash refused" ;;
            hash-error)
                _tiers_case_has "$dir/stdout" 'sha256=unavailable hash_status=23' "diagnostic hash tool failure retained" ;;
            file-template)
                _tiers_case_has "$dir/stdout" 'installed_sha256=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad installed_hash_status=0' "diagnostic valid hash exact" ;;
        esac
    done
}

if [ "${1:-}" = child ]; then _tiers_case_child "$2" "$3"; fi
