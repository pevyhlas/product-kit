#!/usr/bin/env bash
# Negative cases use only disposable projects and sentinel files.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJ="$(make_inited_project)"; track_tmp "$PROJ"
PROJ="$(cd "$PROJ" && pwd -P)"
RS="$PROJ/.prdkit/scripts/bash/retrospective.sh"
FID=055-telemetry
DIR="$PROJ/.prdkit/cache/retrospectives"
RETRO="$DIR/$FID.md"
ENRICH="$PROJ/.prdkit/retrospective/$FID.enrich.json"
mkdir -p "$DIR" "$PROJ/.prdkit/retrospective" "$PROJ/outside"
printf 'sentinel\n' > "$PROJ/outside/sentinel"

reject() {
    run bash "$RS" "$@"
    assert_eq 1 "$STATUS" "reject target/input: $*"
    assert_eq sentinel "$(cat "$RETRO")" "rejection preserves previous report"
    assert_eq sentinel "$(cat "$PROJ/outside/sentinel")" "outside sentinel unchanged"
}

it "invalid change ids cannot create or replace reports"
printf 'sentinel\n' > "$RETRO"
for target in '' . .. _archive ../055-telemetry specs/features/055-telemetry /055-telemetry 055-telemetry/../x --help; do
    reject "$target"
done
reject "$FID" extra
assert_eq no "$([ -e "$PROJ/outside/055-telemetry.md" ] && echo yes || echo no)" "nothing written outside"

it "every output path component must be a physical directory inside the repo"
mv "$DIR" "$PROJ/outside/retros"
ln -s "$PROJ/outside/retros" "$DIR"
reject "$FID"
rm "$DIR"; mv "$PROJ/outside/retros" "$DIR"
mv "$PROJ/.prdkit/cache" "$PROJ/outside/cache"
ln -s "$PROJ/outside/cache" "$PROJ/.prdkit/cache"
reject "$FID"
rm "$PROJ/.prdkit/cache"; mv "$PROJ/outside/cache" "$PROJ/.prdkit/cache"

it "predictable temporary and output symlinks cannot redirect writes"
ln -s "$PROJ/outside/sentinel" "$RETRO.tmp"
run bash "$RS" "$FID"
assert_eq 0 "$STATUS" "legacy temporary name is unused"
assert_eq sentinel "$(cat "$PROJ/outside/sentinel")" "temporary symlink target preserved"
assert_symlink "$RETRO.tmp"
rm "$RETRO" "$RETRO.tmp"
ln -s "$PROJ/outside/sentinel" "$RETRO"
reject "$FID"
rm "$RETRO"
mkdir "$RETRO"
run bash "$RS" "$FID"
assert_eq 1 "$STATUS" "output directory rejected, not used as mv destination"
rmdir "$RETRO"
printf 'sentinel\n' > "$RETRO"

it "implicit resolution uses the current branch only when it is a change id"
git -C "$PROJ" checkout -qb "$FID"
run bash "$RS"
assert_eq 0 "$STATUS" "current change resolves"
git -C "$PROJ" checkout -qb not-a-change
printf 'sentinel\n' > "$RETRO"
reject
git -C "$PROJ" checkout -q --detach
reject
git -C "$PROJ" checkout -q "$FID"
printf 'sentinel\n' > "$RETRO"

fixture() {
    cat > "$ENRICH" <<JSON
{
  "schema": "${SCHEMA:-prdkit.retrospective.enrich.v1}",
  "feature": "${IDENTITY:-055-telemetry}",
  "sessions": ${SESSIONS:-1},
  "tokens": {
    "total": ${TOTAL:-100},
    "by_type": {
      "reasoning": ${REASONING:-50}
    },
    "by_model": {
      "example/model": ${MODEL:-100}
    },
    "by_effort": {
      "high": ${EFFORT:-100}
    },
    "by_agent": {
      "review": ${AGENT:-100}
    }
  }
}
JSON
}

