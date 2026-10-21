#!/usr/bin/env bash
# Product-Kit behavioral eval runner.
#
# Runs each scenario under tests/evals/scenarios/ against a coding agent
# (claude / codex / opencode — whatever you are already logged into) or the
# deterministic mock driver, then judges the outcome with the scenario's
# assert.sh. Policy (see tests/evals/README.md): local-only, runs on your
# existing harness subscription, no API keys, never part of CI.
#
# Usage: bash tests/evals/run-evals.sh [options]
#
# Options:
#   --driver NAME    Driver to use: claude | codex | opencode | mock
#                    (default: first of claude/codex/opencode found on PATH)
#   --scenario NAME  Run a single scenario by directory name (e.g. 02-implement-gate)
#   --keep           Keep fixture directories for post-mortem (prints their paths)
#   --list           List scenarios and detected drivers, then exit
#   -h, --help       Show this help
#
# Environment:
#   EVAL_RESULTS_DIR  Where transcripts + results.jsonl go (default: tests/evals/results/)
#   EVAL_MAX_TURNS    Turn cap for drivers that support one (default: 30)
#   EVAL_TIMEOUT      Per-scenario wall-clock cap in seconds, when the coreutils
#                     `timeout` command is available (default: 900)
#   EVAL_DRIVER_ARGS  Extra arguments appended to the driver invocation
#   EVAL_MOCK_MODE    mock driver only: comply (default) | violate

set -u

EVALS_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PK_ROOT="$(CDPATH="" cd "$EVALS_DIR/../.." && pwd)"
SCENARIOS_DIR="$EVALS_DIR/scenarios"
RESULTS_ROOT="${EVAL_RESULTS_DIR:-$EVALS_DIR/results}"
MAX_TURNS="${EVAL_MAX_TURNS:-30}"
TIMEOUT_S="${EVAL_TIMEOUT:-900}"

usage() { sed -n '2,27p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

DRIVER=""
ONLY=""
KEEP=false
LIST=false

while [ $# -gt 0 ]; do
    case "$1" in
        --driver)
            shift
            [ $# -gt 0 ] || { echo "Error: --driver requires a name" >&2; exit 1; }
            DRIVER="$1"
            ;;
        --scenario)
            shift
            [ $# -gt 0 ] || { echo "Error: --scenario requires a name" >&2; exit 1; }
            ONLY="$1"
            ;;
        --keep) KEEP=true ;;
        --list) LIST=true ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Error: unknown option '$1' (use --help)" >&2; exit 1 ;;
    esac
    shift
done

# --- Driver detection -------------------------------------------------------
# Real drivers are agent CLIs the developer is already logged into. The mock
# driver is a deterministic bash stub used to test the runner itself.
AVAILABLE=()
for d in claude codex opencode; do
    command -v "$d" >/dev/null 2>&1 && AVAILABLE+=("$d")
done

