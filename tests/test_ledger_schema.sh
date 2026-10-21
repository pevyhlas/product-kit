#!/usr/bin/env bash
#
# Ledger contract guard: the prdkit.ledger.v1 vocabulary must stay in lockstep
# across its surfaces —
#   - schemas/prdkit.ledger.v1/            (the machine-readable contract)
#   - templates/task-ledger-template.md    (the seeded consumer policy doc, which lists the
#                                           boundaries 1.0 emits at)
#   - workflows/change.md                  (points the agent at those boundaries)
# so an event can't be documented without a schema or schema'd without documentation.
# Events 1.0 no longer emits stay valid for 0.x spools and must be marked as such.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCHEMA_DIR="$PK_ROOT/schemas/prdkit.ledger.v1"
TEMPLATE="$PK_ROOT/templates/task-ledger-template.md"

# --- The authoritative event list: event|emitted (1.0 boundary) or legacy (0.x spools) ---
EVENTS="
feature.created|emitted
tasks.generated|legacy
task.state_changed|legacy
evidence.recorded|emitted
review.recorded|emitted
exploration.converged|legacy
blocker.opened|emitted
blocker.resolved|emitted
phase.changed|legacy
readiness.changed|legacy
feature.merged|emitted
"

it "Every vocabulary event has a schema file"
while IFS= read -r line; do
    [ -n "$line" ] || continue
    event="${line%%|*}"
    if [ -f "$SCHEMA_DIR/$event.schema.json" ]; then
        _ok "schema exists: $event"
    else
        _no "missing schema file: schemas/prdkit.ledger.v1/$event.schema.json"
    fi
done <<< "$EVENTS"

it "Envelope schema exists and names the envelope fields"
if [ -f "$SCHEMA_DIR/envelope.schema.json" ]; then
    _ok "envelope.schema.json exists"
    for field in schema event event_id feature actor operator ts payload; do
        if grep -q "\"$field\"" "$SCHEMA_DIR/envelope.schema.json"; then
            _ok "envelope declares '$field'"
        else
            _no "envelope schema missing field '$field'"
        fi
    done
else
    _no "missing schemas/prdkit.ledger.v1/envelope.schema.json"
fi

it "Every schema file is a vocabulary event (no orphans)"
for f in "$SCHEMA_DIR"/*.schema.json; do
    base="$(basename "$f" .schema.json)"
    [ "$base" = "envelope" ] && continue
    if printf '%s' "$EVENTS" | grep -q "^$base|"; then
        _ok "schema maps to a vocabulary event: $base"
    else
        _no "orphan schema with no vocabulary entry: $base"
    fi
done

it "Every event appears in the seeded task-ledger template"
while IFS= read -r line; do
    [ -n "$line" ] || continue
    event="${line%%|*}"
    if grep -q "$event" "$TEMPLATE"; then
        _ok "template documents: $event"
    else
        _no "templates/task-ledger-template.md does not mention: $event"
    fi
done <<< "$EVENTS"

it "1.0 events have a boundary row; legacy events are marked as not emitted"
legacy_line="$(grep -E 'stay valid for 0.x spools' "$TEMPLATE" -B2 | tr '\n' ' ')"
while IFS= read -r line; do
    [ -n "$line" ] || continue
    event="${line%%|*}"
    if [ "${line#*|}" = emitted ]; then
        if grep -qE "^\| $event( |/)" "$TEMPLATE" || grep -qE "^\| [a-z.]+ / $event " "$TEMPLATE"; then
            _ok "boundary row for $event"
        else
            _no "templates/task-ledger-template.md has no boundary row for $event"
        fi
    else
        assert_contains "$legacy_line" "$event" "legacy event marked: $event"
    fi
done <<< "$EVENTS"
assert_contains "$(cat "$PK_ROOT/workflows/change.md")" ".prdkit/memory/task-ledger.md" "change.md points at the ledger boundaries"

it "Schema files are valid JSON (when python3 is available)"
if command -v python3 >/dev/null 2>&1; then
    for f in "$SCHEMA_DIR"/*.schema.json; do
        if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$f" 2>/dev/null; then
            _ok "valid JSON: $(basename "$f")"
        else
            _no "invalid JSON: $(basename "$f")"
        fi
    done
else
    _ok "python3 not available — JSON validity check skipped (structure guards above still ran)"
fi

finish
