#!/usr/bin/env bash
# status.sh derives the owner's view from spec markers, open change records, the inbox,
# records and local git. It is read-only, answers with the longest pole, keeps merged and live
# distinct, and never reads the network.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJ="$(make_inited_project)"; track_tmp "$PROJ"
PROJ="$(cd "$PROJ" && pwd -P)"
STATUS_SH="$PROJ/.prdkit/scripts/bash/status.sh"
export PRDKIT_TODAY=2026-10-17
cd "$PROJ" || exit 1

it "an empty project says there is no spec yet"
run bash "$STATUS_SH"
assert_eq 0 "$STATUS" "status runs on a fresh install"
assert_contains "$OUTPUT" "No spec yet" "missing spec named"
assert_contains "$OUTPUT" "No open changes." "no changes"
assert_contains "$OUTPUT" "No DEPLOY records — what is live is unknown." "live state unknown, not assumed"
assert_contains "$OUTPUT" "None: no open changes, holds or owner questions." "no longest pole"

mkdir -p specs/parts specs/changes specs/product
printf '# Demo — lifecycle\n\n**Now**: MVP since 2026-10-01 · **Next**: Private preview\n' > specs/product/lifecycle.md
cat > specs/product.md <<'MD'
# Demo — product

## Requirements

- **R-01 Greet users** (validated, from: mvp): the user sees a greeting.
- **R-02 Export CSV** (hypothesis, from: ga): planned: 004-export. Users export their data.
- **R-03 Old greeting** (validated): retired: replaced by R-01.
- **R-04 Import CSV** (validated, planned: 007-import): users import their data.
- **R-05 Legacy greeting** (hypothesis, from: ga): Retired: replaced by R-01.

## Qualities

- **Q-01 Fast greeting** (hypothesis): p95 under 1 s. Enforced by: unenforced.
- **Q-02 Small pages** (hypothesis): under 100 KB per page on a slow network. Enforced by:
  unenforced.
- **Q-03 Readable pages** (hypothesis): body text at 16 px or more. Enforced by: test_pages.
- **Q-04 Quiet errors** (hypothesis): no stack traces shown to users. Enforced by: Unenforced.
MD
mkdir -p specs/decisions
printf '# D-01 Use server rendering\n\nWhy: pages work without scripts.\n' > specs/decisions/D-01.md
cat > specs/architecture.md <<'MD'
# Demo — architecture

## Parts

| Part | Purpose | Maturity | Owns data | Serves | Spec |
|------|---------|----------|-----------|--------|------|
| P1 Web | serves pages; offline planned: 009-offline | validated | none | R-01 | parts/p1-web.md |
| P2 Export | exports data | hypothesis, planned: 004-export | files | R-02 | note below |

## Data

- P1 Web keeps no data; its page cache was retired: the CDN serves pages.

## Retired

- P3 Mailer: retired: now a component of P1.
- **P3.B-01 Send receipt**: retired: now P1.B-02.
MD
cat > specs/parts/p1-web.md <<'MD'
# P1 Web

## Invariants

- **P1.I-01 No names in logs**: never logs user names. Enforced by: unenforced.
MD
cat > specs/changes/004-export.md <<'MD'
# Change: Export CSV for users

**Opened**: 2026-10-10 · **Parts**: P2 · **Tier**: T1 · **Parent**: none

## Acceptance

| Item | Proves | Check | Attempts | Result |
|------|--------|-------|----------|--------|
| A1 | R-02 | export test | 1 | PASS |
| A2 | R-02 | live export | 3 | FAIL |

## State

**Step**: building
**Waiting on**: owner: pick an export library
**Next**: write the alternatives note
MD
cat > specs/changes/005-copy.md <<'MD'
# Change: Copy edits

**Opened**: 2026-10-16 · **Parts**: P1 · **Tier**: T0 · **Parent**: none

## State

**Step**: review
**Waiting on**: nothing
**Next**: merge
MD
cat > specs/inbox.md <<'MD'
# Owner inbox

<!-- <date> <owner|agent> "<words>" → open
2020-01-01 owner "a format example, never parsed" → open -->

2026-10-01 owner "Add CSV export" → folded: 004-export
2026-10-05 agent "Managed export service or library? Recommend library; default library" → open
2026-10-06 owner "Ship before the fair"
2026-10-16T09:10Z owner "go ahead with the export" → open
Notes that are not an inbox line

