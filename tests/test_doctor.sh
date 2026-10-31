#!/usr/bin/env bash
# doctor.sh diagnoses read-only: malformed IDs and records and installation drift fail;
# budgets, citations, expired records, the inbox, raw evidence and the 0.x layout are
# advisories that --strict promotes.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJ="$(make_inited_project)"; track_tmp "$PROJ"
PROJ="$(cd "$PROJ" && pwd -P)"
DOCTOR="$PROJ/.prdkit/scripts/bash/doctor.sh"
export PRDKIT_TODAY=2026-10-17
cd "$PROJ" || exit 1

mkdir -p specs/parts specs/decisions tests
cat > specs/product.md <<'MD'
# Demo — product

- **R-01 Greet users** (validated): the user sees a greeting.
- **R-02 Old greeting** (validated): retired: replaced by R-01.
- **Q-01 Fast greeting** (hypothesis): p95 under 1 s. Enforced by: test_speed.
MD
cat > specs/architecture.md <<'MD'
# Demo — architecture

| Part | Purpose | Maturity | Owns data | Serves | Spec |
|------|---------|----------|-----------|--------|------|
| P1 Web | serves pages | validated | none | R-01 | parts/p1-web.md |
MD
cat > specs/parts/p1-web.md <<'MD'
# P1 Web

- **P1.B-01 Greeting page**: shows the greeting for R-01. Test: test_greeting.
MD
printf '# D-01 Use server rendering\n\nCited by R-01.\n' > specs/decisions/D-01.md
printf 'def test_greeting():  # proves R-01, P1.B-01\n    pass\n' > tests/test_greeting.py
git add -A >/dev/null; git commit -qm spec >/dev/null

it "a consistent 1.0 spec passes with no advisories"
run bash "$DOCTOR" --json
assert_eq 0 "$STATUS" "doctor passes"
assert_contains "$OUTPUT" '"findings":[],"advisories":[]' "nothing to report"
assert_contains "$OUTPUT" '"readiness":"not-evaluated"' "never a readiness claim"

it "malformed, duplicate and misplaced IDs are failing findings"
printf -- '- **R-1 Short id** (validated): x.\n- **R-01 Again** (validated): y.\n' >> specs/product.md
printf -- '- **P2.I-01 Wrong part**: z. Enforced by: unenforced.\n' >> specs/parts/p1-web.md
run bash "$DOCTOR"
assert_eq 1 "$STATUS" "doctor fails"
assert_contains "$OUTPUT" "Malformed ID at specs/product.md:6" "malformed ID located"
assert_contains "$OUTPUT" "Duplicate ID R-01: defined at specs/product.md:3 and specs/product.md:7" "duplicate located"
assert_contains "$OUTPUT" "P2.I-01 is defined in specs/parts/p1-web.md:4, the part file of P1" "misplaced part ID"
assert_contains "$OUTPUT" "No repairs performed" "read-only reminder"
git checkout -q -- specs

it "IDs cited by tests must exist and not be retired (advisory)"
printf 'def test_old():  # R-02 and R-09 and P1.I-07\n    pass\n' > tests/test_old.py
printf 'release notes mention R-77\n' > NOTES.txt
mkdir -p scripts; printf '# proves R-08\n' > scripts/test-ci-evidence.py
git add -A >/dev/null
run bash "$DOCTOR"
assert_eq 0 "$STATUS" "citation problems are advisories"
assert_contains "$OUTPUT" "advisory: ID R-09 is cited at tests/test_old.py:1 but defined nowhere in the spec" "undefined ID cited by a test"
assert_contains "$OUTPUT" "advisory: ID P1.I-07 is cited at tests/test_old.py:1" "undefined part ID"
assert_contains "$OUTPUT" "advisory: Retired ID R-02 is still cited by a test at tests/test_old.py:1" "retired ID cited by a test"
assert_not_contains "$OUTPUT" "R-77" "non-test files are not scanned"
assert_contains "$OUTPUT" "advisory: ID R-08 is cited at scripts/test-ci-evidence.py:1" "hyphenated test names are tests"
run bash "$DOCTOR" --strict
assert_eq 1 "$STATUS" "--strict fails on advisories"
git rm -qf tests/test_old.py scripts/test-ci-evidence.py; rm -f NOTES.txt

it "records: malformed lines fail, expired holds and waivers are advisories"
cat > specs/records.md <<'MD'
# Records

