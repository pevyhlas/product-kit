#!/usr/bin/env bash
# bounds.sh lists the constraints, non-goals and qualities a change must respect, from the parts
# and journeys its record names, widened through the parts table; items for a later lifecycle
# stage are listed apart.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJ="$(make_inited_project)"; track_tmp "$PROJ"
BOUNDS="$PROJ/.prdkit/scripts/bash/bounds.sh"
cd "$PROJ" || exit 1

mkdir -p specs/product specs/changes
printf '# Demo\n' > specs/product.md
cat > specs/architecture.md <<'MD'
# Demo — architecture

| Part | What it is | Why it exists | Maturity | Spec |
|------|------------|---------------|----------|------|
| P1 Phone app | an app | J-01, J-03 | hypothesis | none |
| P2 Backend | a service | J-02 | hypothesis | none |
| P3 Admin | a web page | J-05 to J-07 | hypothesis | none |
MD
printf '# Demo — lifecycle\n\n**Now**: MVP · **Next**: Private preview\n' > specs/product/lifecycle.md
cat > specs/product/constraints.md <<'MD'
# Demo — constraints

- **C-01 No raw recordings**: aggregates only.
  - Why: privacy.
  - Scope: all clients.
  - Source: owner.
- **C-02 Phone storage cap**: under 50 MB.
  - Why: old phones.
  - Scope: P1 and
    J-03 offline capture.
  - Source: owner; see P2 for the server side.
- **C-03 Server region**: EU only. Scope: P2. Why: residency, unlike P1.
- **C-04 Old rule** (retired: replaced by C-01): anything. Scope: all.
- **C-05 Sync window**: nightly only. Scope: P2,
  J-03. Why: battery.
- Data handling:
  - **C-06 Nested rule**: kept on the device. Scope: P1.
- **C-07 Shared login**: one account. Scope: anything outside P2.
- **C-08 EU hosting** (from: public preview): EU regions. Scope: all.
- **C-09 Endpoint auth**: tokens on each call. Scope: every P2 endpoint.
- **C-10 Audit log**: append only. Scope: all parts but P3.
- **C-11 Plain language**: no jargon. Scope: P2 and all journeys.
- **C-12 Signed builds**: signed. Scope: all of the P2 builds.
- **C-13 Local cache**: bounded. Scope: anything but P2.
- **C-14 Rate limits**: per client. Scope: P2 (all of it).
- **C-15 Error budget**: one per product. Scope: all of it, not only P2.
MD
cat > specs/product/non-goals.md <<'MD'
# Demo — non-goals

- **N-01 No social feed**: never. Why: focus.
- **N-02 No ads**: never.
- **N-03 No web client**: P2 serves the app only. Why: the phone is enough.
MD
cat > specs/product/qualities.md <<'MD'
# Demo — qualities

- **Q-01 Fast capture** (hypothesis): p95 under 1 s on a slow phone. Journeys: J-01.
  Enforced by: test.
- **Q-02 Exact answers** (hypothesis): no estimates. Journeys: J-02. Enforced by: P2.B-04 test.
- **Q-03 Accessible** (hypothesis): WCAG AA everywhere. Enforced by: owner review.
- **Q-04 Answer freshness** (hypothesis): under a minute. Journeys: J-02.
- **Q-05 Quick reads** (hypothesis): P95 read under 1 s over HTTP2.
- **Q-06 Plan limits** (hypothesis, from: ga): limits per plan. Journeys: J-01.
- **Q-07 Steady sync** (hypothesis): no gaps over an hour.

  Watched on the J-02 answers.
- **Q-08 Small backups** (hypothesis): under 1 GB.

Admin qualities for J-09 are pending the owner.

- **Q-10 Audit trail** (hypothesis): every admin action logged. Journeys: J-06.
- **Q-11 Admin speed** (hypothesis): pages under 2 s. Journeys: J-04–J-06.
- **Q-12 Admin export** (hypothesis): CSV for every list. Journeys: J-07 to J-05.
- **Q-13 Long journeys** (hypothesis): under 1 MB each. Journeys: J-005 to J-007.
- Operations:
  - **Q-09 Uptime band** (hypothesis): 99.5 %.

  Operations notes: J-09 waits on the owner.
MD
printf '# Change: capture\n\n**Opened**: 2026-10-19 · **Parts**: P1 · **Journeys**: J-01 · **Tier**: T1\n\n## Intent\n\nSplit from 004, whose **Parts**: P2 stay there; J-02 neither.\n' > specs/changes/005-capture.md
printf '# Change: misc\n\n**Opened**: 2026-10-19 · **Parts**: none · **Tier**: T1\n' > specs/changes/006-misc.md