## Waiting for you

### Keep the CSV header row?
*2026-10-08 · agent · open*

1. **Keep it (Recommended)**: spreadsheets read it.
2. **Drop it**: smaller files.
MD
cat > specs/records.md <<'MD'
# Records

<!-- HOLD <id> owner=<name> scope=<...> since=<date> until=<date|condition> — <reason> -->
HOLD H-1 owner=alex scope=P2 since=2026-10-01 until=2026-10-05 — "pause export" (owner, 2026-10-01)
HOLD H-2 owner=alex scope=env:TEST since=2026-10-01 until=v2 and the security review — "synthetic until v2" (owner)
WAIVER W-1 owner=alex check=A2 scope=004-export expires=2026-12-01 — "skip live" (owner, 2026-10-02)
DEPLOY web env=prod rev=HEADREV date=2026-10-11 by=https://example.invalid/run/2
DEPLOY web env=prod rev=0000000 date=2026-10-09 by=https://example.invalid/run/1
DEPLOY web env=test rev=none date=2026-10-12 by=agent — test environment torn down
MD
git add -A >/dev/null; git commit -qm spec >/dev/null
DEPLOYED="$(git rev-parse HEAD)"
sed -i.bak "s/HEADREV/$DEPLOYED/" specs/records.md && rm -f specs/records.md.bak
echo more > more.txt; git add -A >/dev/null; git commit -qm "after deploy" >/dev/null
git branch 006-stale "$DEPLOYED"; git checkout -q 006-stale; echo s > s.txt; git add s.txt; git commit -qm stale >/dev/null; git checkout -q -
# A squash merge: the default branch already has the branch's version of every file it changed.
git branch 008-squashed "$DEPLOYED"; git checkout -q 008-squashed; echo more > more.txt; git add more.txt; git commit -qm squashed >/dev/null; git checkout -q -
before="$(git status --porcelain; git show-ref; cat specs/*.md specs/changes/*.md)"

it "true now: maturity, planned, retired and unenforced items with titles"
run bash "$STATUS_SH"
assert_eq 0 "$STATUS" "status exits 0"
assert_contains "$OUTPUT" "Requirements: 3 (1 hypothesis, 2 validated), 2 retired" "requirement counts; a capitalized Retired: counts"
assert_contains "$OUTPUT" "R-04 Import CSV (planned: 007-import)" "maturity and planned share parentheses"
assert_contains "$OUTPUT" "Q-02 Small pages" "a flag on a continuation line counts"
assert_not_contains "$OUTPUT" "Q-03 Readable pages" "an enforced quality is not unenforced"
assert_contains "$OUTPUT" "Decisions: 1" "decision files counted"
assert_contains "$OUTPUT" "Parts: 2 (1 hypothesis, 1 validated), 1 retired" "parts from the architecture table and the Retired list, not from a bullet elsewhere"
assert_contains "$OUTPUT" "R-02 Export CSV (planned: 004-export)" "planned item with its change"
assert_contains "$OUTPUT" "  Stage: MVP; next: Private preview" "the current and next stage"
assert_contains "$OUTPUT" "For later stages, not needed now: R-02 (ga)" "a later-stage item; a retired one is not listed"
assert_contains "$OUTPUT" "P2 Export (planned: 004-export)" "a part is planned from its Maturity cell"
assert_not_contains "$OUTPUT" "P1 Web (planned" "planned: in another cell does not mark the part"
assert_contains "$OUTPUT" "Q-01 Fast greeting" "unenforced quality listed"
assert_contains "$OUTPUT" "Q-04 Quiet errors" "a capitalized Unenforced counts"
assert_contains "$OUTPUT" "P1.I-01 No names in logs" "unenforced invariant listed"

it "in flight: step, age, acceptance, attempts, stalls and what each waits on"
assert_contains "$OUTPUT" "004-export — Export CSV for users" "change with its title"
assert_contains "$OUTPUT" "step building, opened 7 days ago; acceptance 1/2 passed, 1 failing or blocked, up to 3 attempts" "progress line"
assert_contains "$OUTPUT" "stalled: A2" "stall budget reached"
assert_contains "$OUTPUT" "waiting on: owner: pick an export library" "waiting on"
assert_contains "$OUTPUT" "006-stale (last commit" "unmerged branch listed"
assert_contains "$OUTPUT" ", possibly squash-merged)" "squash-merged branch labelled"
assert_eq 1 "$(printf '%s\n' "$OUTPUT" | grep -c 'possibly squash-merged')" "only the squash-merged branch is labelled"