if $LIST; then
    echo "Scenarios:"
    for sdir in "$SCENARIOS_DIR"/*/; do
        [ -d "$sdir" ] || continue
        s="$(basename "$sdir")"
        desc=""
        [ -f "$sdir/README.md" ] && desc="$(head -n 1 "$sdir/README.md")"
        printf '  %-22s %s\n' "$s" "$desc"
    done
    echo
    if [ "${#AVAILABLE[@]}" -gt 0 ]; then
        echo "Detected drivers: ${AVAILABLE[*]} (plus: mock)"
    else
        echo "Detected drivers: none (mock always available)"
    fi
    exit 0
fi

if [ -z "$DRIVER" ]; then
    if [ "${#AVAILABLE[@]}" -gt 0 ]; then
        DRIVER="${AVAILABLE[0]}"
    else
        echo "No agent CLI found on PATH (looked for: claude, codex, opencode)." >&2
        echo "Install one and log in with your existing subscription, or check the" >&2
        echo "runner plumbing without an agent: --driver mock" >&2
        exit 1
    fi
fi

case "$DRIVER" in
    claude|codex|opencode)
        if ! command -v "$DRIVER" >/dev/null 2>&1; then
            echo "Driver '$DRIVER' is not installed (not found on PATH)." >&2
            echo "Install it and log in, or pick another: claude, codex, opencode, mock." >&2
            exit 1
        fi
        ;;
    mock) : ;;
    *)
        echo "Unknown driver '$DRIVER'. Supported drivers: claude, codex, opencode, mock." >&2
        exit 1
        ;;
esac

# Record the actual environment; an installed CLI is not evidence of a tested harness version.
source "$PK_ROOT/scripts/common.sh"
if [ "$DRIVER" = mock ]; then
    DRIVER_VERSION=offline-mock
else
    DRIVER_VERSION="$("$DRIVER" --version 2>/dev/null | head -n 1)"
    DRIVER_VERSION="${DRIVER_VERSION:-unknown}"
fi
KIT_VERSION="$(head -n 1 "$PK_ROOT/VERSION")"
KIT_REVISION="$(git -C "$PK_ROOT" rev-parse HEAD 2>/dev/null || printf unknown)"
KIT_DIRTY=false
if [ -n "$(git -C "$PK_ROOT" status --porcelain 2>/dev/null)" ]; then KIT_DIRTY=true; fi

# Wrap the driver in a wall-clock cap when coreutils `timeout` exists;
# otherwise run it uncapped (rely on the driver's own turn limits).
run_capped() {
    if command -v timeout >/dev/null 2>&1; then
        timeout "$TIMEOUT_S" "$@"
    else
        "$@"
    fi
}

# Invoke the selected driver with a prompt. Called with cwd = the fixture.
# Flag notes (verified against each CLI's --help / official docs):
#   claude:   `claude -p/--print --output-format json ... -- "<prompt>"`; the
#             turn cap flag (--max-turns) is not present in every release, so
#             probe --help and degrade gracefully when absent. --allowed-tools
#             lets the headless session read/edit files and run scripts — it is
#             VARIADIC (<tools...>), so the prompt must sit behind a `--`
#             terminator or the option swallows it and the CLI exits 1 with
#             "Input must be provided either through stdin or as a prompt
#             argument".
#   codex:    `codex exec --json --sandbox workspace-write "<prompt>"`.
#   opencode: `opencode run --format json "<prompt>"`.
invoke_driver() {
    local prompt="$1"
    # EVAL_DRIVER_ARGS is intentionally word-split into extra CLI arguments.
    # shellcheck disable=SC2206
    local extra=(${EVAL_DRIVER_ARGS:-})
    case "$DRIVER" in
        claude)
            local args=(--print --output-format json --allowed-tools "Bash,Edit,Write,Read,Glob,Grep")
            if claude --help 2>/dev/null | grep -q -- '--max-turns'; then
                args+=(--max-turns "$MAX_TURNS")
            fi
            run_capped claude "${args[@]}" ${extra[@]+"${extra[@]}"} -- "$prompt"
            ;;
        codex)
            run_capped codex exec --json --sandbox workspace-write ${extra[@]+"${extra[@]}"} "$prompt"
            ;;
        opencode)
            run_capped opencode run --format json ${extra[@]+"${extra[@]}"} "$prompt"
            ;;
        mock)
            run_capped bash "$EVALS_DIR/drivers/mock.sh" ${extra[@]+"${extra[@]}"} "$prompt"
            ;;
    esac
}

# --- Run scenarios ----------------------------------------------------------
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
RUN_DIR="$RESULTS_ROOT/$RUN_ID"
mkdir -p "$RUN_DIR"
JSONL="$RUN_DIR/results.jsonl"

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; Z=$'\033[0m'; else G=; R=; B=; Z=; fi

echo "${B}Product-Kit behavioral evals${Z} — driver: $DRIVER"
echo

passed=0; failed=0; errored=0; matched=0
ROWS=()

for sdir in "$SCENARIOS_DIR"/*/; do
    [ -d "$sdir" ] || continue
    s="$(basename "$sdir")"
    if [ -n "$ONLY" ] && [ "$s" != "$ONLY" ]; then continue; fi
    matched=$((matched + 1))

    fixture="$(mktemp -d)"
    transcript="$RUN_DIR/$s.transcript.txt"
    export FIXTURE="$fixture" PK_ROOT EVAL_SCENARIO="$s" TRANSCRIPT="$transcript"

    echo "${B}▶ $s${Z} (driver: $DRIVER)"
    start="$(date +%s)"
    verdict="error"
    drv_exit="-"

    if bash "$sdir/setup.sh" >"$RUN_DIR/$s.setup.log" 2>&1; then
        cp "$fixture/.prdkit/.manifest" "$RUN_DIR/$s.install-manifest"
        prompt="$(cat "$sdir/prompt.txt")"
        ( cd "$fixture" && invoke_driver "$prompt" ) >"$transcript" 2>&1
        drv_exit=$?
        if [ "$drv_exit" != "0" ]; then
            # A crashed or timed-out driver must never satisfy a refusal
            # scenario by inaction — that is an ERROR, not a pass.
            echo "  driver exited $drv_exit — see $transcript"
        elif bash "$sdir/assert.sh" >"$RUN_DIR/$s.assert.log" 2>&1; then
            verdict="pass"
        else
            verdict="fail"
        fi
    else
        echo "  setup failed — see $RUN_DIR/$s.setup.log"
    fi

    dur=$(( $(date +%s) - start ))
    case "$verdict" in
        pass)  passed=$((passed + 1));  echo "  ${G}PASS${Z} (${dur}s)" ;;
        fail)  failed=$((failed + 1));  echo "  ${R}FAIL${Z} (${dur}s) — see $RUN_DIR/$s.assert.log" ;;
        error) errored=$((errored + 1)); echo "  ${R}ERROR${Z} (${dur}s)" ;;
    esac

    printf '{"ts":"%s","run":"%s","scenario":"%s","driver":"%s","driver_version":"%s","kit_version":"%s","kit_revision":"%s","kit_dirty":%s,"verdict":"%s","driver_exit":"%s","duration_s":%d,"transcript":"%s"}\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RUN_ID" "$s" "$DRIVER" "$(json_escape "$DRIVER_VERSION")" "$(json_escape "$KIT_VERSION")" "$KIT_REVISION" "$KIT_DIRTY" "$verdict" "$drv_exit" "$dur" "$(json_escape "$transcript")" >> "$JSONL"
    ROWS+=("$(printf '%-24s %-10s %-8s %4ss' "$s" "$DRIVER" "$verdict" "$dur")")

    if $KEEP; then
        echo "  fixture kept: $fixture"
    else
        rm -rf "$fixture"
    fi
    echo
done

if [ "$matched" -eq 0 ]; then
    echo "No scenario matched '${ONLY:-*}' under $SCENARIOS_DIR" >&2
    exit 1
fi

echo "────────────────────────────────────────────────"
printf '%-24s %-10s %-8s %5s\n' "SCENARIO" "DRIVER" "VERDICT" "TIME"
for row in "${ROWS[@]}"; do echo "$row"; done
echo "────────────────────────────────────────────────"
echo "Results: $passed passed, $failed failed, $errored errored — details in $RUN_DIR"

if [ "$failed" -eq 0 ] && [ "$errored" -eq 0 ]; then
    echo "${G}ALL SCENARIOS PASSED${Z}"
    exit 0
else
    echo "${R}SCENARIOS FAILED${Z}"
    exit 1
fi