<!-- HOLD <id> owner=<name> scope=<part|env|change> since=<date> until=<date|condition> — <reason> -->
HOLD H-1 owner=alex scope=P1 since=2026-10-01 until=2026-10-05 — "hold P1" (owner, 2026-10-01)
WAIVER W-1 owner=alex check=A2 scope=007-x expires=2026-09-30 — "skip live" (owner, 2026-09-01)
HOLD H-2 owner=alex scope=P1 since=2026-10-01 until=release — "until the release" (owner)
HOLD H-5 owner=alex scope=P1 since=2026-10-01 until=2026-10-05 (owner, verbal)
DEPLOY web env=prod rev=abc123 date=2026-10-11 by=https://example.invalid/run/1
MD
run bash "$DOCTOR"
assert_eq 0 "$STATUS" "valid records pass"
assert_contains "$OUTPUT" "advisory: Expired HOLD H-1" "expired hold"
assert_contains "$OUTPUT" "advisory: Expired HOLD H-5" "a note after a date does not stop it expiring"
assert_contains "$OUTPUT" "advisory: Expired WAIVER W-1" "expired waiver"
assert_not_contains "$OUTPUT" "H-2" "a condition-based hold does not expire by date"
{
    printf 'HOLD H-3 owner=alex scope=P1\nATTEST A-1 by=agent what=x env=prod version=abc date=17.10.2026 — link\nNOTE something\n'
    printf 'ATTEST A-2 by=agent what=internal beta build env=test version=abc date=2026-10-17 — link\n'
    printf 'HOLD H-4 since now owner=alex scope=P1 since=2026-10-01 until=release — x\n'
    printf 'DEPLOY api env=test rev=none date=2026-10-17 by=agent\t— torn down\nDEPLOY api env=prod rev=none date=2026-10-17 by=agent —\n'
} >> specs/records.md
run bash "$DOCTOR"
assert_eq 1 "$STATUS" "malformed records fail"
assert_contains "$OUTPUT" "Malformed record at specs/records.md:9: HOLD H-3 is missing since= until=" "missing keys"
assert_contains "$OUTPUT" "Malformed record at specs/records.md:10: ATTEST A-1 date must be YYYY-MM-DD" "bad date"
assert_contains "$OUTPUT" "Malformed record at specs/records.md:11: not a HOLD, WAIVER, ATTEST or DEPLOY record" "unknown type"
assert_not_contains "$OUTPUT" "records.md:12" "a value with spaces is one value"
assert_contains "$OUTPUT" 'Malformed record at specs/records.md:13: HOLD H-4: "since" comes before any key=value' "a word before the first key"
assert_not_contains "$OUTPUT" "records.md:14" "a tab before the dash still starts the reason"
assert_not_contains "$OUTPUT" "records.md:15" "a dash at the end of the line is an empty reason"
rm specs/records.md

it "the owner inbox: open lines with age, lines without a disposition"
cat > specs/inbox.md <<'MD'
# Owner inbox

2026-10-01 owner "Add CSV export" → folded: 004-export
2026-10-03 agent "Library or service? Recommend library; default library" → open
2026-10-09 owner "Ship before the fair"
2026-10-02T09:00Z owner "Timestamped words" → open
Prose that is not an inbox line
2026-10-04 owner "Quick Start → Onboarding, as in the log" → open
2026-10-05 owner "Map A -> B" -> declined: out of scope
2026-10-06 owner "Rename" → folded: renamed "A" -> "B"
2026-10-07 owner "x" → declined: dup of "y" → see the log
MD
run bash "$DOCTOR"
assert_contains "$OUTPUT" "advisory: Owner inbox: 1 open item(s), oldest from 2026-10-03 (14 days)" "only unanswered agent questions count as owner input"
assert_contains "$OUTPUT" "Owner inbox: 2 item(s) awaiting agent processing" "timestamped and arrow-containing owner direction awaits incorporation"
assert_contains "$OUTPUT" "advisory: Owner inbox: 1 item(s) without an open" "missing disposition"
assert_contains "$OUTPUT" "advisory: Owner inbox: specs/inbox.md line(s) 7 are not" "an unparsed line is reported"
assert_contains "$OUTPUT" "advisory: Owner inbox: 8 item(s) in the one-line form" "one-line items are asked to move to headings"
assert_contains "$OUTPUT" "Owner inbox: 4 resolved-state item(s) retained" "legacy dispositions require reconciliation before removal"

it "the owner inbox: headed items with options, a missing meta line, prose under a section"
cat > specs/inbox.md <<'MD'
# Owner inbox

## Waiting for you

### Library or service?
*2026-10-03 · agent · open*

Export runs inside the request today.

1. **Library (Recommended)**: no new service to pay for.
2. **Managed service**: scales without our code.

**If no answer**: library.

### Rename the export?
_2026-10-02 · agent_

2026-10-01 owner "a body line that looks like a one-line item" → open

## Your direction

Prose under a section heading

### Ship before the fair
*2026-10-09 · owner · deferred: until the fair date is set · see the log*

> Ship before the fair

### A heading without its meta line
MD
run bash "$DOCTOR"
assert_contains "$OUTPUT" "advisory: Owner inbox: 1 open item(s), oldest from 2026-10-03 (14 days)" "headed open question"
assert_contains "$OUTPUT" "Owner inbox: 1 item(s) awaiting agent processing" "one-line owner direction under an item body is not lost"
assert_contains "$OUTPUT" "advisory: Owner inbox: 1 item(s) without an open" "a meta line without a disposition"
assert_contains "$OUTPUT" "line(s) 29 are not inbox items" "a heading without a meta line"
assert_not_contains "$OUTPUT" "line(s) 22" "prose in a headed inbox is ordinary text"
assert_contains "$OUTPUT" "advisory: Owner inbox: 1 item(s) in the one-line form" "only the one-line item is asked to move"
assert_contains "$OUTPUT" "Owner inbox: 1 resolved-state item(s) retained" "headed deferred item is diagnosed too"
assert_contains "$(cat specs/inbox.md)" "Ship before the fair" "doctor preserves owner words"
rm specs/inbox.md