it "enrichment identity and supported schema are mandatory"
SCHEMA=wrong fixture; reject "$FID"
IDENTITY=777-other fixture; reject "$FID"
printf '{"tokens":{"total":100}}\n' > "$ENRICH"; reject "$FID"
printf '{"schema":"prdkit.retrospective.enrich.v1","feature":"055-telemetry","tokens":{"feature":"777-other","total":100},"feature":"777-other"}\n' > "$ENRICH"
reject "$FID"
fixture
printf 'trailing garbage\n' >> "$ENRICH"; reject "$FID"

it "numeric inputs are data, never Bash expressions, and have bounded decimal types"
# shellcheck disable=SC2016 # Deliberately literal attack data; the test must not execute it.
PAYLOAD='a[$(touch '"$PROJ/outside/executed"')]' # disposable execution witness
for bad in null true '"50"' -1 1.5 1+1 "$PAYLOAD" '"'"$PAYLOAD"'"' 9999999999999999999999999999999999; do
    TOTAL="$bad" fixture; reject "$FID"
    REASONING="$bad" fixture; reject "$FID"
    MODEL="$bad" fixture; reject "$FID"
    EFFORT="$bad" fixture; reject "$FID"
    AGENT="$bad" fixture; reject "$FID"
    SESSIONS="$bad" fixture; reject "$FID"
    assert_eq no "$([ -e "$PROJ/outside/executed" ] && echo yes || echo no)" "malformed arithmetic never executes"
done

it "zero and maximum supported totals remain valid, with safe percentage arithmetic"
TOTAL=0 REASONING=0 MODEL=0 EFFORT=0 AGENT=0 fixture
run bash "$RS" "$FID"
assert_eq 0 "$STATUS" "zero total does not divide by zero"
TOTAL=999999999999 REASONING=999999999999 MODEL=999999999999 EFFORT=0 AGENT=0 fixture
run bash "$RS" "$FID"
assert_eq 0 "$STATUS" "bounded maximum supported"
assert_contains "$(cat "$RETRO")" 'Reasoning tokens are 100%' "percentage multiplication does not overflow"
assert_contains "$(cat "$RETRO")" 'accounts for 100%' "model percentage does not overflow"
TOTAL=1e2 REASONING=8e0 MODEL=1e2 fixture
run bash "$RS" "$FID"
assert_eq 0 "$STATUS" "integer-valued JSON numbers normalize before use"
assert_contains "$(cat "$RETRO")" 'Total tokens:** 100' "total normalized to decimal"
assert_contains "$(cat "$RETRO")" 'reasoning: 8' "token count normalized to decimal"

it "compact JSON is validated structurally, independent of member order"
printf '%s\n' '{"tokens":{"by_model":{"example/model":100},"total":100},"feature":"055-telemetry","schema":"prdkit.retrospective.enrich.v1"}' > "$ENRICH"
run bash "$RS" "$FID"
assert_eq 0 "$STATUS" "compact enrichment accepted"
assert_contains "$(cat "$RETRO")" 'example/model: 100' "compact model rendered"

it "enrichment errors preserve the report, including non-object token breakdowns"
printf 'sentinel\n' > "$RETRO"
for bad in 'null' '[]' '"bad"' '{"model":"10"}'; do
    printf '{"schema":"prdkit.retrospective.enrich.v1","feature":"055-telemetry","tokens":{"total":100,"by_model":%s}}\n' "$bad" > "$ENRICH"
    reject "$FID"
done
fixture
printf '{}\n' >> "$ENRICH"; reject "$FID"

it "jq is optional for ledger-only output and missing jq fails enrichment clearly"
# A PATH containing just the actual non-jq prerequisites, not a fake jq parser.
BIN="$PROJ/no-jq"
mkdir "$BIN"
for cmd in bash dirname git sed basename date awk mktemp mv rm uname; do
    ln -s "$(command -v "$cmd")" "$BIN/$cmd"
done
fixture
run env PATH="$BIN" bash "$RS" "$FID"
assert_eq 1 "$STATUS" "enrichment requires jq"
assert_contains "$OUTPUT" 'Enrichment requires jq' "actionable missing dependency error"
assert_eq sentinel "$(cat "$RETRO")" "missing dependency preserves report"
rm "$ENRICH"
run env PATH="$BIN" bash "$RS" "$FID"
assert_eq 0 "$STATUS" "ledger-only generation works without jq"

finish
