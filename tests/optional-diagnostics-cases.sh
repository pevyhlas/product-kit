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

_tiers_case_fail() {
    { _no "$1"; } 2>/dev/null
    return 1
}

_tiers_case_check() { # expected-grep-status fixed-label grep-arguments...
    local expected="$1" label="$2" status
    shift 2
    if grep "$@" >/dev/null 2>&1; then status=0; else status=$?; fi
    if [ "$status" -eq "$expected" ]; then _ok "$label"; else _tiers_case_fail "$label"; fi
}

_tiers_case_has() { _tiers_case_check 0 "$3" -qF "$2" "$1"; }
_tiers_case_result() { _tiers_case_check 0 "$3" -qxF "$2" "$1"; }

_tiers_case_size() { # file wc-flag fixed-label -> checked TIERS_CASE_SIZE
    local value label="$3"
    TIERS_CASE_SIZE=unavailable
    if value="$(wc "$2" < "$1")"; then :; else _tiers_case_fail "$label"; return 1; fi
    value="${value//[[:space:]]/}"
    case "$value" in ''|*[!0-9]*) _tiers_case_fail "$label"; return 1 ;; esac
    [ "${#value}" -le 9 ] || { _tiers_case_fail "$label"; return 1; }
    TIERS_CASE_SIZE="$value"
}

_tiers_case_private() {
    local status
    if grep -qE 'PRIVATE_SENTINEL|/private/|ignored null byte|command not found|Permission denied' "$1" >/dev/null; then status=0; else status=$?; fi
    [ "$status" -eq 1 ] || { _tiers_case_fail "$3"; return 1; }
    _tiers_case_check 1 "$3" -qF "$2" "$1"
}

_tiers_case_extract() {
    # Normalise ONLY completed no-match1 to success/known empty. An output-open failure
    # prevents this function from running and remains nonzero at its containing call.
    local status
    if grep '^optional-diag ' "$1"; then return 0; else status=$?; fi
    [ "$status" -eq 1 ]
}

_tiers_case_count() { # file pattern fixed-label -> checked TIERS_CASE_SIZE
    local value status label="$3"
    TIERS_CASE_SIZE=unavailable
    if value="$(grep -c "$2" "$1")"; then status=0; else status=$?; fi
    case "$status" in 0|1) ;; *) _tiers_case_fail "$label"; return 1 ;; esac
    case "$value" in ''|*[!0-9]*) _tiers_case_fail "$label"; return 1 ;; esac
    [ "${#value}" -le 9 ] || { _tiers_case_fail "$label"; return 1; }
    TIERS_CASE_SIZE="$value"
}

_tiers_case_prepare() {
    local dir="$1" status
    mkdir -p "$dir/tests" &&
        cp "$TESTS_DIR/lib.sh" "$dir/tests/lib.sh" &&
        cp "$TESTS_DIR/optional-diagnostics.sh" "$dir/tests/optional-diagnostics.sh" &&
        sed '/^it "a fresh install/,$d' "$TESTS_DIR/test_optional_subsystems.sh" > "$dir/tests/test_optional_subsystems.sh" || return 1
    grep -q '^tiers_assert_first_install()' "$dir/tests/test_optional_subsystems.sh" || return 1
    if grep -q '^it ' "$dir/tests/test_optional_subsystems.sh"; then return 1; else status=$?; fi
    [ "$status" -eq 1 ] || return 1
    _tiers_case_fixture "$dir/project"
}