it "budgets are advisories, never targets"
{ printf '# Demo — product\n\n- **R-01 Greet users** (validated): x.\n'; i=0; while [ "$i" -lt 160 ]; do echo "line $i"; i=$((i + 1)); done; } > specs/product.md
run bash "$DOCTOR"
assert_eq 0 "$STATUS" "an overflow does not fail doctor"
assert_contains "$OUTPUT" "advisory: Budget: specs/product.md has 163 lines, over its 150-line reading budget" "overflow reported"
git checkout -q -- specs/product.md

it "a 1.0 product.md with one-digit journey bullets still passes, with an advisory"
printf -- '\n## Users and journeys\n\n- **J-1 Greet**: a visitor is greeted.\n' >> specs/product.md
run bash "$DOCTOR"
assert_eq 0 "$STATUS" "the 1.0 template's journey bullets are not a failing finding"
assert_contains "$OUTPUT" "advisory: One-digit journey IDs at specs/product.md:9" "the Restructure is suggested"
git checkout -q -- specs/product.md

it "beside specs/product/, product.md and architecture.md are summaries with 80 and 100-line budgets"
{ i=0; while [ "$i" -lt 110 ]; do echo "line $i"; i=$((i + 1)); done; } >> specs/architecture.md
run bash "$DOCTOR"
assert_not_contains "$OUTPUT" "Budget: specs/architecture.md" "the 1.0 architecture keeps 300"
mkdir -p specs/product; printf '# Demo — non-goals\n' > specs/product/non-goals.md
{ printf '# Demo\n'; i=0; while [ "$i" -lt 84 ]; do echo "line $i"; i=$((i + 1)); done; } > specs/product.md
run bash "$DOCTOR"
assert_contains "$OUTPUT" "Budget: specs/product.md has 85 lines, over its 80-line reading budget" "the executive page budget"
assert_contains "$OUTPUT" "over its 100-line reading budget" "the architecture overview budget"
rm -rf specs/product; git checkout -q -- specs/product.md specs/architecture.md

it "the 1.1 layout: journey files, product detail files, component files"
mkdir -p specs/product/journeys specs/parts/p1-web
printf '# J-01 Get greeted (validated)\n\n**Who**: visitor\n' > specs/product/journeys/j-01-get-greeted.md
printf '# J-2 Short id (hypothesis)\n' > specs/product/journeys/j-02-bad.md
printf '# Demo — non-goals\n\n- **N-01 No accounts**: none. Why: x.\n- **N-1 Short**: y.\n' > specs/product/non-goals.md
printf '# P1 Web — rendering\n\n- **P1.B-02 Cached page**: J-01 reads from cache (D-02). Test: unenforced.\n- **P2.B-01 Elsewhere**: wrong part. Test: unenforced.\n' > specs/parts/p1-web/rendering.md
{ printf '# J-03 Long (hypothesis)\n'; i=0; while [ "$i" -lt 155 ]; do echo "step $i"; i=$((i + 1)); done; } > specs/product/journeys/j-03-long.md
mkdir -p specs/architecture
printf '# Demo — decisions\n\n## D-02 Cache pages\n\nWhy.\n\n## D-3 Short\n\n## D-04 Old cache (retired: replaced by D-02)\n' > specs/architecture/decisions.md
run bash "$DOCTOR"
assert_contains "$OUTPUT" "Malformed ID at specs/architecture/decisions.md:7" "a one-digit decision section"
assert_not_contains "$OUTPUT" "ID D-02 is cited" "a decision section defines its ID"
assert_contains "$OUTPUT" "Malformed ID at specs/product/journeys/j-02-bad.md:1" "a one-digit journey heading"
assert_contains "$OUTPUT" "Malformed ID at specs/product/non-goals.md:4" "a one-digit non-goal"
assert_contains "$OUTPUT" "P2.B-01 is defined in specs/parts/p1-web/rendering.md:4, the part file of P1" "a component file belongs to its part"
assert_contains "$OUTPUT" "Budget: specs/product/journeys/j-03-long.md has 156 lines, over its 150-line" "each journey has its own budget"
assert_not_contains "$OUTPUT" "ID J-01 is cited" "a journey heading defines its ID"
run bash "$PROJ/.prdkit/scripts/bash/status.sh"
assert_contains "$OUTPUT" "Journeys: 2 (1 hypothesis, 1 validated)" "journeys counted with their maturity"
assert_contains "$OUTPUT" "Non-goals:" "non-goals counted"
assert_contains "$OUTPUT" "Decisions: 2, 1 retired" "a decision section retired on its heading"
rm -rf specs/product specs/parts/p1-web specs/architecture