it "live: latest deploy per app and environment, and what is merged but not deployed"
assert_contains "$OUTPUT" "web prod: $DEPLOYED on 2026-10-11 (1 commit(s) on" "newest deploy wins and the gap is counted"
assert_not_contains "$OUTPUT" "0000000 on" "older deploy superseded"
assert_contains "$OUTPUT" "web test: nothing deployed since 2026-10-12" "known-empty environment"

it "holds and waivers with expiry, owner queue with age and missing dispositions"
assert_contains "$OUTPUT" "HOLD H-1 on P2 by alex, until 2026-10-05 — EXPIRED" "expired hold flagged"
assert_contains "$OUTPUT" "HOLD H-2 on env:TEST by alex, until v2 and the security review" "a condition keeps all its words"
assert_contains "$OUTPUT" "WAIVER W-1 on 004-export (check A2) by alex, until 2026-12-01" "active waiver"
assert_contains "$OUTPUT" "2026-10-05 agent, 12 days:" "open question with age"
assert_contains "$OUTPUT" "(no disposition)" "line without a disposition surfaced"
assert_not_contains "$OUTPUT" "Add CSV export" "folded line is not queued"
assert_not_contains "$OUTPUT" "format example" "comment lines are never parsed"
assert_contains "$OUTPUT" "2026-10-16 owner, 1 days: \"go ahead with the export\"" "a timestamped line is queued"
assert_contains "$OUTPUT" "2026-10-08 agent, 9 days: Keep the CSV header row?" "a headed item is queued by its title"
assert_not_contains "$OUTPUT" "Notes that are not" "an unparsed line is not queued"

it "the longest pole is the stalled item and what it waits on"
assert_contains "$OUTPUT" "004-export acceptance A2 (stalled, up to 3 attempts) — waits on owner: pick an export library" "longest pole named"
assert_contains "$OUTPUT" "Merged, live and validated are distinct" "claims kept distinct"

it "JSON carries the same derived state and parses"
run bash "$STATUS_SH" --json
assert_eq 0 "$STATUS" "json exits 0"
assert_contains "$OUTPUT" '"layout":"1.0"' "layout"
assert_contains "$OUTPUT" '"stage":{"now":"MVP","next":"Private preview","later":"R-02 (ga)"}' "the stage"
assert_contains "$OUTPUT" '"id":"R-02","title":"Export CSV","maturity":"hypothesis","planned":"004-export"' "item"
assert_contains "$OUTPUT" '"max_attempts":3,"stalled":"A2"' "acceptance summary"
assert_contains "$OUTPUT" '"commits_behind_default":"1"' "deploy gap"
assert_contains "$OUTPUT" '"env":"test","rev":"none","live":false' "known-empty environment"
assert_contains "$OUTPUT" '"id":"D-01","title":"Use server rendering","maturity":"","planned":"","retired":false,"unenforced":false,"at":"specs/decisions/D-01.md:1"' "decision row fields"
assert_contains "$OUTPUT" '"branch":"008-squashed","last_commit":' "squashed branch in JSON"
assert_contains "$OUTPUT" '"possibly_squash_merged":true' "squash flag in JSON"
assert_contains "$OUTPUT" '"longest_pole":{"item":"004-export acceptance A2' "longest pole"
assert_contains "$OUTPUT" '"readiness":"requires-evidence-review"' "never a readiness claim"
if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "$OUTPUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then _ok "valid JSON"; else _no "valid JSON" "$OUTPUT"; fi
fi

it "without stalls, the oldest waiting change is the longest pole"
sed -i.bak 's/| 3 | FAIL |/| 1 | FAIL |/' specs/changes/004-export.md && rm -f specs/changes/004-export.md.bak
run bash "$STATUS_SH"
assert_contains "$OUTPUT" "004-export — waits on owner: pick an export library" "waiting change named"
git checkout -q -- specs/changes/004-export.md