_tiers_case_configure() {
    local dir="$1" mode="$2"
    case "$mode" in
        file-renderer|retention|undefined-callback|failing-callback|read-fault|pipeline-fault|parser-fault|invalid-hash|hash-error|sink-fault)
            rm "$dir/project/.prdkit/scripts/bash/render-agents.sh" || return ;;
        file-template) rm "$dir/project/.prdkit/templates/agent-definition-template.md" || return ;;
        row-renderer|row-template)
            local row=.prdkit/scripts/bash/render-agents.sh
            [ "$mode" != row-template ] || row=.prdkit/templates/agent-definition-template.md
            grep -v "  $row"'$' "$dir/project/.prdkit/.manifest" > "$dir/manifest" &&
                mv "$dir/manifest" "$dir/project/.prdkit/.manifest" || return 1 ;;
        rows-options)
            printf 'options: PRIVATE_SENTINEL\n%s  .prdkit/scripts/bash/render-agents.sh.extra\n%s  .prdkit/templates/agent-definition-template.md\n%s  .prdkit/templates/agent-definition-template.md\n' \
                aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
                aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa \
                aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "$dir/project/.prdkit/.manifest" || return ;;
        substring-choice|options-none|options-missing)
            grep -v '^options: ' "$dir/project/.prdkit/.manifest" > "$dir/manifest" || return
            case "$mode" in
                substring-choice) printf 'prefix options: agent-tiers suffix\n' >> "$dir/manifest" || return ;;
                options-none) printf 'options: none\n' >> "$dir/manifest" || return ;;
            esac
            mv "$dir/manifest" "$dir/project/.prdkit/.manifest" || return ;;
        options-duplicate) printf 'options: agent-tiers\n' >> "$dir/project/.prdkit/.manifest" || return ;;
        missing-helper) rm "$dir/tests/optional-diagnostics.sh" || return ;;
        unreadable-helper)
            chmod 000 "$dir/tests/optional-diagnostics.sh" || return
            # Explicit directory/read-error fallback for root, not permission proof.
            if [ -r "$dir/tests/optional-diagnostics.sh" ]; then
                rm "$dir/tests/optional-diagnostics.sh" && mkdir "$dir/tests/optional-diagnostics.sh" || return 1
            fi ;;
        nul-choice) printf 'options: agent-tiers\n\000PRIVATE_SENTINEL\n' > "$dir/project/.prdkit/.manifest" || return ;;
        read-error) rm "$dir/project/.prdkit/.manifest" && mkdir "$dir/project/.prdkit/.manifest" || return 1 ;;
    esac
    : > "$dir/predicate-calls"
}

_tiers_case_capture() { # fd3/fd4 have BOTH opened before we can launch anything
    TIERS_CASE_LAUNCHED=true
    if bash "$TESTS_DIR/optional-diagnostics-cases.sh" child "$1" "$2" >&3 2>&4; then
        TIERS_CASE_STATUS=0
    else TIERS_CASE_STATUS=$?; fi
    case "$TIERS_CASE_STATUS" in 0|1) return 0 ;; *) return 1 ;; esac
}