it "a change gets the bounds in scope for its parts and journeys"
run bash "$BOUNDS" 005-capture
assert_eq 0 "$STATUS" "bounds exits 0"
assert_contains "$OUTPUT" "in scope: P1 J-01 J-03)" "scope read from the header only, widened by P1's row"
assert_contains "$OUTPUT" "- C-01 No raw recordings" "a constraint scoped with no ID binds everywhere"
assert_contains "$OUTPUT" "- C-02 Phone storage cap" "a constraint whose Scope names the part"
assert_not_contains "$OUTPUT" "C-03" "a one-line constraint scoped to another part (an ID after its Scope field does not count)"
assert_not_contains "$OUTPUT" "C-04" "a retired constraint"
assert_contains "$OUTPUT" "- N-01 No social feed" "every non-goal"
assert_contains "$OUTPUT" "- N-02 No ads" "every non-goal"
assert_contains "$OUTPUT" "- N-03 No web client (specs/product/non-goals.md)" "a non-goal citing another part still binds; the last item of a file names its own file"
assert_contains "$OUTPUT" "- Q-01 Fast capture" "a quality citing the journey"
assert_not_contains "$OUTPUT" "Q-02" "a quality citing only other journeys and parts"
assert_contains "$OUTPUT" "- Q-03 Accessible" "a quality citing nothing binds everywhere"
assert_contains "$OUTPUT" "- Q-05 Quick reads" "P95 and HTTP2 are not part IDs"
assert_contains "$OUTPUT" "- C-06 Nested rule" "an indented item"
assert_contains "$OUTPUT" "- C-07 Shared login" "an exception in Scope binds"
assert_not_contains "$OUTPUT" "C-09" "every with a part ID binds only that part"
assert_contains "$OUTPUT" "- C-10 Audit log" "an exception with but binds"
assert_contains "$OUTPUT" "- C-11 Plain language" "all of something unnamed binds"
assert_not_contains "$OUTPUT" "C-12" "all of the named part binds only that part"
assert_contains "$OUTPUT" "- C-13 Local cache" "an exception with but alone binds"
assert_not_contains "$OUTPUT" "C-14" "all of it refers to the named part"
assert_contains "$OUTPUT" "- C-15 Error budget" "all of it with no part before it is everything"
assert_not_contains "$OUTPUT" "Q-07" "an indented paragraph after a blank line continues the item"
assert_contains "$OUTPUT" "- Q-08 Small backups" "a paragraph at column 0 after a blank line ends the item"
assert_contains "$OUTPUT" "- Q-09 Uptime band" "a paragraph no deeper than a nested bullet ends it"

it "items for a later stage are listed apart"
assert_contains "$OUTPUT" "Stage now: MVP" "the current stage"
assert_not_contains "$(printf '%s\n' "$OUTPUT" | sed -n '/^Qualities:/,/^Later/p')" "Q-06" "a GA quality is not a bound yet"
assert_contains "$OUTPUT" "- Q-06 Plan limits (from: ga; specs/product/qualities.md)" "listed as later"
assert_contains "$OUTPUT" "- C-08 EU hosting (from: public preview;" "a constraint for a later stage"
mv specs/product/lifecycle.md lifecycle.md.off
run bash "$BOUNDS" 005-capture
assert_contains "$(printf '%s\n' "$OUTPUT" | sed -n '/^Qualities:/,$p')" "- Q-06 Plan limits" "without a current stage, everything binds now"
assert_not_contains "$OUTPUT" "Later stages" "no later list"
mv lifecycle.md.off specs/product/lifecycle.md