it "status is read-only"
assert_eq "$before" "$(git status --porcelain; git show-ref; cat specs/*.md specs/changes/*.md)" "no file, index or ref changes"

it "live 0.x canon beside the 1.0 spec is two canons; values with quotes stay valid JSON"
mkdir -p specs/targets/t1; : > specs/targets/t1/target.md
printf '2026-10-07 owner "say \\"hi\\" \\\\ now" → open\n' >> specs/inbox.md
run bash "$STATUS_SH"
assert_contains "$OUTPUT" "Two canons" "both layouts flagged"
run bash "$STATUS_SH" --json
if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "$OUTPUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then _ok "escaped JSON"; else _no "escaped JSON" "$OUTPUT"; fi
fi

it "the parts table's Maturity column is found by its header"
P11="$(make_inited_project)"; track_tmp "$P11"
mkdir -p "$P11/specs"
cat > "$P11/specs/architecture.md" <<'MD'
# Demo — architecture

| Part | What it is | Why it exists | Components | Owns data | Maturity | Spec |
|------|------------|---------------|------------|-----------|----------|------|
| P1 Web | pages | J-01 | render | none | validated | none yet |
| P2 Store | database | J-01 | tables | rows | hypothesis | none yet |
MD
run bash -c "cd '$P11' && bash .prdkit/scripts/bash/status.sh"
assert_contains "$OUTPUT" "Parts: 2 (1 hypothesis, 1 validated)" "maturity read from the sixth column"

it "unknown options are usage errors"
run bash "$STATUS_SH" --target T-1
assert_eq 2 "$STATUS" "0.x filters are gone"

# --- A second project: worktrees, passes on a late attempt, deploys ahead of the default branch.
P2="$(make_inited_project)"; track_tmp "$P2"
P2="$(cd "$P2" && pwd -P)"
cd "$P2" || exit 1
mkdir -p specs; printf '# Demo\n\n## Requirements\n\n- **R-01 Greet** (validated): a greeting.\n' > specs/product.md
git add -A >/dev/null; git commit -qm spec >/dev/null
MAIN_BRANCH="$(git symbolic-ref --short HEAD)"

it "an open change in a worktree shows from the main checkout, with where it lives"
run bash "$P2/.prdkit/scripts/bash/new-change.sh" --json --short-name greet "Warmer greeting"
assert_eq 0 "$STATUS" "change created in a worktree"
run bash "$P2/.prdkit/scripts/bash/status.sh"
assert_contains "$OUTPUT" "001-greet — Warmer greeting" "worktree change listed from main"
assert_contains "$OUTPUT" "in .worktrees/001-greet" "its location shown"
assert_not_contains "$OUTPUT" "No open changes." "main does not claim no open changes"
run bash "$P2/.prdkit/scripts/bash/status.sh" --json
assert_contains "$OUTPUT" '"location":".worktrees/001-greet"' "location in JSON"

it "a record in several checkouts is listed once, the change's own branch winning"
mkdir -p specs/changes
sed 's/^\*\*Step\*\*: .*/**Step**: stale copy/' .worktrees/001-greet/specs/changes/001-greet.md > specs/changes/001-greet.md
run bash "$P2/.prdkit/scripts/bash/status.sh"
assert_eq 1 "$(printf '%s\n' "$OUTPUT" | grep -c '001-greet — Warmer greeting')" "one row for the id"
assert_not_contains "$OUTPUT" "stale copy" "the worktree copy wins"
rm -f specs/changes/001-greet.md

it "a change the root's log records as closed is not open, though an older worktree carries it"
printf -- '- 2026-10-19 001-greet: warmer greeting — R-01 — #1\n' > specs/log.md
run bash "$P2/.prdkit/scripts/bash/status.sh"
assert_not_contains "$OUTPUT" "001-greet — Warmer greeting" "closed on the default branch"
rm -f specs/log.md

it "an item passed on its third attempt is not stalled"
cat > .worktrees/001-greet/specs/changes/001-greet.md <<'MD'
# Change: Warmer greeting

**Opened**: 2026-10-15 · **Parts**: P1 · **Tier**: T1 · **Parent**: none

## Acceptance