_tiers_diag_cases_body() {
    it "diagnostic controls (synthetic; separate from installation assertions)"
    local work dir mode status size expected_pass expected_fail expected_calls n rel before_fail="$_FAIL"
    if work="$(mktemp -d)" && [ -n "$work" ] && [ -d "$work" ]; then :; else
        _tiers_case_fail "diagnostic fixture allocated"; return 1
    fi
    track_tmp "$work"
    # Preserve the original suite counters separately in verbose and quiet invocations.
    printf 'Installation assertions: %s passed, %s failed\n' "$_PASS" "$_FAIL" ||
        { _tiers_case_fail "diagnostic header delivered"; return 1; }
    for mode in healthy substring-choice file-renderer file-template row-renderer row-template retention \
        grep-error rows-options options-none options-missing options-duplicate missing-helper unreadable-helper undefined-callback failing-callback \
        nul-choice substitution-nul read-error read-fault pipeline-fault parser-fault \
        invalid-hash hash-error sink-fault hash-tools; do
        dir="$work/$mode"
        _tiers_case_prepare "$dir" >/dev/null || { _tiers_case_fail "diagnostic actual caller and fixture prepared"; return 1; }
        _tiers_case_configure "$dir" "$mode" >/dev/null || { _tiers_case_fail "diagnostic fixture configured"; return 1; }
        TIERS_CASE_LAUNCHED=false
        # The enclosing body contains shell errors BEFORE either capture is opened.
        # Failed opens cannot be confused with expected child exit1: capture returns0
        # only after the launch ran and its separate status was saved.
        if _tiers_case_capture "$dir" "$mode" 3> "$dir/stdout" 4> "$dir/stderr"; then
            status="$TIERS_CASE_STATUS"
        else _tiers_case_fail "diagnostic child capture completed"; return 1; fi
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
        assert_eq "$n" "$status" "diagnostic $mode child exit" || return 1
        _tiers_case_size "$dir/stderr" -c "diagnostic $mode stderr contained" || return 1
        assert_eq 0 "$TIERS_CASE_SIZE" "diagnostic $mode stderr contained"
        _tiers_case_private "$dir/stdout" "$work" "diagnostic $mode stdout contained" || return 1
        _tiers_case_size "$dir/stdout" -c "diagnostic $mode output bounded" || return 1
        if [ "$TIERS_CASE_SIZE" -le 4096 ]; then _ok "diagnostic $mode output bounded"; else _tiers_case_fail "diagnostic $mode output bounded"; fi
        if _tiers_case_extract "$dir/stdout" > "$dir/diagnostic"; then :; else
            _tiers_case_fail "diagnostic $mode extraction completed"; return 1
        fi
        _tiers_case_size "$dir/diagnostic" -c "diagnostic $mode facts bounded and allowlisted" || return 1
        if [ "$TIERS_CASE_SIZE" -le 2048 ]; then
            LC_ALL=C _tiers_case_check 1 "diagnostic $mode facts bounded and allowlisted" -q '[^a-zA-Z0-9_= .-]' "$dir/diagnostic"
        else _tiers_case_fail "diagnostic $mode facts bounded and allowlisted"; fi
        [ "$mode" != hash-tools ] || continue
        _tiers_case_result "$dir/results" "pass=$expected_pass" "diagnostic $mode original pass count"
        _tiers_case_result "$dir/results" "fail=$expected_fail" "diagnostic $mode original fail count"
        _tiers_case_has "$dir/retained" retained "diagnostic $mode first output retained after run"
        _tiers_case_size "$dir/predicate-calls" -l "diagnostic $mode short circuit" || return 1
        assert_eq "$expected_calls" "$TIERS_CASE_SIZE" "diagnostic $mode short circuit"
        case "$mode" in
            healthy|substring-choice)
                _tiers_case_check 1 "diagnostic healthy emits no facts" -q '^optional-diag ' "$dir/stdout" ;;
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
                _tiers_case_count "$dir/stdout" '^optional-diag .*observed=' "diagnostic $mode all rechecks emitted" || return 1
                assert_eq 4 "$TIERS_CASE_SIZE" "diagnostic $mode all rechecks emitted" ;;
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
                _tiers_case_check 1 "diagnostic failed measure nonzero" -q 'measure_status=0' "$dir/stdout" ;;
            invalid-hash)
                _tiers_case_has "$dir/stdout" 'sha256=unavailable hash_status=1' "diagnostic invalid hash refused" ;;
            hash-error)
                _tiers_case_has "$dir/stdout" 'sha256=unavailable hash_status=23' "diagnostic hash tool failure retained" ;;
            file-template)
                _tiers_case_has "$dir/stdout" 'installed_sha256=ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad installed_hash_status=0' "diagnostic valid hash exact" ;;
        esac
    done
    [ "$_FAIL" -eq "$before_fail" ]
}

tiers_diag_cases() {
    # Deliberately only the NEW test runner, not inherited installation-suite output.
    # Same-shell grouping preserves counters and contains errors before any open/read.
    local before_fail="$_FAIL"
    if ! declare -F _tiers_parent_cases >/dev/null; then
        _tiers_case_fail "diagnostic parent controls available"; return 1
    fi
    if { _tiers_diag_cases_body; } 2>/dev/null; then :; else
        [ "$_FAIL" -ne "$before_fail" ] || _tiers_case_fail "diagnostic child controls completed"
        return 1
    fi
    if { _tiers_parent_cases; } 2>/dev/null; then :; else
        [ "$_FAIL" -ne "$before_fail" ] || _tiers_case_fail "diagnostic parent controls completed"
        return 1
    fi
}

_tiers_parent_injected() {
    builtin printf 'injected\n' > "$parent_root/injected"
}