it "the lifecycle: a known current stage, known from: markers, stage columns that agree"
mkdir -p specs/product/journeys
printf '# Demo — lifecycle\n\n**Now**: Beta · **Next**: GA\n' > specs/product/lifecycle.md
printf '# J-01 Greet (hypothesis)\n' > specs/product/journeys/j-01-greet.md
printf '# J-02 Pay (hypothesis, from: ga)\n' > specs/product/journeys/j-02-pay.md
printf '# J-03 Share (hypothesis, from: alpha)\n' > specs/product/journeys/j-03-share.md
printf '# J-04 Log in (hypothesis, from: demo)\n' > specs/product/journeys/j-04-log-in.md
run bash "$DOCTOR"
assert_eq 1 "$STATUS" "an unknown stage fails"
assert_contains "$OUTPUT" "Lifecycle: specs/product/lifecycle.md needs '**Now**: <stage>'" "the current stage must be known"
assert_contains "$OUTPUT" 'advisory: Lifecycle: "from: alpha" in J-03 at specs/product/journeys/j-03-share.md:1 names no stage' "an unknown marker stage"
printf '# Demo — lifecycle\n\n**Now**: MVP (since 2026-10-01) · **Next**: Private preview\n' > specs/product/lifecycle.md
run bash "$DOCTOR"
assert_eq 0 "$STATUS" "a from: that names no stage is advisory: it may be a source note"
{ printf '# Demo — lifecycle\n\n**Now**: MVP · **Next**: GA\n'; i=0; while [ "$i" -lt 150 ]; do echo "line $i"; i=$((i + 1)); done; } > specs/product/lifecycle.md
run bash "$DOCTOR"
assert_contains "$OUTPUT" "Budget: specs/product/lifecycle.md has 153 lines, over its 150-line" "the lifecycle has a budget"
printf '# Demo — lifecycle\n\n**Now**: MVP (since 2026-10-01) · **Next**: Private preview\n' > specs/product/lifecycle.md
rm specs/product/journeys/j-03-share.md
cat > specs/product.md <<'MD'
# Demo

| Area | MVP (now) | Private preview | GA |
|------|-----------|-----------------|----|
| Use | J-01, J-04 | J-05 | J-02 |
MD
printf '# J-05 Invite (hypothesis, from: public preview)\n' > specs/product/journeys/j-05-invite.md
run bash "$DOCTOR"
assert_not_contains "$OUTPUT" "needs '**Now**" "MVP with a note is a known stage"
assert_contains "$OUTPUT" "Lifecycle: the stage is MVP, so remove the reached from: markers of J-04" "a reached marker"
assert_contains "$OUTPUT" "product.md:5 shows J-05 in the private preview column, but its file has from: public preview" "a stage column that disagrees with the file"
assert_not_contains "$OUTPUT" "shows J-02" "a GA journey in the GA column"
assert_not_contains "$OUTPUT" "shows J-01" "an unmarked journey in the current stage column"
rm -rf specs/product; git checkout -q -- specs/product.md

it "local machine paths in specs and agent context are advisories"
printf 'See /home/alex/project/notes.md.\nhttps://example.com/home/x is a URL.\nAlso C:\\Users\\alex\\notes.md.\n' >> specs/architecture.md
mkdir -p docs; printf '# Runbook\n\nClone into /Users/alex/src, or ~/src by default.\n\n> the owner said: "paths like /home/alex do not belong in docs"\n' > docs/runbook.md; git add docs/runbook.md
run bash "$DOCTOR"
assert_eq 0 "$STATUS" "an advisory"
assert_contains "$OUTPUT" "advisory: Local machine path at docs/runbook.md:3, specs/architecture.md:6, specs/architecture.md:8:" "home, Users and Windows paths in tracked docs; a URL, ~/ and a quote are not"
printf 'x\n' > zz-gone.md; git add zz-gone.md; rm zz-gone.md
run bash "$DOCTOR"
assert_contains "$OUTPUT" "advisory: Local machine path at docs/runbook.md:3" "a tracked file missing from the work tree does not hide the advisory"
git rm -q --cached zz-gone.md
git rm -q --cached docs/runbook.md; rm -rf docs; git checkout -q -- specs/architecture.md

it "a change record deleted without its log line is a failing finding"
mkdir -p specs/changes; printf '# 003-x\n' > specs/changes/003-x.md; git add specs/changes; git commit -qm open >/dev/null
git rm -q specs/changes/003-x.md; git commit -qm close >/dev/null
run bash "$DOCTOR"
assert_eq 1 "$STATUS" "doctor fails"
assert_contains "$OUTPUT" "Closed without a specs/log.md line: 003-x" "the unlogged change is named"
printf -- '- 2026-10-17 003-x: done\n' > specs/log.md
run bash "$DOCTOR"
assert_not_contains "$OUTPUT" "Closed without" "its log line clears it"
rm specs/log.md; git reset -q --hard HEAD~2

it "a renamed change record is not a closed one"
mkdir -p specs/changes; printf '# 004-y\n\nIntent: export the weekly report as a file.\n' > specs/changes/004-y.md
git add specs/changes; git commit -qm open >/dev/null
git mv specs/changes/004-y.md specs/changes/004-z.md; git commit -qm rename >/dev/null
run bash "$DOCTOR"
assert_not_contains "$OUTPUT" "Closed without" "a rename is not a deletion"
git reset -q --hard HEAD~2