| Item | Proves | Check | Attempts | Result |
|------|--------|-------|----------|--------|
| A1 | R-01 | greeting test | 3 | PASS |
| A2 | R-01 | live greeting | 3 | NOT_APPLICABLE |
| A3 | R-01 | owner trial | 2 | BLOCKED |

## State

**Step**: review
**Waiting on**: nothing
**Next**: merge
MD
run bash "$P2/.prdkit/scripts/bash/status.sh"
assert_contains "$OUTPUT" "stalled: A3 (" "only the unpassed item is stalled"
assert_not_contains "$OUTPUT" "stalled: A1" "a late pass is not a stall"
run bash "$P2/.prdkit/scripts/bash/status.sh" --json
assert_contains "$OUTPUT" '"max_attempts":3,"stalled":"A3"' "JSON agrees"

it "a deploy ahead of the default branch never reads as matching it"
git checkout -q -b hotfix; echo fix > fix.txt; git add fix.txt; git commit -qm hotfix >/dev/null
AHEAD="$(git rev-parse HEAD)"; git checkout -q "$MAIN_BRANCH"
printf '# Records\n\nDEPLOY web env=prod rev=%s date=2026-10-16 by=agent\n' "$AHEAD" > specs/records.md
run bash "$P2/.prdkit/scripts/bash/status.sh"
assert_contains "$OUTPUT" "(1 deployed commit(s) not on $MAIN_BRANCH)" "ahead is named"
assert_not_contains "$OUTPUT" "matches $MAIN_BRANCH" "no false match"
echo more > more.txt; git add more.txt; git commit -qm more >/dev/null
run bash "$P2/.prdkit/scripts/bash/status.sh"
assert_contains "$OUTPUT" "(1 commit(s) on $MAIN_BRANCH not deployed, 1 deployed commit(s) not on $MAIN_BRANCH)" "diverged both ways"
run bash "$P2/.prdkit/scripts/bash/status.sh" --json
assert_contains "$OUTPUT" '"commits_behind_default":"1","commits_not_on_default":"1"' "JSON counts both ways"

it "status never fetches a missing object in a partial clone"
ORIGIN="$(mktemp -d)"; track_tmp "$ORIGIN"
git -C "$ORIGIN" init -q; git -C "$ORIGIN" config uploadpack.allowfilter true
cp -R "$P2/.product-kit" "$ORIGIN/"; : > "$ORIGIN/a.txt"
git -C "$ORIGIN" add -A >/dev/null; git -C "$ORIGIN" -c user.name=t -c user.email=t@e commit -qm one >/dev/null
CLONE="$(mktemp -d)"; track_tmp "$CLONE"; rmdir "$CLONE"
if git clone -q --filter=blob:none "file://$ORIGIN" "$CLONE" 2>/dev/null; then
    ( cd "$CLONE" && bash .product-kit/scripts/init.sh ) >/dev/null 2>&1
    : > "$ORIGIN/b.txt"; git -C "$ORIGIN" add b.txt; git -C "$ORIGIN" -c user.name=t -c user.email=t@e commit -qm two >/dev/null
    mkdir -p "$CLONE/specs"
    printf 'DEPLOY web env=prod rev=%s date=2026-10-16 by=agent\n' "$(git -C "$ORIGIN" rev-parse HEAD)" > "$CLONE/specs/records.md"
    objects_before="$(find "$CLONE/.git/objects" -type f | wc -l)"
    run bash -c "cd '$CLONE' && bash .prdkit/scripts/bash/status.sh"
    assert_eq "$objects_before" "$(find "$CLONE/.git/objects" -type f | wc -l)" "no object fetched"
    case "$OUTPUT" in
        *"revision not resolvable here"*|*"Git is older than 2.45"*) _ok "the missing revision stays unknown" ;;
        *) _no "the missing revision stays unknown" "$OUTPUT" ;;
    esac
    # Git without GIT_NO_LAZY_FETCH would fetch: a partial clone is spotted by its promisor remote
    # (git clone --filter sets no extensions.partialclone) and the object reads are skipped.
    FAKE="$(mktemp -d)"; track_tmp "$FAKE"
    # shellcheck disable=SC2016  # the stub's own $1 and $@, expanded when it runs
    printf '#!/bin/sh\nif [ "$1" = version ]; then echo "git version 2.39.3"; exit 0; fi\nexec "%s" "$@"\n' "$(command -v git)" > "$FAKE/git"
    chmod +x "$FAKE/git"
    printf 'DEPLOY web env=prod rev=%s date=2026-10-16 by=agent\n' "$(git -C "$CLONE" rev-parse HEAD)" > "$CLONE/specs/records.md"
    run bash -c "cd '$CLONE' && PATH='$FAKE':\"\$PATH\" bash .prdkit/scripts/bash/status.sh"
    assert_contains "$OUTPUT" "distance unknown: this partial clone's Git is older than 2.45" "older Git skips the object reads"
    assert_eq "$objects_before" "$(find "$CLONE/.git/objects" -type f | wc -l)" "still no object fetched"