_tiers_parent_probe() (
    # One level only: exercise the SAME parent body, not tiers_diag_cases(), which
    # also calls these probes. Never inherit cleanup ownership of the outer suite.
    local parent_root="$1" fault="$2" invalid_label='' invalid_pass=false operation=0 marker='' injected=false
    local saved_ok
    _TMPDIRS=(); trap _cleanup EXIT
    _PASS=0
    # shellcheck disable=SC2030 # Isolated probe counter; the outer runner checks exit AND its serialized value.
    _FAIL=0
    VERBOSE=false; TIERS_CASE_LAUNCHED=false
    case "$fault" in
        privacy-no-match) ;;
        privacy-*|path-error|capture-read) invalid_label='diagnostic healthy stdout contained' ;;
        stderr-measure) invalid_label='diagnostic healthy stderr contained' ;;
        stdout-measure) invalid_label='diagnostic healthy output bounded' ;;
        extract-*|diagnostic-measure|allowlist-error) invalid_label='diagnostic healthy facts bounded and allowlisted' ;;
        count-read) invalid_label='diagnostic healthy short circuit' ;;
        facts-count) invalid_label='diagnostic file-renderer all rechecks emitted' ;;
        healthy-absence) invalid_label='diagnostic healthy emits no facts' ;;
        failed-absence) invalid_label='diagnostic failed measure nonzero' ;;
        result-read) invalid_label='diagnostic healthy original pass count' ;;
    esac
    # Wrap the real harness operation solely to detect a specific false passing check.
    saved_ok="$(declare -f _ok)"
    eval "${saved_ok/_ok/_tiers_parent_saved_ok}"
    _ok() {
        [ -z "$invalid_label" ] || [ "$1" != "$invalid_label" ] || invalid_pass=true
        _tiers_parent_saved_ok "$@"
    }
    mktemp() {
        local allocated
        case "$fault" in
            allocation) _tiers_parent_injected || return 97; printf 'PRIVATE_PARENT_SENTINEL\n' >&2; return 23 ;;
            allocation-empty) _tiers_parent_injected || return 97; return 0 ;;
        esac
        allocated="$(command mktemp "$@")" || return
        case "$fault" in
            stdout-open|stderr-open|extract-open|setup-write)
                _tiers_parent_injected || return 97
                case "$fault" in
                    stdout-open) command mkdir -p "$allocated/healthy/stdout" || return ;;
                    stderr-open) command mkdir -p "$allocated/healthy/stderr" || return ;;
                    extract-open) command mkdir -p "$allocated/healthy/diagnostic" || return ;;
                    setup-write) command mkdir -p "$allocated/healthy/project/.prdkit/scripts/bash/render-agents.sh" || return ;;
                esac ;;
        esac
        builtin printf '%s\n' "$allocated"
    }
    mkdir() {
        if [ "$fault" = setup-mkdir ] || [ "$fault" = failure-message ]; then
            _tiers_parent_injected || return 97
            builtin printf 'PRIVATE_PARENT_SENTINEL /private/mkdir\n' >&2; return 23
        fi
        command mkdir "$@"
    }
    cp() {
        if [ "$fault" = setup-copy ]; then
            _tiers_parent_injected || return 97
            builtin printf 'PRIVATE_PARENT_SENTINEL /private/copy\n' >&2; return 23
        fi
        command cp "$@"
    }
    sed() {
        if [ "$fault" = setup-filter ]; then
            _tiers_parent_injected || return 97
            builtin printf 'partial\n'; builtin printf 'PRIVATE_PARENT_SENTINEL /private/filter\n' >&2; return 23
        fi
        command sed "$@"
    }
    bash() {
        local result
        if [ "$fault" = child-launch ]; then
            _tiers_parent_injected || return 97
            builtin printf 'PRIVATE_PARENT_SENTINEL /private/launch\n' >&2; return 127
        fi
        if command bash "$@"; then result=0; else result=$?; fi
        if [ "$fault" = capture-read ]; then
            command chmod 000 "$3/stdout" || return 97
            if [ -r "$3/stdout" ]; then
                command rm "$3/stdout" && command mkdir "$3/stdout" || return 97
            fi
            _tiers_parent_injected || return 97
        fi
        return "$result"
    }
    # shellcheck disable=SC2329 # Called indirectly by the actual parent body.
    printf() {
        if [ "$fault" = header-write ] && [ "${1:-}" = 'Installation assertions: %s passed, %s failed\n' ]; then
            _tiers_parent_injected || return 97
            builtin printf 'Installation assertions: '
            builtin printf 'PRIVATE_PARENT_SENTINEL /private/write\n' >&2; return 23
        fi
        # shellcheck disable=SC2059 # Forward the tested caller's constant format/arguments.
        builtin printf "$@"
    }
    # shellcheck disable=SC2329 # Called indirectly by the actual harness _no.
    echo() {
        if [ "$fault" = failure-message ]; then
            builtin printf 'PRIVATE_PARENT_SENTINEL /private/failure-message\n' >&2; return 23
        fi
        builtin echo "$@"
    }
    wc() {
        case "$fault:${label:-}" in
            stderr-measure:*'stderr contained'|stdout-measure:*'output bounded'|diagnostic-measure:*'facts bounded and allowlisted'|count-read:*'short circuit')
                _tiers_parent_injected || return 97
                builtin printf 0; builtin printf 'PRIVATE_PARENT_SENTINEL /private/measure\n' >&2; return 23 ;;
        esac
        command wc "$@"
    }
    grep() {
        local hit=false result=23
        case "$fault:$*" in
            privacy-error:*PRIVATE_SENTINEL*) hit=true ;;
            privacy-no-match:*PRIVATE_SENTINEL*) hit=true; result=1 ;;
            privacy-match:*PRIVATE_SENTINEL*) hit=true; result=0 ;;
            path-error:*'-qF '*'/healthy/stdout') hit=true ;;
            prefix-error:"-q ^it "*) hit=true ;;
            extract-read:"^optional-diag "*) hit=true ;;
            allowlist-error:*'[^a-zA-Z0-9_= .-]'*) hit=true ;;
            facts-count:"-c ^optional-diag .*observed="*) hit=true ;;
            healthy-absence:"-q ^optional-diag "*) hit=true ;;
            failed-absence:"-q measure_status=0 "*) hit=true ;;
            result-read:*'/results') hit=true ;;
        esac
        if [ "$hit" = true ]; then
            _tiers_parent_injected || return 97
            [ "$fault" != facts-count ] || builtin printf 4
            if [ "$result" -gt 1 ]; then builtin printf 'PRIVATE_PARENT_SENTINEL /private/inspection\n' >&2; fi
            return "$result"
        fi
        command grep "$@"
    }
    if [ "$fault" = fixed-load-write ] || [ "$fault" = fixed-choice-write ]; then
        # Actual caller bytes and inherited CLOSED stdout, not a substitute printer.
        if _tiers_case_prepare "$parent_root/caller" >/dev/null; then
            if [ "$fault" = fixed-load-write ]; then
                command rm "$parent_root/caller/tests/optional-diagnostics.sh" || exit 97
                _tiers_parent_injected || exit 97
                if source "$parent_root/caller/tests/test_optional_subsystems.sh" >&-; then operation=0; else operation=$?; fi
            else
                STATUS=0; OUTPUT=neutral
                _tiers_diag_choice() { return 23; }
                _tiers_parent_injected || exit 97
                if tiers_assert_first_install "$parent_root/caller/project" >&-; then operation=0; else operation=$?; fi
            fi
        else exit 97; fi
    else
        if { _tiers_diag_cases_body; } 2>/dev/null; then operation=0; else operation=$?; fi
    fi
    if { IFS= read -r marker < "$parent_root/injected"; } 2>/dev/null && [ "$marker" = injected ]; then injected=true; fi
    unset -f printf echo grep wc mkdir cp sed bash mktemp
    builtin printf 'parent-result pass=%s fail=%s operation=%s invalid_pass=%s injected=%s launched=%s\n' \
        "$_PASS" "$_FAIL" "$operation" "$invalid_pass" "$injected" "${TIERS_CASE_LAUNCHED:-false}"
    finish
)