it "SPEC.md beside split spec files is two competing specs, failing strict"
printf '# Demo — spec\n\n- **R-02 Export** (hypothesis): users export data.\n' > specs/SPEC.md
run bash "$DOCTOR" --strict
assert_eq 1 "$STATUS" "strict doctor fails"
assert_contains "$OUTPUT" "Two spec forms: specs/SPEC.md beside specs/product.md specs/architecture.md specs/parts/p1-web.md" "both forms named"
run bash "$PROJ/.prdkit/scripts/bash/status.sh"
assert_contains "$OUTPUT" "Two spec forms: specs/SPEC.md beside" "status warns before combining"
rm specs/SPEC.md

it "every budget has a split: links resolve, split files are reached, pieces keep budgets"
RF="$(mktemp -d)"; track_tmp "$RF"
git -C "$RF" init -q
bash "$PK_ROOT/scripts/init.sh" --target "$RF" --copy >/dev/null
mkdir -p "$RF/specs/product/requirements" "$RF/specs/product/journeys" "$RF/specs/product/non-goals" "$RF/specs/architecture/data"
cat > "$RF/specs/product.md" <<'MD'
# Demo

See [requirements](product/requirements.md "Requirements") and [gone](product/gone.md#top); `[code](product/nothere.md)`.
All [detail](product/), [site](https://example.com/x.md), [abs](/specs/architecture.md), [absbad](/specs/nope.md).
[sp](<product/gone two.md>), [pct](product/gone%20three.md), [par](product/x(1).md).
[pr](//example.com/x.md), [pad]( product/gone4.md ).
<!-- [c](comment-missing.md) -->

[^1]: Measured in a field trial.
[^2]: notes/trial.md held the raw counts.
[NOTE]: Measured too.
[r]: <README>

```
[f](fenced-missing.md)
```
MD
printf '# Demo — requirements\n\n- [Billing](requirements/billing.md)\n- Journeys: [all](journeys/)\n' > "$RF/specs/product/requirements.md"
printf '# Demo — billing\n\nBack to [the page](../../product.md).\n' > "$RF/specs/product/requirements/billing.md"
printf '# Demo — orphan\n' > "$RF/specs/product/requirements/orphan.md"
printf '# Demo — old billing (retired: now billing.md)\n' > "$RF/specs/product/requirements/old-billing.md"
printf '# J-01 Pay (hypothesis)\n' > "$RF/specs/product/journeys/j-01-pay.md"
printf '# J-02 Old pay (retired: now J-01)\n' > "$RF/specs/product/journeys/j-02-old-pay.md"
printf '# Demo — architecture\n\nData lives in one store.\n\n[data]: <architecture/data.md>\n' > "$RF/specs/architecture.md"
printf '# Demo — data\n\n[Retention](data/retention.md), [non-goals](../product/non-goals/billing.md)\n' > "$RF/specs/architecture/data.md"
printf '# Demo — notes\n' > "$RF/specs/architecture/notes.md"
{ printf '# Demo — billing non-goals\n'; i=0; while [ "$i" -lt 154 ]; do echo "line $i"; i=$((i + 1)); done; } > "$RF/specs/product/non-goals/billing.md"
{ printf '# Demo — retention\n'; i=0; while [ "$i" -lt 304 ]; do echo "line $i"; i=$((i + 1)); done; } > "$RF/specs/architecture/data/retention.md"
mkdir -p "$RF/specs/product/lifecycle" "$RF/specs/observed" "$RF/specs/decisions"
{ printf '# Demo — MVP\n'; i=0; while [ "$i" -lt 154 ]; do echo "line $i"; i=$((i + 1)); done; } > "$RF/specs/product/lifecycle/mvp.md"
{ printf '# D-01 Store\n\n[Migration](D-01-migration.md)\n'; i=0; while [ "$i" -lt 302 ]; do echo "line $i"; i=$((i + 1)); done; } > "$RF/specs/decisions/D-01.md"
printf '# Store — migration (D-01)\n' > "$RF/specs/decisions/D-01-migration.md"
printf '# Demo — observed\n\n- [Payments](observed/payments.md)\n' > "$RF/specs/observed.md"
{ printf '# Demo — users\n'; i=0; while [ "$i" -lt 154 ]; do echo "line $i"; i=$((i + 1)); done; } > "$RF/specs/product/users.md"
{ printf '# Demo — observed payments\n'; i=0; while [ "$i" -lt 154 ]; do echo "line $i"; i=$((i + 1)); done; } > "$RF/specs/observed/payments.md"
printf '# Demo — observed stores\n\n[gone](../nowhere.md)\n' > "$RF/specs/observed/stores.md"
run bash -c "cd '$RF' && bash .prdkit/scripts/bash/doctor.sh"
assert_contains "$OUTPUT" "Link at specs/product.md:3 points to specs/product/gone.md, which does not exist" "a link to a missing file"
assert_not_contains "$OUTPUT" "nothere.md" "a link in inline code is not a link"
assert_contains "$OUTPUT" "specs/product/requirements/orphan.md is reached from no summary" "a split file without a link"
assert_contains "$OUTPUT" "specs/architecture/notes.md is reached from no summary" "a topic without a link"
assert_not_contains "$OUTPUT" "billing.md is reached" "reached through a linked file"
assert_not_contains "$OUTPUT" "j-01-pay.md is reached" "reached through a folder link"
assert_not_contains "$OUTPUT" "old-billing.md is reached" "a retired file is exempt"
assert_not_contains "$OUTPUT" "data.md is reached" "reached through a reference definition"
assert_not_contains "$OUTPUT" "Link at specs/product/requirements/billing.md" "a link up through ../ resolves"
assert_contains "$OUTPUT" "Budget: specs/product/non-goals/billing.md has 155 lines, over its 150-line" "a split non-goals file keeps its budget"
assert_contains "$OUTPUT" "Budget: specs/architecture/data/retention.md has 305 lines, over its 300-line" "a split topic keeps its budget"
assert_contains "$OUTPUT" "Budget: specs/product/lifecycle/mvp.md has 155 lines, over its 150-line" "a stage file keeps its budget"
assert_contains "$OUTPUT" "Budget: specs/observed/payments.md has 155 lines, over its 150-line" "an observed piece keeps its budget"
assert_contains "$OUTPUT" "Budget: specs/decisions/D-01.md has 305 lines, over its 300-line" "a long decision keeps its budget"
assert_contains "$OUTPUT" "Budget: specs/product/users.md has 155 lines, over its 150-line" "all pains and personas have a budget"
assert_contains "$OUTPUT" "specs/observed/stores.md is not linked from specs/observed.md" "an observed piece without a link"
assert_not_contains "$OUTPUT" "payments.md is not linked" "a linked observed piece"
assert_contains "$OUTPUT" "Link at specs/observed/stores.md:3 points to specs/nowhere.md" "a broken link in an observed piece"
assert_not_contains "$OUTPUT" "points to specs/product/requirements.md" "a title after the target is dropped"
assert_not_contains "$OUTPUT" "example.com" "a URL is not a file link"
assert_not_contains "$OUTPUT" "points to specs/architecture.md" "a repository-root link resolves"
assert_contains "$OUTPUT" "Link at specs/product.md:4 points to specs/nope.md" "a broken repository-root link"
assert_contains "$OUTPUT" "points to specs/product/gone two.md, which" "a target in angle brackets keeps its spaces"
assert_contains "$OUTPUT" "points to specs/product/gone three.md, which" "%20 is a space"
assert_contains "$OUTPUT" "points to specs/product/x(1).md, which" "parentheses in a path"
assert_not_contains "$OUTPUT" "comment-missing" "a link in a comment is skipped"
assert_not_contains "$OUTPUT" "fenced-missing" "a link in a fence is skipped"
assert_not_contains "$OUTPUT" "Measured" "a footnote or a label over prose is no link"
assert_not_contains "$OUTPUT" "trial.md" "a footnote is never a link"
assert_contains "$OUTPUT" "points to specs/README, which" "a reference definition in angle brackets"
assert_not_contains "$OUTPUT" "example.com" "a protocol-relative URL is not a file link"
assert_contains "$OUTPUT" "points to specs/product/gone4.md, which" "a padded target"
assert_not_contains "$OUTPUT" "Duplicate ID D-01" "a decision piece heading cites its ID"
rm "$RF/specs/observed.md"
run bash -c "cd '$RF' && bash .prdkit/scripts/bash/doctor.sh"
assert_contains "$OUTPUT" "specs/observed/payments.md is not linked from specs/observed.md" "observed pieces without observed.md"

it "raw evidence tracked under specs/ is an advisory"
mkdir -p specs/changes/results; printf 'output\n' > specs/changes/results/run.log
git add -A >/dev/null
run bash "$DOCTOR"
assert_contains "$OUTPUT" "advisory: Raw evidence tracked under specs/: 1 file(s)" "tracked evidence surfaced"
git rm -rqf specs/changes

it "a raw archive on main is an advisory naming the fix; --strict fails it"
mkdir -p specs/archive/product-spec; printf '# Old product spec\n' > specs/archive/product-spec/product-spec.md
run bash "$DOCTOR"
assert_not_contains "$OUTPUT" "Archive on main" "an untracked folder is not on main"
git add specs/archive
run bash "$DOCTOR"
assert_eq 0 "$STATUS" "an advisory"
assert_contains "$OUTPUT" "advisory: Archive on main: specs/archive/ tracks 1 file(s); condense them into specs/archive.md and remove them from main with git rm; git keeps them (.prdkit/workflows/compact.md)" "the fix is named"
run bash "$DOCTOR" --strict
assert_eq 1 "$STATUS" "--strict fails it"
git rm -rqf specs/archive

it "specs/archive.md: its links resolve, a git path is code, its budget grows into git"
# shellcheck disable=SC2016 # backticks are Markdown code spans, not command substitution
{ printf '# Demo — archive\n\n**Base**: `abc1234`. Details: `git show abc1234:specs/features/003-x/spec.md`, `[x](gone-in-code.md)`.\n\n'
  printf 'See [the product](product.md) and [the old spec](features/003-x/spec.md).\n'
  i=0; while [ "$i" -lt 150 ]; do echo "line $i"; i=$((i + 1)); done; } > specs/archive.md
run bash "$DOCTOR"
assert_contains "$OUTPUT" "Link at specs/archive.md:5 points to specs/features/003-x/spec.md, which does not exist" "a link into a removed folder"
assert_not_contains "$OUTPUT" "points to specs/product.md" "a link to the live spec resolves"
assert_not_contains "$OUTPUT" "gone-in-code" "a git path or a link in code is no link"
assert_contains "$OUTPUT" "Budget: specs/archive.md has 155 lines, over its 150-line reading budget" "condensed past its budget"
assert_not_contains "$OUTPUT" "Archive on main" "the condensed file is no raw archive"
rm specs/archive.md

it "specs/archive.md names a base commit here and its last 0.x feature, or doctor says so"
cp .prdkit/templates/archive-template.md specs/archive.md
run bash "$DOCTOR"
assert_eq 0 "$STATUS" "an advisory"
assert_contains "$OUTPUT" "advisory: Archive: specs/archive.md has no readable **Last 0.x feature** line (a number, or none) and no **Base** commit; new-change.sh reserves the old 0.x feature numbers from them" "the unfilled template"
printf '# Demo — archive\n\n**Base**: deadbeef1, main before the cutover.\n\n**Last 0.x feature**: 012\n' > specs/archive.md
run bash "$DOCTOR"
assert_contains "$OUTPUT" "Archive: specs/archive.md has a **Base** commit that is not in this repository (deadbeef1)" "a dead base"
printf '# Demo — archive\n\n- Base: %s\n- Last 0.x feature: 012\n' "$(git rev-parse HEAD)" > specs/archive.md
run bash "$DOCTOR"
assert_not_contains "$OUTPUT" "Archive:" "a base here and a last feature, written plainly"
printf '# Demo — archive\n\n**Last 0.x feature**: none\n' > specs/archive.md
run bash "$DOCTOR"
assert_not_contains "$OUTPUT" "Archive:" "none needs no base"
rm specs/archive.md

it "agent context: only a plain repo-relative 0.x path that is missing is stale"
cat > CLAUDE.md <<'MD'
# Agents

- A feature lived in `specs/features/005-<slug>/tasks.md`; its tasks matched specs/features/00*/tasks.md.
- Old spec pieces: specs/product-spec/old-{product,architecture}.md.
- Never recreate specs/features/ or specs/archive/.
- History: `git show abc1234:specs/features/012-y/spec.md`.
- Shared rules: acme/platform:specs/product-spec/approved.md, https://example.com/acme/platform/blob/main/specs/product-spec/approved.md, acme/platform/specs/targets/t.md, team@platform:specs/targets/t.md, ourspecs/features/x.md.
- Stale: **specs/features/003-x/spec.md**.
- Imports: @specs/features/004-z/spec.md and ./specs/targets/old.md.
MD
git add CLAUDE.md
run bash "$DOCTOR"
assert_eq 0 "$STATUS" "an advisory"
assert_contains "$OUTPUT" "advisory: Agent context names removed 0.x paths (CLAUDE.md: specs/features/003-x/spec.md, CLAUDE.md: specs/features/004-z/spec.md, CLAUDE.md: specs/targets/old.md); point it at the current spec, and history questions at specs/archive.md; qualify paths in other repositories as owner/repo:path" "stale plain, ./ and @ paths; placeholders, globs, braces, bare folders, git show pointers, URLs and other repositories' paths are not"
git rm -qf CLAUDE.md

it "installation drift in kit-owned files is a failing finding"
echo "LOCAL EDIT" >> .prdkit/workflows/change.md
run bash "$DOCTOR" --json
assert_eq 1 "$STATUS" "drift fails doctor"
assert_contains "$OUTPUT" "Kit-owned content drift: .prdkit/workflows/change.md" "drift named"
if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "$OUTPUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then _ok "valid JSON"; else _no "valid JSON" "$OUTPUT"; fi
fi

it "each stage runs in an environment the environments topic lists"
EN="$(mktemp -d)"; track_tmp "$EN"
git -C "$EN" init -q
bash "$PK_ROOT/scripts/init.sh" --target "$EN" --copy >/dev/null
mkdir -p "$EN/specs/product/lifecycle" "$EN/specs/architecture/environments"
cat > "$EN/specs/architecture/environments.md" <<'MD'
# Demo — environments

<!--
| Environment | For |
|-------------|-----|
| GHOST | a comment, not an environment |
-->

| Environment | For |
|-------------|-----|
| <TEST> | <placeholder> |
| **TEST** | early access |
| [PROD](../../README.md) | everyone |

| Area | Note |
|------|------|
| STAGING | another table, not an environment |
MD
printf '# Demo — edge\n\n| Environment | For |\n|---|---|\n| EDGE (at the edge) | a note after the name |\n| _TEST_ | listed twice, in underscores |\n' > "$EN/specs/architecture/environments/edge.md"
cat > "$EN/specs/product/lifecycle.md" <<'MD'
# Demo — lifecycle

**Now**: MVP since 2026-10-01 · **Next**: Private preview

## Idea
- **Environment**: none; nothing is built.
## MVP (now)
- **Environment**: TEST, with real data.
## Private preview (next)
- **Environment**: TEST-like staging, test first, with invited users.
## Public preview
- **Environment**: the _PROD_ environment.
## GA
- **Environment**: staging.
## Sunset
- **Environment**: <placeholder>.
## Demo
- **Environment**: EDGE.
## Wrapped
- **Environment**: shared hosting at first, then
  PROD once it opens.
## Colon
**Environment:** nowhere yet.
MD
printf '# Demo — retired\n\n## Retired\n\n- **Environment**: PRODUCTION servers.\n' > "$EN/specs/product/lifecycle/retired.md"
printf '# Demo — sunset\n\n- **Environment**: elsewhere.\n' > "$EN/specs/product/lifecycle/sunset.md"
printf '  PROD, an indented first line\n# Demo — a piece\n' > "$EN/specs/product/lifecycle/a-piece.md"
printf '## Crlf\r\n- **Environment**: elsewhere.\r\n' > "$EN/specs/product/lifecycle/crlf.md"
run bash -c "cd '$EN' && bash .prdkit/scripts/bash/doctor.sh"
assert_contains "$OUTPUT" "Environments: the Private preview stage at specs/product/lifecycle.md:10 runs in none of the environments specs/architecture/environments.md lists (TEST, PROD, EDGE); name one, or add it there" "a stage naming no listed environment, as a whole word, as spelled"
assert_contains "$OUTPUT" "the GA stage at specs/product/lifecycle.md:14" "a name from another table is not an environment"
assert_contains "$OUTPUT" "the Retired stage at specs/product/lifecycle/retired.md:5" "a stage piece is checked too, by whole words"
assert_contains "$OUTPUT" "Environments: a stage at specs/product/lifecycle/sunset.md:3" "a piece without a stage heading"
assert_contains "$OUTPUT" "the Crlf stage at specs/product/lifecycle/crlf.md:2 runs" "CRLF lines"
assert_contains "$OUTPUT" "the Colon stage at specs/product/lifecycle.md:23" "the colon inside the bold, without a bullet, closed with its file"
assert_not_contains "$OUTPUT" "the MVP stage" "a listed name, written with emphasis in the table"
assert_not_contains "$OUTPUT" "the Public preview stage" "a listed name in underscore emphasis"
assert_not_contains "$OUTPUT" "the Idea stage" "none names no environment, rightly"
assert_not_contains "$OUTPUT" "the Sunset stage" "a placeholder is skipped"
assert_not_contains "$OUTPUT" "the Demo stage" "a split piece's environment, its note after the name dropped"
assert_not_contains "$OUTPUT" "the Wrapped stage" "a name on a wrapped line"
assert_not_contains "$OUTPUT" "GHOST" "a commented table lists nothing"
printf '# Demo — environments\n\n| Environment | For |\n|---|---|\n| <TEST> | <early access> |\n' > "$EN/specs/architecture/environments.md"; rm -r "$EN/specs/architecture/environments"
run bash -c "cd '$EN' && bash .prdkit/scripts/bash/doctor.sh"
assert_contains "$OUTPUT" "Environments: the | Environment | table in specs/architecture/environments.md holds only placeholders" "a copied template table"
assert_not_contains "$OUTPUT" "Environments: the M" "no stage is checked against placeholders"
printf '# Demo — environments\n\nOne server for everything.\n' > "$EN/specs/architecture/environments.md"
run bash -c "cd '$EN' && bash .prdkit/scripts/bash/doctor.sh"
assert_contains "$OUTPUT" "Environments: specs/architecture/environments.md has no table headed | Environment |" "an environments topic without its table"
assert_not_contains "$OUTPUT" "Environments: the" "no stage is checked against an empty list"
rm "$EN/specs/architecture/environments.md"
run bash -c "cd '$EN' && bash .prdkit/scripts/bash/doctor.sh"
assert_not_contains "$OUTPUT" "Environments:" "without an environments topic nothing is checked"

it "doctor never modifies the project"
assert_contains "$(tail -n 1 .prdkit/workflows/change.md)" "LOCAL EDIT" "drifted file left as found"

it "the shipped example spec passes strict doctor"
EX="$(mktemp -d)"; track_tmp "$EX"
git -C "$EX" init -q
bash "$PK_ROOT/scripts/init.sh" --target "$EX" --copy >/dev/null
cp -R "$PK_ROOT/examples/request-service/specs" "$EX/"
run bash -c "cd '$EX' && bash .prdkit/scripts/bash/doctor.sh --strict"
assert_eq 0 "$STATUS" "example has no findings or advisories"

finish