else
    _ok "partial clone unavailable here; skipped"
fi

it "a squash-merged branch stays labelled after the default branch changes its files again"
SQ="$(mktemp -d)"; track_tmp "$SQ"
sq() { git -C "$SQ" -c user.name=t -c user.email=t@e "$@"; }
git -C "$SQ" init -q; git -C "$SQ" symbolic-ref HEAD refs/heads/main
cp -R "$P2/.product-kit" "$SQ/"; : > "$SQ/a.txt"; sq add -A >/dev/null; sq commit -qm one >/dev/null
( cd "$SQ" && bash .product-kit/scripts/init.sh ) >/dev/null 2>&1
sq checkout -q -b feat; echo v1 > "$SQ/x.txt"; echo y > "$SQ/y.txt"; sq add x.txt y.txt; sq commit -qm feat >/dev/null
sq checkout -q main; echo m > "$SQ/m.txt"; sq add m.txt; sq commit -qm work >/dev/null
# An open branch editing a file the default branch changes later: the scan runs and finds no match.
sq checkout -q -b edit-x; echo mine > "$SQ/x.txt"; sq add x.txt; sq commit -qm mine >/dev/null; sq checkout -q main
# GitHub's update-branch merges the default branch in; then the PR is squash-merged.
sq checkout -q feat; sq merge -q --no-edit main >/dev/null; sq checkout -q main
echo v1 > "$SQ/x.txt"; echo y > "$SQ/y.txt"; sq add x.txt y.txt; sq commit -qm "feat (#1)" >/dev/null
echo v2 > "$SQ/x.txt"; sq add x.txt; sq commit -qm later >/dev/null
sq checkout -q -b open-work; echo n > "$SQ/n.txt"; sq add n.txt; sq commit -qm open >/dev/null; sq checkout -q main
run bash -c "cd '$SQ' && bash .prdkit/scripts/bash/status.sh"
assert_contains "$OUTPUT" "feat (last commit" "the squashed branch is listed"
assert_eq 1 "$(printf '%s\n' "$OUTPUT" | grep -c 'possibly squash-merged')" "only one branch is labelled"
assert_eq 1 "$(printf '%s\n' "$OUTPUT" | grep 'feat (last commit' | grep -c 'possibly squash-merged')" "the squashed branch is labelled"
assert_contains "$OUTPUT" "edit-x (last commit" "the open branch is listed"

it "a branch whose objects a tree-filtered clone lacks is not called squash-merged"
git -C "$ORIGIN" checkout -q -b feat HEAD~1; : > "$ORIGIN/c.txt"; git -C "$ORIGIN" add c.txt
git -C "$ORIGIN" -c user.name=t -c user.email=t@e commit -qm feat >/dev/null; git -C "$ORIGIN" checkout -q -
TREE0="$(mktemp -d)"; track_tmp "$TREE0"; rmdir "$TREE0"
if git clone -q --filter=tree:0 "file://$ORIGIN" "$TREE0" 2>/dev/null; then
    ( cd "$TREE0" && bash .product-kit/scripts/init.sh ) >/dev/null 2>&1
    git -C "$TREE0" branch -q feat origin/feat
    run bash -c "cd '$TREE0' && bash .prdkit/scripts/bash/status.sh"
    assert_contains "$OUTPUT" "feat (last commit" "the branch is listed"
    assert_not_contains "$OUTPUT" "possibly squash-merged" "an unreadable diff is no squash evidence"
else
    _ok "tree-filtered clone unavailable here; skipped"
fi

finish