it "a Scope continuation line and a part behavior count"
printf '# Change: offline\n\n**Opened**: 2026-10-19 · **Journeys**: J-03 · **Tier**: T1\n' > specs/changes/007-offline.md
run bash "$BOUNDS" 007-offline
assert_contains "$OUTPUT" "- C-02 Phone storage cap" "J-03 on the Scope continuation line"
assert_contains "$OUTPUT" "- C-05 Sync window" "a wrapped one-line Scope keeps its tail"
assert_not_contains "$OUTPUT" "Q-01" "Q-01 cites another journey"
printf '# Change: server\n\n**Opened**: 2026-10-19 · **Parts**: P2 · **Tier**: T1\n' > specs/changes/008-server.md
run bash "$BOUNDS" 008-server
assert_contains "$OUTPUT" "- C-03 Server region" "a one-line Scope field"
assert_contains "$OUTPUT" "- C-09 Endpoint auth" "every with a part ID binds that part"
assert_not_contains "$OUTPUT" "C-02" "P2 outside C-02's Scope field does not count"
assert_contains "$OUTPUT" "- Q-02 Exact answers" "a part behavior cites its part"
assert_contains "$OUTPUT" "- Q-04 Answer freshness" "a named part adds the journeys its row cites"
assert_not_contains "$OUTPUT" "C-06" "a constraint for another part"
printf '# Change: answers\n\n**Opened**: 2026-10-19 · **Journeys**: J-02 · **Tier**: T1\n' > specs/changes/009-answers.md
run bash "$BOUNDS" 009-answers
assert_contains "$OUTPUT" "- C-03 Server region" "a named journey adds the parts whose rows cite it"

it "a range cites every ID in it"
printf '# Change: admin\n\n**Opened**: 2026-10-19 · **Parts**: P3 · **Tier**: T1\n' > specs/changes/010-admin.md
run bash "$BOUNDS" 010-admin
assert_contains "$OUTPUT" "in scope: P3 J-05 J-06 J-07)" "a range in a parts row widens to every journey in it"
assert_contains "$OUTPUT" "- Q-10 Audit trail" "an item citing a journey inside the row's range"
printf '# Change: audit\n\n**Opened**: 2026-10-19 · **Journeys**: J-05 · **Tier**: T1\n' > specs/changes/011-audit.md
run bash "$BOUNDS" 011-audit
assert_contains "$OUTPUT" "- Q-11 Admin speed" "an item citing a range that holds the journey"
assert_not_contains "$OUTPUT" "Q-01 " "a journey outside every range"

printf '# Change: admin pages\n\n**Opened**: 2026-10-19 · **Journeys**: J-05 to J-07, J-05 · **Tier**: T1\n' > specs/changes/012-admin-pages.md
run bash "$BOUNDS" 012-admin-pages
assert_contains "$OUTPUT" "in scope: J-05 J-06 J-07 P3)" "a range in the header, each ID once"
assert_contains "$OUTPUT" "- Q-10 Audit trail" "an item citing a journey inside the header's range"
printf '# Change: export\n\n**Opened**: 2026-10-19 · **Journeys**: J-06 · **Tier**: T1\n' > specs/changes/013-export.md
run bash "$BOUNDS" 013-export
assert_contains "$OUTPUT" "- Q-12 Admin export" "a descending range"
assert_not_contains "$OUTPUT" "Q-13" "a three-digit range keeps its digits: J-006 is not J-06"
printf '# Change: long\n\n**Opened**: 2026-10-19 · **Journeys**: J-006 · **Tier**: T1\n' > specs/changes/014-long.md
run bash "$BOUNDS" 014-long
assert_contains "$OUTPUT" "- Q-13 Long journeys" "a three-digit range"

printf '# Change: typo\n\n**Opened**: 2026-10-19 · **Parts**: P9, P2.B-04 (its P95th path) · **Journeys**: J-02 · **Tier**: T1\n' > specs/changes/015-typo.md
run bash "$BOUNDS" 015-typo
assert_contains "$OUTPUT" "Not in the parts table, so not in scope: P9" "a part the table does not define is reported"
assert_not_contains "$OUTPUT" "so not in scope: P9 P" "a part behavior cites a defined part; P95th is not an ID"
run bash "$BOUNDS" 005-capture
assert_not_contains "$OUTPUT" "Not in the parts table" "no note when every part is defined"

it "no parts or journeys, or --all, lists every live item"
run bash "$BOUNDS" 006-misc
assert_contains "$OUTPUT" "- C-03 Server region" "everything in scope"
assert_contains "$OUTPUT" "- Q-02 Exact answers" "everything in scope"
assert_not_contains "$OUTPUT" "C-04" "still no retired item"
run bash "$BOUNDS" --all
assert_contains "$OUTPUT" "- C-02 Phone storage cap" "--all"
assert_contains "$OUTPUT" "- C-06 Nested rule" "--all includes indented items"

it "a missing record is a usage error"
run bash "$BOUNDS" 099-none
assert_eq 2 "$STATUS" "exit 2"
run bash "$BOUNDS"
assert_eq 2 "$STATUS" "no argument"

finish