_tiers_parent_capture() {
    if _tiers_parent_probe "$1" "$2" >&5 2>&6; then TIERS_PARENT_STATUS=0; else TIERS_PARENT_STATUS=$?; fi
    return 0 # A failed fd open at the call site cannot masquerade as expected probe exit1.
}

# shellcheck disable=SC2031 # Probe _FAIL is intentionally separate; this is the real outer harness counter.
_tiers_parent_cases() {
    it "diagnostic parent boundaries (separate synthetic assertions)"
    local root dir fault out err expected before_fail="$_FAIL"
    if root="$(mktemp -d)" && [ -n "$root" ] && [ -d "$root" ]; then track_tmp "$root"; else
        _tiers_case_fail "diagnostic parent fixture allocated"; return 1
    fi
    for fault in allocation allocation-empty setup-mkdir setup-copy setup-filter setup-write prefix-error \
        stdout-open stderr-open capture-read child-launch header-write failure-message \
        privacy-no-match privacy-match privacy-error path-error stderr-measure stdout-measure \
        extract-open extract-read diagnostic-measure allowlist-error count-read facts-count \
        healthy-absence failed-absence result-read fixed-load-write fixed-choice-write; do
        dir="$root/$fault"
        command mkdir "$dir" || { _tiers_case_fail "diagnostic parent fixture prepared"; return 1; }
        if _tiers_parent_capture "$dir" "$fault" 5> "$dir/stdout" 6> "$dir/stderr"; then :; else
            _tiers_case_fail "diagnostic parent capture opened"; return 1
        fi
        # Checked reads, then builtin inspection: no error-as-no-match in this outer
        # probe assertion layer. Failed/partial cat output is never consumed.
        if out="$(command cat "$dir/stdout")" && err="$(command cat "$dir/stderr")"; then :; else
            _tiers_case_fail "diagnostic parent captures readable"; return 1
        fi
        expected=1
        [ "$fault" != privacy-no-match ] || expected=0
        assert_eq "$expected" "$TIERS_PARENT_STATUS" "diagnostic parent $fault exit"
        if [ -z "$err" ]; then _ok "diagnostic parent $fault inherited stderr"; else _tiers_case_fail "diagnostic parent $fault inherited stderr"; fi
        case "$out" in *PRIVATE_PARENT_SENTINEL*|*/private/*|*"$root"*)
            _tiers_case_fail "diagnostic parent $fault inherited stdout" ;;
            *) _ok "diagnostic parent $fault inherited stdout" ;;
        esac
        if [ "${#out}" -le 4096 ]; then _ok "diagnostic parent $fault bounded"; else _tiers_case_fail "diagnostic parent $fault bounded"; fi
        case "$out" in *"invalid_pass=false injected=true"*) _ok "diagnostic parent $fault inspected without false pass" ;;
            *) _tiers_case_fail "diagnostic parent $fault inspected without false pass" ;;
        esac
        if [ "$expected" -eq 0 ]; then
            case "$out" in *"fail=0 operation=0"*) _ok "diagnostic parent completed no-match succeeds" ;;
                *) _tiers_case_fail "diagnostic parent completed no-match succeeds" ;;
            esac
        else
            case "$out" in *"fail=0 "*|*"fail=unavailable "*)
                _tiers_case_fail "diagnostic parent $fault failed assertion retained" ;;
                *"parent-result pass="*" fail="*) _ok "diagnostic parent $fault failed assertion retained" ;;
                *) _tiers_case_fail "diagnostic parent $fault failed assertion retained" ;;
            esac
        fi
        case "$fault" in stdout-open|stderr-open)
            case "$out" in *"launched=false"*) _ok "diagnostic parent $fault never launched child" ;;
                *) _tiers_case_fail "diagnostic parent $fault never launched child" ;;
            esac ;;
        esac
    done
    [ "$_FAIL" -eq "$before_fail" ]
}

if [ "${1:-}" = child ]; then _tiers_case_child "$2" "$3"; fi
