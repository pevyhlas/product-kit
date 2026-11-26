#!/usr/bin/env bash
# doctor.sh diagnoses read-only: malformed IDs and records and installation drift fail;
# budgets, citations, expired records, the inbox, raw evidence and the spec layout are
# advisories that --strict promotes.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJ="$(make_inited_project)"; track_tmp "$PROJ"
PROJ="$(cd "$PROJ" && pwd -P)"
DOCTOR="$PROJ/.prdkit/scripts/bash/doctor.sh"
export PRDKIT_TODAY=2026-10-17
cd "$PROJ" || exit 1

it "a fresh installation warns about actual fill-in slots and the unconfirmed Rigor default"
run bash "$DOCTOR"
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" "advisory: Unfilled template placeholder"
assert_contains "$OUTPUT" ".prdkit/memory/constitution.md:1 (<Project>)"
assert_contains "$OUTPUT" "advisory: Unconfirmed init default (1): .prdkit/memory/constitution.md:5 (Rigor)"
run bash "$DOCTOR" --strict --json
assert_eq 1 "$STATUS"
assert_eq '[10,1]' "$(jq -c '[.trace["template-placeholder"], .trace["unconfirmed-default"]]' <<< "$OUTPUT")"
assert_eq 2 "$(jq '.findings | length' <<< "$OUTPUT")" "strict promotes both advisories"
assert_eq '[]' "$(jq -c .advisories <<< "$OUTPUT")"

it "ordinary syntax, examples and protected quotes are not fill-in slots"
fill_seeded_policy "$PROJ" || exit 1
cat >> .prdkit/memory/constitution.md <<'MD'

<!-- Example: # <Project> constitution -->
> Preserve the literal text <human who owns outcomes and consequential choices>.

Use <details> for notes, with [a label]. A typed argument can be <project>.
~~~md
- **Rigor**: light [prdkit:unconfirmed]
# <Project> constitution
~~~
MD
run bash "$DOCTOR" --strict --json
assert_eq 0 "$STATUS" "unmarked light and retained config examples are clean"
assert_eq '[0,0]' "$(jq -c '[.trace["template-placeholder"], .trace["unconfirmed-default"]]' <<< "$OUTPUT")"

it "an otherwise filled constitution warns on a marked value, not the value itself"
sed -i.bak 's/^\(- \*\*Rigor\*\*: light\)$/\1 [prdkit:unconfirmed]/' .prdkit/memory/constitution.md
run bash "$DOCTOR" --json
assert_eq 0 "$STATUS"
assert_eq '[0,1]' "$(jq -c '[.trace["template-placeholder"], .trace["unconfirmed-default"]]' <<< "$OUTPUT")"
mv .prdkit/memory/constitution.md.bak .prdkit/memory/constitution.md
run bash "$DOCTOR" --strict
assert_eq 0 "$STATUS" "removing the marker confirms the same value"

it "active config and spec fields show literal residue without needing the kit checkout"
mv .product-kit kit-away
consumer_template=.prdkit/templates/product-template.md
cp "$consumer_template" product-template.saved
printf '<Local template slot>\n' > "$consumer_template"
cp .prdkit/memory/config.md config.saved
sed '/^- context-budget-bytes:/a\
- review-publishers: bot:123, bot:<numeric account id>, user:<numeric account id>\
- review-owner: user:<numeric owner id>
' config.saved > .prdkit/memory/config.md
mkdir -p specs/changes
cat > specs/product.md <<'MD'
# Demo

\<One sentence: who struggles with what today.>

```mermaid
flowchart LR
  A([<persona>]) -->|web| J1[J-01 Review order]
```

<The thesis, and the signal that would prove it wrong.>
<The thesis, and the signal that would prove it wrong.>
<Local template slot>
MD
printf '# Change: Demo\n\n## State\n**Waiting on**: nothing\n**Next**: <next action>\n' > specs/changes/001-demo.md
run bash "$DOCTOR" --json
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq 8 "$(jq '.trace["template-placeholder"]' <<< "$OUTPUT")"
assert_contains "$OUTPUT" '.prdkit/memory/config.md:9 (<numeric account id>)'
assert_contains "$OUTPUT" 'specs/product.md:3 (<One sentence: who struggles with what today.>)'
assert_contains "$OUTPUT" 'specs/product.md:7 (<persona>)'
assert_not_contains "$OUTPUT" '(<Local template slot>)'
run bash "$DOCTOR" --strict --json
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" "Unfilled template placeholder (8)" "strict fails on slots alone"
mv kit-away .product-kit
mv product-template.saved "$consumer_template"
mv config.saved .prdkit/memory/config.md
rm specs/changes/001-demo.md specs/product.md
rmdir specs/changes

it "local anchors find each slot of a partly filled line, including split spec rows"
mkdir -p specs/architecture specs/product specs/parts
printf '# Request Service — <topic>\n' > specs/architecture/operations.md
printf '# P<n> <part name>\n' > specs/parts/draft.md
printf '# Request Service — requirements\n\n- **R-17 Display status** (hypothesis): <what must be true>.\n' > specs/product/requirements.md
run bash "$DOCTOR" --json
assert_eq 4 "$(jq '.trace["template-placeholder"]' <<< "$OUTPUT")"
assert_contains "$OUTPUT" 'specs/architecture/operations.md:1 (<topic>)'
assert_contains "$OUTPUT" 'specs/parts/draft.md:1 (<n>)'
assert_contains "$OUTPUT" 'specs/parts/draft.md:1 (<part name>)'
assert_contains "$OUTPUT" 'specs/product/requirements.md:3 (<what must be true>)'
printf '# <Product> — <topic>\n' > specs/architecture/operations.md
run bash "$DOCTOR" --json
assert_eq 5 "$(jq '.trace["template-placeholder"]' <<< "$OUTPUT")" "both unfilled heading slots count"
assert_contains "$OUTPUT" 'specs/architecture/operations.md:1 (<Product>)'
rm specs/architecture/operations.md specs/product/requirements.md specs/parts/draft.md
rmdir specs/architecture specs/product specs/parts

it "combined SPEC.md uses split slot contexts only in the corresponding sections"
cat > specs/SPEC.md <<'MD'
# Request Service — spec

## Problem and users

- **R-17 Display status** (hypothesis): <what must be true>.

## Requirements and qualities

- **R-18 Show the outcome** (hypothesis): <what must be true>.
- **Q-07 Respond promptly** (validated): <band and method>. Journeys: J-02. Enforced by: <test, metric,
  owner review or unenforced>.

## Shape and parts

```mermaid
sequenceDiagram
  P1->>P2: <request>
```

### P3 <part name>

## Constraints and non-goals

- **N-03 Skip notifications**: <what it does not do>. Why: email is out of scope. Revisit when: validated.

## Decisions and why it works

- **Mechanism**: <how the parts achieve it>
MD
run bash "$DOCTOR" --json
assert_eq 7 "$(jq '.trace["template-placeholder"]' <<< "$OUTPUT")"
assert_contains "$OUTPUT" 'specs/SPEC.md:9 (<what must be true>)'
assert_not_contains "$OUTPUT" 'specs/SPEC.md:5 (<what must be true>)'
assert_contains "$OUTPUT" 'specs/SPEC.md:10 (<test, metric, owner review or unenforced>)'
assert_contains "$OUTPUT" 'specs/SPEC.md:17 (<request>)'
assert_contains "$OUTPUT" 'specs/SPEC.md:20 (<part name>)'
rm specs/SPEC.md

it "combined requirements and qualities recognize lists and ranges without hiding stock slots"
cat > specs/SPEC.md <<'MD'
# Request Service — spec

## Journeys

- **J-01 Submit** (hypothesis): a requester sends a request.
- **J-02 Track** (hypothesis): a requester looks up the status.
- **J-03 Resolve** (hypothesis): an operator records a decision.

## Requirements and qualities

- **R-01 Show the outcome** (hypothesis): the user sees progress. Journeys: J-01,J-02. Source: <owner, date: "<words>"; observed; or the change that introduced it>.
- **Q-01 Respond promptly** (hypothesis): p95 under 1 s on a slow network. Journeys: J-01, J-02–J-03.
  Enforced by: <test, metric, owner review or unenforced>.

## Shape and parts

One service delivers J-01, J-02, J-03, R-01 and Q-01.
MD
run bash "$DOCTOR" --strict --json
assert_eq 1 "$STATUS" "$OUTPUT"
assert_eq 2 "$(jq '.trace["template-placeholder"]' <<< "$OUTPUT")"
assert_contains "$OUTPUT" 'specs/SPEC.md:11 (<owner, date:'
assert_contains "$OUTPUT" 'specs/SPEC.md:12 (<test, metric, owner review or unenforced>)'
sed -i.bak 's/Source: <.*>/Source: observed/; s/Enforced by: <.*>/Enforced by: unenforced/' specs/SPEC.md
run bash "$DOCTOR" --strict --json
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq 0 "$(jq '.trace["template-placeholder"]' <<< "$OUTPUT")"
rm specs/SPEC.md specs/SPEC.md.bak

it "other stock citation fields preserve slots beside mixed ID lists, subparts and linked lists"
mkdir -p specs/parts
cat > specs/architecture.md <<'MD'
# Request Service — architecture

| Part | What it is | Why it exists | Components | Maturity | Spec |
|------|------------|---------------|------------|----------|------|
| P2.1 Index | tracks requests | Q-01, J-01 to J-02, R-01, P2.2 | <components> | hypothesis | [p2.1-index](parts/p2.1-index.md) |
MD
cat > specs/parts/p2.1-index.md <<'MD'
# P2.1 Index

- <When a dependency fails, what this part does>. Users see: J-01, J-02, Variations.
MD
cat > specs/product.md <<'MD'
# Request Service

| Pain today | Evidence | Solved by |
|------------|----------|-----------|
| Lost updates | <assumed, desk research, observed or measured; a link> | J-01 J-02 |

| Area | Idea (now) | Demo | MVP |
|------|------------|------|-----|
| Requests | [J-01](product/journeys/j-01-submit.md), [J-02 <journey>](product/journeys/j-02-track.md), [J-03 Resolve](product/journeys/j-03-resolve.md) | [J-04 Review](product/journeys/j-04-review.md), [J-05 Reopen](product/journeys/j-05-reopen.md) | |
MD
run bash "$DOCTOR" --json
assert_eq 4 "$(jq '.trace["template-placeholder"]' <<< "$OUTPUT")" "one stock slot per row"
assert_contains "$OUTPUT" 'specs/architecture.md:5 (<components>)'
assert_contains "$OUTPUT" 'specs/parts/p2.1-index.md:3 (<When a dependency fails, what this part does>)'
assert_contains "$OUTPUT" 'specs/product.md:5 (<assumed, desk research, observed or measured; a link>)'
assert_contains "$OUTPUT" 'specs/product.md:9 (<journey>)'
rm specs/architecture.md specs/parts/p2.1-index.md specs/product.md
rmdir specs/parts

it "parts and journey-stage anchors ignore other columns and count each link, in either layout"
cat > architecture.slots <<'MD'
| Maturity | Part | Why it exists | Components | Spec |
|----------|------|---------------|------------|------|
| validated | P1 <name> | J-01 to J-08; R-01 to R-13 | <components> | none yet |
| validated | P2 Client | J-01: one owner of request state (R-01, R-02, Q-01) | <components> | none yet |
| validated | P3 Service | Unrelated free text <components> | scheduler | none yet |
MD
cat > journeys.slots <<'MD'
| Area | Idea (now) | MVP |
|------|------------|-----|
| Requests | | [J-01 <journey>](product/journeys/j-01-submit.md) |
| Requests | [J-01 <journey>](product/journeys/j-01-submit.md); [J-02 <journey>](product/journeys/j-02-track.md) | |
| Requests | [J-01 Submit](product/journeys/j-01-submit.md); [J-02 Track](product/journeys/j-02-track.md) | |

| Area | Idea (now) | MVP | GA |
|------|------------|-----|----|
| <area> | [J-01 Submit](product/journeys/j-01-submit.md) | [J-02 Track](product/journeys/j-02-track.md) | [J-03 <journey>](product/journeys/j-03-resolve.md) |

| Area | Notes |
|------|-------|
| <area> | A literal example of <journey>. |

Area | MVP
-----|----
Requests | [J-01 <journey>](product/journeys/j-01-submit.md)
MD
for layout in split combined; do
    if [ "$layout" = split ]; then
        { printf '# Request Service — architecture\n\n'; cat architecture.slots; } > specs/architecture.md
        run bash "$DOCTOR" --json
        assert_eq 3 "$(jq '.trace["template-placeholder"]' <<< "$OUTPUT")" "split: three parts slots"
        assert_contains "$OUTPUT" '(<name>)' "Part column located by name after reordering"
        assert_contains "$OUTPUT" '(<components>)' "unrelated maturity and citation text do not hide slots"
        { printf '# Request Service\n\n## Journeys\n\n'; cat journeys.slots; } > specs/product.md
    else
        {
            printf '# Request Service — spec\n\n## Shape and parts\n\n'
            cat architecture.slots
            printf '\n## Journeys\n\n'
            cat journeys.slots
        } > specs/SPEC.md
    fi
    run bash "$DOCTOR" --json
    assert_eq 9 "$(jq '.trace["template-placeholder"]' <<< "$OUTPUT")" "$layout: three parts slots, six stage slots"
    if [ "$layout" = combined ]; then
        assert_contains "$OUTPUT" '(<name>)' "$layout: Part column located by name after reordering"
        assert_contains "$OUTPUT" '(<components>)' "$layout: unrelated maturity and citation text do not hide slots"
    fi
    assert_contains "$OUTPUT" '(<journey>)' "$layout: stock token in a link caption"
    if [ "$layout" = split ]; then rm specs/architecture.md specs/product.md; else rm specs/SPEC.md; fi
done
rm architecture.slots journeys.slots

it "distinctive occurrences are counted in active prose but not in protected Markdown"
cat > specs/architecture.md <<'MD'
# Request Service — architecture

Keep <delivery, tooling> separately from <delivery, tooling> in the release plan. Ignore <path> here.

`<delivery, tooling>` and ``literal `<delivery, tooling>` with another tick`` are examples.
This span wraps `over the
next line with <delivery, tooling>` and then closes.

<!-- <delivery, tooling> -->
Prose <!-- beginning of a longer comment
<delivery, tooling>
closing --> after the comment, still <delivery, tooling>.

> <delivery, tooling> belongs to a quote.
So does <delivery, tooling> on a lazy continuation.

~~~md
<delivery, tooling>
~~~

    <delivery, tooling>
MD
run bash "$DOCTOR" --strict --json
assert_eq 1 "$STATUS" "$OUTPUT"
assert_eq 3 "$(jq '.trace["template-placeholder"]' <<< "$OUTPUT")"
assert_contains "$OUTPUT" 'specs/architecture.md:3 (<delivery, tooling>), specs/architecture.md:3 (<delivery, tooling>)'
rm specs/architecture.md

it "link destinations and XML tags are not stock slots, including inside the Components column"
cat > specs/architecture.md <<'MD'
# Request Service — architecture

[Component definitions](<components>)
The manifest stores component identifiers in the `<id>` children of <components></components>.
The manifest uses <components format="xml" example="<delivery, tooling>">.
[Further details](<delivery, tooling>)
[Workflow notes](workflow<components>(v2).md "Examples of <delivery, tooling>")

| Part | Components |
|------|------------|
| P1 Service | <components enabled="true"></components> |
| P2 Client | [Component definitions](<components>) |
MD
run bash "$DOCTOR" --json
assert_eq 0 "$(jq '.trace["template-placeholder"]' <<< "$OUTPUT")" "$OUTPUT"
rm specs/architecture.md

it "Markdown blocks keep list text and escaped ticks active after multiline inline code"
cat > specs/architecture.md <<'MD'
# Request Service — architecture

An example uses the delimiter `raw
text <!--` without opening a comment.

This line is still active: <delivery, tooling>.

<!-- A genuine multiline comment starts here.

## This heading is not active
```text
<delivery, tooling>
--> The comment ends here.

1. Inventory the part's major pieces:
    <delivery, tooling>.

       <delivery, tooling>

    ~~~text
    <delivery, tooling>
    ~~~

After the list, a literal \` leaves <delivery, tooling> active before another literal \`.
Actual code still closes at the next equal run, even after a literal backslash: `\<delivery, tooling>\`.
MD
run bash "$DOCTOR" --strict --json
assert_eq 1 "$STATUS" "$OUTPUT"
assert_eq 3 "$(jq '.trace["template-placeholder"]' <<< "$OUTPUT")"
assert_contains "$OUTPUT" 'specs/architecture.md:6 (<delivery, tooling>)'
assert_contains "$OUTPUT" 'specs/architecture.md:15 (<delivery, tooling>)'
assert_contains "$OUTPUT" 'specs/architecture.md:24 (<delivery, tooling>)'
rm specs/architecture.md

it "headings and table rows do not lend closing backticks to another block"
cat > specs/architecture.md <<'MD'
# Request Service — architecture

Literal ` in a heading
----------------------
The paragraph has <delivery, tooling> before its own literal `.

| Format | Example |
|--------|---------|
| Literal ` | First row |
| Active prompt | <delivery, tooling> and a literal ` |
MD
run bash "$DOCTOR" --json
assert_eq 2 "$(jq '.trace["template-placeholder"]' <<< "$OUTPUT")"
assert_contains "$OUTPUT" 'specs/architecture.md:5 (<delivery, tooling>)'
assert_contains "$OUTPUT" 'specs/architecture.md:10 (<delivery, tooling>)'
rm specs/architecture.md

it "stock destination anchors still match even though ordinary destinations are skipped"
cat > specs/product.md <<'MD'
# Request Service

## Journeys

| Area | Idea (now) | MVP |
|------|------------|-----|
| Requests | [J-01 <journey>](product/journeys/j-01-<slug>.md) | |
MD
run bash "$DOCTOR" --json
assert_eq 2 "$(jq '.trace["template-placeholder"]' <<< "$OUTPUT")"
assert_contains "$OUTPUT" 'specs/product.md:7 (<journey>), specs/product.md:7 (<slug>)'
rm specs/product.md

it "only stock Mermaid nodes and edges match diagram slots"
cat > specs/product.md <<'MD'
# Request Service

```mermaid
flowchart LR
  A([Requester]) -->|<surface>| J1[J-01 <journey>]
  B([Operator]) -->|<surface>| J2[J-02 Resolve]
  %% A([Requester]) -->|<surface>| J1[J-01 <journey>]
```

```text
flowchart LR
  A([Requester]) -->|<surface>| J1[J-01 <journey>]
```
MD
run bash "$DOCTOR" --json
assert_eq 2 "$(jq '.trace["template-placeholder"]' <<< "$OUTPUT")"
assert_contains "$OUTPUT" 'specs/product.md:5 (<surface>), specs/product.md:5 (<journey>)'
rm specs/product.md

it "record reasons count only when the whole field is still the stock slot"
cat > specs/records.md <<'MD'
# Records

ATTEST A-1 by=agent what=checked env=test version=abc date=2026-10-17 — copied syntax — <evidence link>
ATTEST A-2 by=agent what=checked env=test version=abc date=2026-10-17 — <evidence link>
MD
run bash "$DOCTOR" --json
assert_eq 1 "$(jq '.trace["template-placeholder"]' <<< "$OUTPUT")"
assert_contains "$OUTPUT" 'specs/records.md:4 (<evidence link>)'
rm specs/records.md

mkdir -p specs/parts specs/decisions tests .prdkit/history
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
| P1 Web | serves pages | validated | none | R-01, Q-01 | parts/p1-web.md |
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
assert_contains "$OUTPUT" '"findings":[],"advisories":[],"trace":{"code-path":0,"planned-closed":0,"planned-unknown":0,"retired-cited":0,"unallocated":0,"part-need":0,"change-restates":0,"change-undefined":0,"template-placeholder":0,"unconfirmed-default":0}' "nothing to report; each trace check counted by its code"
assert_contains "$OUTPUT" '"readiness":"not-evaluated"' "never a readiness claim"
assert_eq 0 "$(printf '%s\n' "$OUTPUT" | jq '.budget_excess_reading_lines')" "no reading-budget excess"

it "the optional design summary is a link root and has no findings when well formed"
mkdir -p specs/product
cat > specs/design.md <<'MD'
# UI design
## Direction
> Owner: "Keep the next step easy to find."
## Composition
Q-01 still holds for [the part](parts/p1-web.md).
## Copy
## Decisions
- 2026-10-16 — See [decision](decisions/D-01.md).
MD
run bash "$DOCTOR" --strict --json
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq 0 "$(jq '.advisories | length' <<< "$OUTPUT")" "design participates as a separate summary"

it "the optional design summary cannot link to tracked history"
mkdir -p .prdkit/history
printf '# Archive\n' > .prdkit/history/archive.md
printf '\n[Past direction](../.prdkit/history/archive.md)\n' >> specs/design.md
run bash "$DOCTOR" --json
assert_eq 1 "$STATUS" "a resolved history link still fails"
assert_contains "$OUTPUT" "specs/design.md:10: spec links to history (.prdkit/history/archive.md)"
rm .prdkit/history/archive.md

it "doctor checks active design headings, links, citations and the 100-reading-line budget"
cat > specs/design.md <<'MD'
# UI design
## Direction
<!--
## Composition
-->
~~~
## Copy
~~~
   ## Decisions ##
[Missing](../missing.md). J-99.
MD
# Ten source lines above, one 9,100-character line reads as 91.
printf '%09100d\n' 0 >> specs/design.md
run bash "$DOCTOR" --json
assert_eq 0 "$STATUS" "shape problems are advisories"
design_advice="$(jq -r '.advisories[]' <<< "$OUTPUT")"
assert_contains "$design_advice" "specs/design.md: missing '## Composition' heading"
assert_contains "$design_advice" "specs/design.md: missing '## Copy' heading"
assert_not_contains "$design_advice" "missing '## Decisions' heading"
assert_not_contains "$design_advice" "missing '## Direction' heading"
assert_contains "$design_advice" "Link at specs/design.md:10 points to missing.md, which does not exist"
assert_contains "$design_advice" "ID J-99 is cited at specs/design.md:10 but defined nowhere"
assert_contains "$design_advice" "Budget: specs/design.md has 11 lines that read as 101 at 100 characters a line"
assert_eq 1 "$(jq '.budget_excess_reading_lines' <<< "$OUTPUT")"
run bash "$DOCTOR" --strict
assert_eq 1 "$STATUS" "strict fails on design shape advisories"
rm specs/design.md
rmdir specs/product

it "doctor refuses old paths with one actionable finding and no partial history report"
for legacy in specs/log.md specs/log specs/archive.md; do
    ln -s missing "$legacy"
    run bash "$DOCTOR" --json
    assert_eq 1 "$STATUS"
    assert_eq 1 "$(jq '.findings | length' <<< "$OUTPUT")"
    finding="$(jq -r '.findings[0]' <<< "$OUTPUT")"
    assert_contains "$finding" 'git mv specs/log.md .prdkit/history/log.md'
    assert_contains "$finding" 'git mv specs/log .prdkit/history/log'
    assert_contains "$finding" 'git mv specs/archive.md .prdkit/history/archive.md'
    rm "$legacy"
done

it "older Git checks local history in partial clones without contacting a promisor"
partial="$(mktemp -d)" || exit 1
track_tmp "$partial"
git -C "$PROJ" config uploadpack.allowFilter true || exit 1
if git clone -q --filter=blob:none "file://$PROJ" "$partial/clone" &&
    [ "$(git -C "$partial/clone" config --bool --get remote.origin.promisor)" = true ]; then
    mkdir "$partial/bin"
    export PARTIAL_REAL_GIT PARTIAL_TRANSPORT
    PARTIAL_REAL_GIT="$(command -v git)"; PARTIAL_TRANSPORT="$partial/transport"
    cat > "$partial/bin/git" <<'SH'
#!/bin/sh
case "$1" in
    version) echo 'git version 2.39.5'; exit 0 ;;
    --git-dir=*)
        if [ "${PARTIAL_TREE_UNAVAILABLE:-}" = yes ] && [ "$2" = ls-tree ]; then
            echo 'fixture: local tree unavailable' >&2
            exit 1
        fi ;;
esac
exec "$PARTIAL_REAL_GIT" "$@"
SH
    cat > "$partial/sentinel" <<'SH'
#!/bin/sh
echo 'promisor transport attempted' >> "$PARTIAL_TRANSPORT"
exit 1
SH
    chmod +x "$partial/bin/git" "$partial/sentinel"
    git -C "$partial/clone" config remote.origin.uploadpack "$partial/sentinel"
    partial_run() {
        local script="$1"; shift
        (cd "$partial/clone" && PATH="$partial/bin:$PATH" bash ".prdkit/scripts/bash/$script" "$@")
    }
    run partial_run doctor.sh --json
    assert_eq 0 "$STATUS" "clean partial checkout still passes on older Git"
    assert_eq '{}' "$(jq '.trace | with_entries(select(.value != 0))' <<< "$OUTPUT")"
    run partial_run new-change.sh --json --no-branch --short-name partial "desc"
    assert_eq 0 "$STATUS" "local committed history is sufficient to allocate"
    assert_contains "$OUTPUT" '"CHANGE_ID":"001-partial"'
    rm -f "$partial/clone/specs/changes/001-partial.md"
    PARTIAL_TREE_UNAVAILABLE=yes run partial_run doctor.sh --json
    assert_eq 0 "$STATUS" "unavailable legacy-tree evidence is advisory"
    assert_contains "$OUTPUT" 'Legacy history layout unchecked at'
    assert_eq 0 "$(jq '.findings | length' <<< "$OUTPUT")"
    assert_eq 0 "$(jq '.trace["code-path"]' <<< "$OUTPUT")" "doctor still runs its trace checks"
    PARTIAL_TREE_UNAVAILABLE=yes run partial_run new-change.sh --json --no-branch --short-name refused "desc"
    assert_eq 1 "$STATUS" "missing committed evidence cannot free a number"
    assert_not_contains "$OUTPUT" 'CHANGE_ID'
    printf -- '- 2026-10-17 001-done: closed\n' > "$partial/clone/specs/log.md"
    git -C "$partial/clone" add specs/log.md &&
        git -C "$partial/clone" -c user.name=test -c user.email=t@example.com commit -qm 'legacy log' &&
        git -C "$partial/clone" rm -q specs/log.md || exit 1
    run partial_run doctor.sh --json
    assert_eq 1 "$STATUS" "a staged deletion cannot hide a legacy path in a local tree"
    assert_contains "$OUTPUT" 'git mv specs/log.md .prdkit/history/log.md'
    assert_not_contains "$OUTPUT" 'Legacy history layout unchecked'
    run test ! -e "$PARTIAL_TRANSPORT"
    assert_eq 0 "$STATUS" "the promisor transport was never called"
else
    _ok "blob-filtered clones unavailable; skipped"
fi

it "canon cannot cite a pending close, the folded log or the archive"
cat >> specs/product.md <<'MD'

[Close](../.prdkit/history/log/031-x.md)
[Folded log](/.prdkit/history/log.md#031-x)
[Archive]: ../.prdkit/history/archive.md
MD
run bash "$DOCTOR" --json
assert_eq 1 "$STATUS"
assert_eq 3 "$(jq '[.findings[] | select(contains("spec links to history"))] | length' <<< "$OUTPUT")"
git restore -- specs/product.md

it "doctor flags close rows over 200 characters in both live log locations"
mkdir -p .prdkit/history/log
stem='- 2026-10-17 031-x: '
intent="$(printf '%*s' "$((200 - ${#stem}))" '' | tr ' ' x)"
printf '%s%s\n' "$stem" "$intent" > .prdkit/history/log/031-x.md
run bash "$DOCTOR" --json
assert_eq 0 "$STATUS" "200 characters pass"
printf '%s%sé\n' "$stem" "$intent" > .prdkit/history/log/031-x.md
printf '# History\n\n%s%sé\n' "${stem/031-/032-}" "$intent" > .prdkit/history/log.md
run bash "$DOCTOR" --json
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" '.prdkit/history/log/031-x.md:1: close row is 201 characters, over 200'
assert_contains "$OUTPUT" '.prdkit/history/log.md:3: close row is 201 characters, over 200'
rm .prdkit/history/log/031-x.md .prdkit/history/log.md
rmdir .prdkit/history/log

it "doctor accepts a declared subpart and a task assigned to it"
mkdir -p specs/changes
sed -i.bak 's/| R-01, Q-01 |/| none |/' specs/architecture.md
rm specs/architecture.md.bak
printf '| P1.1 Index | indexes items | hypothesis | none | R-01 | parts/p1.1-index.md |\n' >> specs/architecture.md
printf '# P1.1 Index\n\n**Parent**: P1\n\n- **P1.1.B-01 Lookup**: finds an item. Test: lookup.\n' > specs/parts/p1.1-index.md
printf '# P2 Other\n' > specs/parts/p2-other.md
cat > specs/changes/001-parts.md <<'MD'
# Change: Parts
**Opened**: 2026-10-16 · **Parts**: P1.1, P9 · **Tags**: cleanup · **Tier**: T1

## Tasks
- [ ] (P1.1) Update P1.1.B-01
- [ ] (optional) Describe the change
- [ ] Update the notes

## State
**Waiting on**: nothing
**Next**: start
MD
run bash "$DOCTOR" --json
assert_eq 0 "$STATUS"
assert_eq 0 "$(jq '.trace["change-undefined"]' <<< "$OUTPUT")" "a subpart behavior is a single canonical ID"
assert_eq 1 "$(jq '.trace["part-need"]' <<< "$OUTPUT")" "only the unrelated P2 lacks an allocation"
assert_not_contains "$OUTPUT" "Part citing no journey, R or Q (1): P1 at" "the parent does not repeat the child's allocation"

it "doctor rejects malformed, unknown and out-of-scope task IDs"
cat >> specs/architecture.md <<'MD'

```md
| P9 Not a real part | example | hypothesis |
```
MD
cat >> specs/changes/001-parts.md <<'MD'

##   Tasks
- [ ] (P1.1.1) Malformed ID
- [ ] (p1.1) Malformed lowercase ID
- [ ] (P9) Unknown part, even though listed
- [ ] (P2) Known part outside scope
MD
run bash "$DOCTOR" --json
assert_eq 1 "$STATUS"
findings="$(jq -r '.findings[]' <<< "$OUTPUT")"
assert_contains "$findings" 'Malformed task part P1.1.1'
assert_contains "$findings" 'Malformed task part p1.1'
assert_contains "$findings" 'Unknown task part P9'
assert_contains "$findings" 'Task part P2 is not in the change header Parts'
rm specs/changes/001-parts.md

it "doctor rejects an unknown parent, cycles and a second level of subparts"
for parent in P9 P1.1; do
    printf '# P1.1 Index\n\n**Parent**: %s\n' "$parent" > specs/parts/p1.1-index.md
    run bash "$DOCTOR" --json
    assert_eq 1 "$STATUS"
    case "$parent" in
        P9) assert_contains "$OUTPUT" 'Unknown parent P9 for P1.1' ;;
        P1.1) assert_contains "$OUTPUT" 'Part parent cycle' ;;
    esac
done
printf '# P1.1 Index\n\n**Parent**: P2\n' > specs/parts/p1.1-index.md
printf '# P2 Other\n\n**Parent**: P1.1\n' > specs/parts/p2-other.md
run bash "$DOCTOR" --json
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'Part parent cycle'
printf '# P2 Other\n\n**Parent**: P1\n' > specs/parts/p2-other.md
run bash "$DOCTOR" --json
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'Part nesting exceeds one level'
rm specs/parts/{p1.1-index,p2-other}.md
git restore -- specs/architecture.md

it "an ordered-list code fence is not a second definition"
cat >> specs/product.md <<'MD'

1. Example:

    ```markdown
    - **R-01 Sample definition** (validated): example only.
    ```
MD
run bash "$DOCTOR" --json
assert_eq 0 "$STATUS"
assert_not_contains "$OUTPUT" 'Duplicate ID R-01'
git restore -- specs/product.md

it "literal indented tildes do not hide the real requirements below them"
awk 'NR == 3 { print "    ~~~~text\n" } { print }' specs/product.md > specs/product.tmp
mv specs/product.tmp specs/product.md
run bash "$DOCTOR" --json
assert_eq 0 "$STATUS"
assert_eq '[]' "$(jq -c '.findings' <<< "$OUTPUT")"
assert_not_contains "$OUTPUT" 'defined nowhere in the spec'
run bash .prdkit/scripts/bash/status.sh --json
assert_eq '["R-01","R-02"]' "$(jq -c '[.items[].id | select(startswith("R-"))]' <<< "$OUTPUT")"
git restore -- specs/product.md

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

it "a dangling test symlink is an advisory by default, a finding in strict mode, and does not stop other citations"
ln -s missing.py tests/test_dangling.py
printf '# verifies R-98\n' > tests/test_readable.py
git add tests/test_dangling.py tests/test_readable.py
dangling='tests/test_dangling.py: test symlink target is absent; citations not checked'
citation='ID R-98 is cited at tests/test_readable.py:1 but defined nowhere in the spec'
run bash "$DOCTOR" --json
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq '[]' "$(jq -c '.findings' <<< "$OUTPUT")"
assert_contains "$(jq -r '.advisories[]' <<< "$OUTPUT")" "$dangling"
assert_contains "$(jq -r '.advisories[]' <<< "$OUTPUT")" "$citation"
run bash "$DOCTOR" --json --strict
assert_eq 1 "$STATUS" "$OUTPUT"
assert_eq '[]' "$(jq -c '.advisories' <<< "$OUTPUT")"
assert_contains "$(jq -r '.findings[]' <<< "$OUTPUT")" "$dangling"
assert_contains "$(jq -r '.findings[]' <<< "$OUTPUT")" "$citation"
git rm -qf tests/test_dangling.py tests/test_readable.py

it "records: malformed lines fail, due hold reminders and expired waivers are advisories"
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
assert_contains "$OUTPUT" "advisory: HOLD H-1 due (owner alex, until 2026-10-05): it still applies; ask the owner to confirm or lift it" "due reminder, not a lift"
assert_contains "$OUTPUT" "advisory: HOLD H-5 due" "a note after a date does not suppress the reminder"
assert_contains "$OUTPUT" "advisory: Expired WAIVER W-1 (owner alex, until 2026-09-30): it no longer applies; the owner renews or removes it" "unchanged waiver expiry"
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

it "authority hashing preserves Unicode and nested content, normalizing only trailing LF"
AUTH_REF=.prdkit/scripts/bash/authority-ref.sh
STATUS_SH=.prdkit/scripts/bash/status.sh
printf '## H-07\n\n**Source**: owner note\n**Date**: 2026-10-01\n\n> «Échec — 雪»  \n### Detail\n> encore' > specs/authority.md
run bash "$AUTH_REF" H-07
assert_eq 0 "$STATUS"
assert_eq 'ref=specs/authority.md#H-07@6ac0061d5838' "$OUTPUT" 'golden digest, no LF at EOF'
printf '\n\n\n' >> specs/authority.md
cat >> specs/authority.md <<'MD'
## Later

```md
## H-07
```
<!--
## H-07
-->
MD
run bash "$AUTH_REF" H-07
assert_eq 0 "$STATUS"
assert_eq 'ref=specs/authority.md#H-07@6ac0061d5838' "$OUTPUT" 'next peer heading ends entry; fenced and commented anchors are not duplicates'

it "existing authority digests keep main's indented-heading behavior on the active awk"
printf '%s\n' '# Authority' '## H-01' 'Owner approval.' '  ## Other' 'Unrelated.' > specs/authority.md
# Legacy mawk matches only one space with this historical expression.
if LC_ALL=C awk 'BEGIN { h = "  ## Other"; sub(/^ ? ? ?/, "", h); exit (h !~ /^##/) }'; then
    digest=fcff486c40d9; other=c0204f9c6d62
else
    digest=c0204f9c6d62; other=fcff486c40d9
fi
run bash "$AUTH_REF" H-01
assert_eq 0 "$STATUS"
assert_eq "ref=specs/authority.md#H-01@$digest" "$OUTPUT"
for ref in "$digest" "$other"; do
    printf '# Records\nHOLD H-01 owner=owner scope=production since=2026-10-01 until=lifted — ref=specs/authority.md#H-01@%s\n' "$ref" > specs/records.md
    run bash "$DOCTOR" --json
    if [ "$ref" = "$digest" ]; then
        assert_eq 0 "$STATUS"
        assert_contains "$OUTPUT" 'HOLD H-01 on production by owner'
        assert_not_contains "$OUTPUT" 'authority digest mismatch'
    else
        assert_eq 1 "$STATUS"
        assert_contains "$OUTPUT" 'Malformed record at specs/records.md:2: authority digest mismatch'
    fi
done
rm specs/records.md

it "long quotes exceed the row budget inline, but checked references retain exact scope"
scope='production promotions for the public service only, except rollbacks approved by the incident lead; internal preview is not held'
hold_row="HOLD H-07 owner=owner scope=$scope since=2026-10-01 until=2026-10-05"
words='«Ne pas promouvoir — 東京の確認が終わるまで。»'
printf '%s — ' "$hold_row" > specs/records.md
for ((i=0; i<520; i++)); do printf '%s ' "$words"; done >> specs/records.md
printf '(owner note, 2026-10-01)\n' >> specs/records.md
run bash "$DOCTOR" --json
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" 'Move long owner quotes to specs/authority.md with a checked ref='

{
    printf '# Owner authority\n\n## H-07\n\n**Source**: owner note\n**Date**: 2026-10-01\n\n'
    for ((i=0; i<90; i++)); do printf '> %s %s %s %s %s %s\n' "$words" "$words" "$words" "$words" "$words" "$words"; done
    cat <<'MD'

## W-01
**Source**: original approval
**Date**: 2026-10-01

> Skip the freshness check for the test environment through Friday.

## W-02
**Source**: renewal approval
**Date**: 2026-10-17

> Skip the freshness check for the isolated test environment only, through the end of the month.
MD
} > specs/authority.md
hold_ref="$(bash "$AUTH_REF" H-07)" || exit 1
old_waiver="$(bash "$AUTH_REF" W-01)" || exit 1
new_waiver="$(bash "$AUTH_REF" W-02)" || exit 1
cat > specs/records.md <<MD
# Records

WAIVER W-02 owner=owner check=artifact freshness scope=isolated test only expires=2026-10-31 — $new_waiver
$hold_row — $hold_ref
WAIVER W-01 owner=owner check=artifact freshness scope=test expires=2026-10-09 — $old_waiver
MD
run bash "$DOCTOR" --json
assert_eq 0 "$STATUS"
assert_eq 0 "$(jq '.budget_excess_reading_lines' <<< "$OUTPUT")" 'protected quotes have no reading budget'
assert_contains "$OUTPUT" "HOLD H-07 on $scope by owner, until 2026-10-05"
assert_contains "$OUTPUT" 'WAIVER W-02 on isolated test only (check artifact freshness) by owner, until 2026-10-31'
assert_contains "$OUTPUT" 'Expired WAIVER W-01'
assert_not_contains "$OUTPUT" "$words" 'doctor reports the row, not the quote'

it "the hold still blocks after compaction, and the new waiver does not extend the old row"
printf '# Change log\n\n- 2026-10-16 compaction: folded changes and moved the protected quote\n' > .prdkit/history/log.md
run bash "$STATUS_SH"
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" "HOLD H-07 on $scope by owner, until 2026-10-05 — DUE, still applies"
assert_contains "$OUTPUT" "HOLD H-07 on $scope — waits on owner lifting it"
assert_not_contains "$OUTPUT" "$words" 'status reports the row, not the quote'
run bash "$STATUS_SH" --json
assert_eq 0 "$STATUS"
assert_eq "$scope" "$(jq -r '.holds[] | select(.id == "H-07") | .scope' <<< "$OUTPUT")"
assert_eq '["W-02:active","W-01:expired"]' "$(jq -c '[.holds[] | select(.type == "WAIVER") | .id + ":" + .state]' <<< "$OUTPUT")"
rm .prdkit/history/log.md

it "both readers fail at the records line for broken authority references"
printf '# Records\n\n%s — %s\n' "$hold_row" "$hold_ref" > specs/records.md
mv specs/authority.md "$PROJ/authority.saved"
for broken in missing-file missing-anchor duplicate-anchor edited bad-ref; do
    case "$broken" in
        missing-file) problem='missing authority file specs/authority.md' ;;
        missing-anchor) printf '## H-08\n> Different owner words\n' > specs/authority.md; problem='missing authority anchor' ;;
        duplicate-anchor)
            cp "$PROJ/authority.saved" specs/authority.md
            printf '\n## H-07\n> Duplicate entry\n' >> specs/authority.md
            problem='duplicate authority anchor' ;;
        edited)
            sed 's/owner note/edited source/' "$PROJ/authority.saved" > specs/authority.md
            problem='authority digest mismatch' ;;
        bad-ref) printf '# Records\n\n%s — ref=../outside.md#H-07@000000000000\n' "$hold_row" > specs/records.md; problem='invalid authority reference' ;;
    esac
    for reader in "$STATUS_SH" "$DOCTOR"; do
        run bash "$reader" --json
        assert_eq 1 "$STATUS" "$broken fails in ${reader##*/}"
        assert_contains "$OUTPUT" "Malformed record at specs/records.md:3: $problem"
    done
done
rm "$PROJ/authority.saved" specs/authority.md specs/records.md

it "HOLD and WAIVER references must follow the reason separator"
for kind in HOLD WAIVER; do
    case "$kind" in
        HOLD) row='HOLD H-09 owner=owner scope=production since=2026-10-01 until=owner confirmation'; anchor=H-09 ;;
        WAIVER) row='WAIVER W-09 owner=owner check=freshness scope=test expires=2026-10-31'; anchor=W-09 ;;
    esac
    printf '# Records\n\n%s ref=specs/authority.md#%s@000000000000\n' "$row" "$anchor" > specs/records.md
    for reader in "$STATUS_SH" "$DOCTOR"; do
        for mode in text json; do
            if [ "$mode" = json ]; then run bash "$reader" --json; else run bash "$reader"; fi
            assert_eq 1 "$STATUS" "$kind with missing separator fails in ${reader##*/} ($mode)"
            assert_contains "$OUTPUT" "Malformed record at specs/records.md:3: $kind $anchor: put ref= after the reason separator ( — )"
        done
    done
done

it "reserving ref does not change inline reasons or unrelated record fields"
cat > specs/records.md <<'MD'
HOLD H-09 owner=owner scope=production since=2026-10-01 until=owner confirmation xref=legacy — "Leave ref=legacy alone" (owner note)
WAIVER W-09 owner=owner check=freshness scope=test expires=2026-10-31 — "Also keep ref=legacy" (owner note)
ATTEST A-09 by=owner what=reviewed env=test version=abc date=2026-10-17 ref=legacy
MD
run bash "$STATUS_SH" --json
assert_eq 0 "$STATUS"
assert_eq '["\"Leave ref=legacy alone\" (owner note)","\"Also keep ref=legacy\" (owner note)"]' \
    "$(jq -c '[.holds[].reason]' <<< "$OUTPUT")"
run bash "$DOCTOR" --json
assert_eq 0 "$STATUS"
rm specs/records.md

it "one-line inbox items require the current headed format"
printf '2026-10-01 owner "Request" → open\n' > specs/inbox.md
run bash "$DOCTOR" --json
assert_eq 1 "$STATUS" "unsupported inbox fails diagnostics"
assert_contains "$OUTPUT" "headed items" "current format named"

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

## Your direction

Prose under a section heading

### Ship before the fair
*2026-10-09 · owner · deferred: until the fair date is set · see the log*

> Ship before the fair

### A heading without its meta line
MD
run bash "$DOCTOR"
assert_contains "$OUTPUT" "advisory: Owner inbox: 1 open item(s), oldest from 2026-10-03 (14 days)" "headed open question"
assert_contains "$OUTPUT" "advisory: Owner inbox: 1 item(s) without an open" "a meta line without a disposition"
assert_contains "$OUTPUT" "are not inbox items" "a heading without a meta line"
assert_not_contains "$OUTPUT" "line(s) 22" "prose in a headed inbox is ordinary text"
assert_contains "$OUTPUT" "Owner inbox: 1 resolved-state item(s) retained" "headed deferred item is diagnosed too"
assert_contains "$(cat specs/inbox.md)" "Ship before the fair" "doctor preserves owner words"
rm specs/inbox.md

it "budgets are advisories, never targets"
{ printf '# Demo — product\n\n- **R-01 Greet users** (validated): x.\n'; i=0; while [ "$i" -lt 160 ]; do echo "line $i"; i=$((i + 1)); done; } > specs/product.md
run bash "$DOCTOR"
assert_eq 0 "$STATUS" "an overflow does not fail doctor"
assert_contains "$OUTPUT" "advisory: Budget: specs/product.md has 163 lines, over its 150-line reading budget" "overflow reported"
assert_contains "$OUTPUT" "Reading lines over budget (total): 13" "text reports only the excess"
git checkout -q -- specs/product.md

it "total excess measures size independently of advisory count and ignores spare budget"
for file in specs/product.md specs/observed.md; do
    { i=0; while [ "$i" -lt 160 ]; do echo "line $i"; i=$((i + 1)); done; } > "$file"
done
run bash "$DOCTOR" --json
assert_eq 0 "$STATUS" "excess stays advisory"
assert_eq 20 "$(printf '%s\n' "$OUTPUT" | jq '.budget_excess_reading_lines')" "two ten-line excesses sum; under-budget files do not offset them"
assert_eq 2 "$(printf '%s\n' "$OUTPUT" | jq '[.advisories[] | select(startswith("Budget:"))] | length')" "two budget advisories"
git checkout -q -- specs/product.md
{ i=0; while [ "$i" -lt 181 ]; do echo "line $i"; i=$((i + 1)); done; } > specs/observed.md
run bash "$DOCTOR" --json
assert_eq 31 "$(printf '%s\n' "$OUTPUT" | jq '.budget_excess_reading_lines')" "excess rises even when advisory count falls"
assert_eq 1 "$(printf '%s\n' "$OUTPUT" | jq '[.advisories[] | select(startswith("Budget:"))] | length')" "one budget advisory remains"
run bash "$DOCTOR" --json --strict
assert_eq 1 "$STATUS" "strict promotes the budget advisory"
assert_eq 31 "$(printf '%s\n' "$OUTPUT" | jq '.budget_excess_reading_lines')" "strict preserves the size metric"
assert_eq 0 "$(printf '%s\n' "$OUTPUT" | jq '.advisories | length')" "strict retains its existing empty-advisories contract"
rm specs/observed.md

it "a line counts once per 100 characters, so long rows cannot dodge a budget"
long="$(printf '%0400d' 0)"; dashes="$(i=0; while [ "$i" -lt 100 ]; do printf '—'; i=$((i + 1)); done)"
{ printf '# Demo — product\n\n'; i=0; while [ "$i" -lt 40 ]; do echo "| R-x | $long |"; i=$((i + 1)); done; } > specs/product.md
run bash "$DOCTOR"
assert_eq 0 "$STATUS" "still an advisory"
assert_contains "$OUTPUT" "advisory: Budget: specs/product.md has 42 lines that read as 202 at 100 characters a line, over its 150-line reading budget" "40 rows of 400 characters read as 200 lines"
run bash "$DOCTOR" --json
assert_eq 52 "$(printf '%s\n' "$OUTPUT" | jq '.budget_excess_reading_lines')" "long-row excess uses reading lines, not physical lines"
{ printf '# Demo — product\n'; i=0; while [ "$i" -lt 149 ]; do echo "$dashes"; i=$((i + 1)); done; } > specs/product.md
run bash "$DOCTOR"
assert_not_contains "$OUTPUT" "Budget: specs/product.md" "a character is counted once, however many bytes it takes"
run bash "$DOCTOR" --json
assert_eq 0 "$(printf '%s\n' "$OUTPUT" | jq '.budget_excess_reading_lines')" "UTF-8 characters do not inflate excess; exactly at budget is zero"
git checkout -q -- specs/product.md

it "compaction counts pending entry files without log.md, at the ten-close boundary"
mkdir -p .prdkit/history/log
i=1; while [ "$i" -le 9 ]; do
    printf -- '- 2026-10-17 %03d-c: done\n' "$((i + 100))" > ".prdkit/history/log/$((i + 100))-c.md"
    i=$((i + 1))
done
run bash "$DOCTOR" --json
assert_eq 0 "$STATUS" "nine valid entry files pass: $OUTPUT"
assert_not_contains "$OUTPUT" "Compaction due" "nine closes are current"
printf -- '- 2026-10-17 110-c: done\n' > .prdkit/history/log/110-c.md
run bash "$DOCTOR"
assert_eq 0 "$STATUS" "compaction due is advisory"
assert_contains "$OUTPUT" "advisory: Compaction due: 10 changes closed and no pass recorded in .prdkit/history/log.md" "pending files alone make compaction due"
run bash "$DOCTOR" --json --strict
assert_eq 1 "$STATUS" "strict fails overdue compaction"
assert_eq 1 "$(printf '%s\n' "$OUTPUT" | jq '[.findings[] | select(startswith("Compaction due:"))] | length')" "strict promotes the compaction advisory"
rm .prdkit/history/log/110-c.md
# A symlink is not an entry, even when its target has a valid close line.
printf -- '- 2026-10-17 110-c: done\n' > pending-close.txt
ln -s ../../pending-close.txt .prdkit/history/log/110-c.md
run bash "$DOCTOR" --json
assert_not_contains "$OUTPUT" "Compaction due" "a symlink does not add a close"
rm .prdkit/history/log/110-c.md pending-close.txt
rm .prdkit/history/log/*.md; rmdir .prdkit/history/log

it "compaction shares status's mixed-log accounting in both log orders"
for order in newest oldest; do
    {
        printf '# Closed changes\n\n'
        if [ "$order" = newest ]; then
            printf -- '- 2026-10-17 101-c: new\n- 2026-10-17 compaction: latest\n- 2026-10-16 100-c: old\n- 2026-10-15 compaction: earlier\n'
        else
            printf -- '- 2026-10-15 compaction: earlier\n- 2026-10-16 100-c: old\n- 2026-10-17 compaction: latest\n- 2026-10-17 101-c: new\n'
        fi
    } > .prdkit/history/log.md
    mkdir -p .prdkit/history/log
    i=102; while [ "$i" -le 109 ]; do
        printf -- '- 2026-10-17 %03d-c: pending\n' "$i" > ".prdkit/history/log/$i-c.md"; i=$((i + 1))
    done
    run bash "$DOCTOR" --json
    assert_not_contains "$OUTPUT" "Compaction due" "$order: one new folded entry plus eight pending is current"
    printf -- '- 2026-10-17 110-c: pending\n' > .prdkit/history/log/110-c.md
    run bash "$DOCTOR" --json
    assert_eq 0 "$STATUS" "$order: compaction due stays advisory"
    assert_contains "$OUTPUT" "Compaction due: 10 changes closed since the last pass (2026-10-17)" "$order: only entries since the latest pass plus pending files count"
    assert_eq 1 "$(printf '%s\n' "$OUTPUT" | jq '[.advisories[] | select(startswith("Compaction due:"))] | length')" "$order: exactly one overdue advisory"
    run bash "$PROJ/.prdkit/scripts/bash/status.sh" --json
    assert_contains "$OUTPUT" '"compaction":{"closed_since_last":10,"last":"2026-10-17","due":true}' "$order: status and doctor agree"
    rm .prdkit/history/log/*.md; rmdir .prdkit/history/log
    run bash "$DOCTOR" --json
    assert_not_contains "$OUTPUT" "Compaction due" "$order: folded history before the latest pass does not make compaction overdue"
done
rm .prdkit/history/log.md

it "the log, inbox and records have budgets, each with its way out"
{ i=0; while [ "$i" -lt 151 ]; do printf -- '- 2026-10-17 %03d-c: done — R-01 — #%d\n' "$((i + 100))" "$i"; i=$((i + 1)); done; } > .prdkit/history/log.md
run bash "$DOCTOR"
assert_contains "$OUTPUT" "advisory: Budget: .prdkit/history/log.md has 151 lines, over its 150-line reading budget; condense its older entries into .prdkit/history/archive.md" "the log condenses into the archive"
rm .prdkit/history/log.md
{ printf '# Owner inbox\n\n<!--\n'; i=0; while [ "$i" -lt 150 ]; do echo "note $i"; i=$((i + 1)); done; printf -- '-->\n\n## Waiting for you\n'; } > specs/inbox.md
printf 'DEPLOY web env=test rev=abc1234 date=2026-10-17 by=https://example.invalid/run/1 — %s\n' "$(printf '%016000d' 0)" > specs/records.md
run bash "$DOCTOR"
assert_eq 0 "$STATUS" "budgets stay advisories"
assert_contains "$OUTPUT" "advisory: Budget: specs/inbox.md has 156 lines, over its 150-line reading budget; incorporate answered items" "the inbox drains"
assert_contains "$OUTPUT" "advisory: Budget: specs/records.md has 1 line that reads as 161 at 100 characters a line, over its 150-line reading budget; remove lifted holds, expired waivers" "superseded records leave"
rm specs/inbox.md specs/records.md

it "one-digit journey IDs are rejected"
printf -- '\n## Users and journeys\n\n- **J-1 Greet**: a visitor is greeted.\n' >> specs/product.md
run bash "$DOCTOR"
assert_eq 1 "$STATUS" "unsupported ID fails"
assert_contains "$OUTPUT" "with two or more digits" "current ID format named"
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

it "the optional paid preview stage sits between public preview and GA"
mkdir -p specs/product/journeys
printf '# Demo — lifecycle\n\n**Now**: Public preview since 2026-11-01 · **Next**: Paid Preview\n' > specs/product/lifecycle.md
printf '# J-01 Join (hypothesis, from: public preview)\n' > specs/product/journeys/j-01-join.md
printf '# J-02 Pay (hypothesis, from: Paid  Preview)\n' > specs/product/journeys/j-02-pay.md
printf '# J-03 Scale (hypothesis, from: ga)\n' > specs/product/journeys/j-03-scale.md
cat > specs/product.md <<'MD'
# Demo

| Area | Public preview (now) | Paid preview | GA |
|------|----------------------|--------------|----|
| Use | J-01 | J-02, J-03 | |
MD
run bash "$DOCTOR"
assert_not_contains "$OUTPUT" "names no stage" "from: paid preview names a stage, in any case and spacing"
assert_contains "$OUTPUT" "Lifecycle: the stage is Public preview, so remove the reached from: markers of J-01" "public preview is reached"
assert_not_contains "$OUTPUT" "J-01, J-02" "paid preview comes after public preview"
assert_not_contains "$OUTPUT" "shows J-02" "a paid preview journey in its column"
assert_contains "$OUTPUT" "product.md:5 shows J-03 in the paid preview column, but its file has from: ga" "GA comes after paid preview"
run bash "$PROJ/.prdkit/scripts/bash/status.sh"
assert_contains "$OUTPUT" "Stage: Public preview; next: Paid Preview" "the next stage keeps both words"
assert_contains "$OUTPUT" "For later stages, not needed now: J-02 (paid preview), J-03 (ga)" "both are later stages"
printf '# Demo — lifecycle\n\n**Now**: Paid preview · **Next**: GA\n' > specs/product/lifecycle.md
run bash "$DOCTOR"
assert_not_contains "$OUTPUT" "needs '**Now**" "paid preview is a known current stage"
assert_contains "$OUTPUT" "Lifecycle: the stage is Paid preview, so remove the reached from: markers of J-01, J-02" "public and paid preview are reached"
assert_not_contains "$OUTPUT" "J-02, J-03" "GA is not reached"
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
assert_contains "$OUTPUT" "Closed without a log entry: 003-x" "the unlogged change is named"
printf -- '- 2026-10-17 003-x: done\n' > .prdkit/history/log.md
run bash "$DOCTOR"
assert_not_contains "$OUTPUT" "Closed without" "its log line clears it"
rm .prdkit/history/log.md
mkdir -p .prdkit/history/log; printf -- '- 2026-10-17 003-x: done\n' > .prdkit/history/log/003-x.md
run bash "$DOCTOR"
assert_eq 0 "$STATUS" "an entry file is a log entry: $OUTPUT"
assert_not_contains "$OUTPUT" "Closed without" "its entry file clears it"
assert_not_contains "$OUTPUT" "Malformed log entry" "a well-formed entry file is quiet"
for bad in '- 2026-10-17 004-y: names another change' '- 2026-10-17 003-x: done
- 2026-10-17 003-x: twice' 'done, no date' '- 2026-10-17 003-x: '; do
    printf '%s\n' "$bad" > .prdkit/history/log/003-x.md
    run bash "$DOCTOR"
    assert_eq 1 "$STATUS" "a malformed entry fails doctor: $bad"
    assert_contains "$OUTPUT" "Malformed log entry .prdkit/history/log/003-x.md" "names the file: $bad"
done
printf -- '- 2026-10-17 003-x: done\n' > .prdkit/history/log/003-x.md; printf 'x\n' > .prdkit/history/log/notes.txt
run bash "$DOCTOR"
assert_contains "$OUTPUT" "Malformed log entry .prdkit/history/log/notes.txt" "only change entries belong in .prdkit/history/log/"
rm .prdkit/history/log/notes.txt; printf 'x\n' > .prdkit/history/log/.notes
run bash "$DOCTOR"
assert_contains "$OUTPUT" "Malformed log entry .prdkit/history/log/.notes" "a hidden file is seen too"
rm .prdkit/history/log/.notes; mv .prdkit/history/log/003-x.md .prdkit/history/log.entry; ln -s ../log.entry .prdkit/history/log/003-x.md
run bash "$DOCTOR"
assert_contains "$OUTPUT" "Malformed log entry .prdkit/history/log/003-x.md" "a symlink is no entry"
assert_contains "$OUTPUT" "Closed without a log entry: 003-x" "and closes nothing"
rm .prdkit/history/log/003-x.md .prdkit/history/log.entry; ln -s missing.md .prdkit/history/log/003-x.md
run bash "$DOCTOR"
assert_contains "$OUTPUT" "Malformed log entry .prdkit/history/log/003-x.md" "a dangling symlink is seen too"
rm -rf .prdkit/history/log
# shellcheck disable=SC2016 # backticks are Markdown code spans, not command substitution
printf '# Demo — archive\n\n**Log condensed through**: 003; those entries: `git show abc1234:.prdkit/history/log.md`.\n' > .prdkit/history/archive.md
run bash "$DOCTOR"
assert_not_contains "$OUTPUT" "Closed without" "a log condensed into the archive keeps it closed"
# shellcheck disable=SC2016 # backticks are Markdown code spans, not command substitution
for value in '002 — entries at `git show 9f81234:.prdkit/history/log.md`' '002 as of 2026-10-30' 'through 9'; do
    printf '# Demo — archive\n\n**Log condensed through**: %s\n' "$value" > .prdkit/history/archive.md
    run bash "$DOCTOR"
    assert_contains "$OUTPUT" "Closed without a log entry: 003-x" "only a leading number counts: $value"
done
rm .prdkit/history/archive.md; git reset -q --hard HEAD~2

it "legacy cutoff-only archives accept CRLF, no final LF, and trailing pointer prose"
kit_bin="$PROJ/.prdkit/scripts/bash"
mkdir -p specs/changes
printf '# Open\n\n## State\n\nWaiting on: nothing\nNext: continue\n' > specs/changes/007-open.md
# shellcheck disable=SC2016 # Markdown code span
cutoff_line='**Log condensed through**: 005; those entries: `git show abc1234:.prdkit/history/log.md`.'
legacy_capture() (
    bash "$kit_bin/status.sh" --json &&
        bash "$kit_bin/bounds.sh" 007-open
)
printf '%s\n' "$cutoff_line" > .prdkit/history/archive.md
run legacy_capture
assert_eq 0 "$STATUS" 'canonical cutoff-only fixture'
cutoff_output="$OUTPUT"
run bash "$DOCTOR" --json
assert_eq 0 "$STATUS" 'doctor accepts canonical cutoff-only text'
cutoff_doctor="$OUTPUT"
for encoding in crlf unterminated prose; do
    case "$encoding" in
        crlf) printf '%s\r\n' "$cutoff_line" ;;
        unterminated) printf '%s' "$cutoff_line" ;;
        prose) printf '%s; also see the migration notes\n' "${cutoff_line%.}" ;;
    esac > .prdkit/history/archive.md
    run legacy_capture
    assert_eq 0 "$STATUS" "$encoding: status and bounds succeed"
    assert_eq "$cutoff_output" "$OUTPUT" "$encoding: output is unchanged"
    run bash "$DOCTOR" --json
    if [ "$encoding" = prose ]; then
        assert_eq 0 "$STATUS" 'doctor accepts pointer prose'
        assert_eq "$cutoff_doctor" "$OUTPUT" 'doctor output is unchanged'
    else
        assert_eq 1 "$STATUS" "$encoding: doctor retains its general LF text check"
        assert_eq '["Invalid spec text: .prdkit/history/archive.md (expected LF-terminated text)"]' \
            "$(jq -c .findings <<< "$OUTPUT")" 'the archive parser does not add a finding'
    fi
done
rm .prdkit/history/archive.md specs/changes/007-open.md

it "sparse compaction preserves exact history past open and planned changes, in either log order"
before_sparse="$(git rev-parse HEAD)"
mkdir -p specs/changes
for id in 001-first 002-second 003-outcome 004-fourth 005-fifth 006-sixth 008-planned 009-gap 010-tenth; do
    printf '# %s\n\n## State\n\nWaiting on: nothing\nNext: continue\n' "$id" > "specs/changes/$id.md"
done
printf -- '\n- **R-03 An open outcome** (hypothesis, planned: 003-outcome): record the outcome.\n- **R-04 Another plan** (hypothesis, planned: 008): record the result.\n' >> specs/product.md
git add specs; git commit -qm 'open changes'
stale="$(mktemp -d)"; track_tmp "$stale"
git worktree add -q --detach "$stale" HEAD
for id in 001-first 002-second 004-fourth 005-fifth 006-sixth 009-gap 010-tenth; do
    git rm -q "specs/changes/$id.md"
    printf -- '- 2026-10-10 %s: historical evidence for %s\n' "$id" "$id" >> .prdkit/history/log.md
done
git add .prdkit/history/log.md; git commit -qm 'close changes and snapshot the folded log'
folded_sha="$(git rev-parse HEAD)"
# shellcheck disable=SC2016 # Markdown code span
printf '# Archive\n\n**Log condensed through**: 002; also 004-006, 010; those entries: `git show %s:.prdkit/history/log.md`; also see the migration notes\n**Allocated through**: 010\n' "$folded_sha" > .prdkit/history/archive.md
archive_sha="$(sed -n 's/.*git show \([0-9a-f]*\):\.prdkit\/history\/log.md.*/\1/p' .prdkit/history/archive.md)"
assert_contains "$(git show "$archive_sha:.prdkit/history/log.md")" '005-fifth: historical evidence for 005-fifth' "a member in the middle of a range is retrievable by ID"
pass='- 2026-10-12 compaction: condensed older closes'
# The live 009 is in a gap and must not be treated as archived. Ten later closes are due.
before_pass='- 2026-10-10 009-gap: keep the entry in this gap'
after_pass="$(i=20; while [ "$i" -lt 30 ]; do printf -- '- 2026-10-13 %03d-new: a later close\n' "$i"; i=$((i + 1)); done)"
for order in oldest newest; do
    if [ "$order" = oldest ]; then printf '%s\n' "$before_pass" "$pass" "$after_pass"
    else printf '%s\n' "$after_pass" "$pass" "$before_pass"; fi > .prdkit/history/log.md
    run bash "$DOCTOR"
    assert_eq 0 "$STATUS" "$order: doctor accepts the sparse archive"
    assert_not_contains "$OUTPUT" "Planned for a closed change" "$order: planned gaps stay open"
    assert_contains "$OUTPUT" "Compaction due: 10 changes closed since the last pass" "$order: no archived history is recounted"
    run bash .prdkit/scripts/bash/status.sh --json
    assert_eq 0 "$STATUS" "$order: status accepts the same archive"
    assert_eq "003-outcome 008-planned" "$(jq -r '[.changes[].id] | sort | join(" ")' <<< "$OUTPUT")" "$order: neither cutoff nor sparse history is resurrected by a stale worktree"
    assert_eq 10 "$(jq '.compaction.closed_since_last' <<< "$OUTPUT")" "$order: status also counts only new closes"
done
sed -i.bak '/ 009-gap:/d' .prdkit/history/log.md; rm .prdkit/history/log.md.bak
run bash "$DOCTOR"
assert_contains "$OUTPUT" 'Closed without a log entry: 009-gap;' "a missing ID in a gap is still a finding"
printf '%s\n' "$before_pass" >> .prdkit/history/log.md

it "doctor rejects archived numbers still open, planned, or in either form of live log"
printf '# Open again\n' > specs/changes/001-reused.md
printf '# Open another\n' > specs/changes/005-reused.md
printf -- '\n- **R-05 Old plan** (hypothesis, planned: 001): no longer planned.\n- **R-06 Sparse plan** (hypothesis, planned: 005-reused): also no longer planned.\n' >> specs/product.md
printf -- '- 2026-10-10 004-fourth: historical evidence for 004-fourth\n' >> .prdkit/history/log.md
mkdir -p .prdkit/history/log
printf -- '- 2026-10-10 006-sixth: historical evidence for 006-sixth\n' > .prdkit/history/log/006-sixth.md
printf '%s\n' "$before_pass" > .prdkit/history/log/009-gap.md
run bash "$DOCTOR"
assert_eq 1 "$STATUS" "archive conflicts fail without --strict"
for id in 001-reused 005-reused; do
    assert_contains "$OUTPUT" "specs/changes/$id.md is open but its number is condensed" "doctor names conflicting open record $id"
done
assert_contains "$OUTPUT" 'Planned for a closed change: 001 at specs/product.md:' 'doctor rejects a planned cutoff number'
assert_contains "$OUTPUT" 'Planned for a closed change: 005-reused at specs/product.md:' 'an open record cannot hide a conflicting planned marker'
for id in 004-fourth 006-sixth; do
    assert_contains "$OUTPUT" "Live log entry for $id is also condensed" "even identical archived and live text is an error for $id"
done
assert_contains "$OUTPUT" 'Duplicate live log entry for 009-gap' 'folded and per-entry copies cannot both remain live'
run bash "$kit_bin/status.sh" --json
assert_eq 0 "$STATUS" 'status can summarize the live view despite the doctor finding'
assert_eq 11 "$(jq '.compaction.closed_since_last' <<< "$OUTPUT")" 'only non-archived closes count, including the live entry in a gap'
for order in oldest newest; do
    archived_copy='- 2026-10-14 004-fourth: stray folded copy'
    if [ "$order" = oldest ]; then printf '%s\n' "$before_pass" "$pass" "$after_pass" "$archived_copy"
    else printf '%s\n' "$archived_copy" "$after_pass" "$pass" "$before_pass"; fi > .prdkit/history/log.md
    run bash "$kit_bin/status.sh" --json
    assert_eq 11 "$(jq '.compaction.closed_since_last' <<< "$OUTPUT")" "$order: ignore archived entries on both live paths"
done
git worktree remove "$stale"
rm -f specs/changes/{001,005}-reused.md .prdkit/history/archive.md .prdkit/history/log/{006-sixth,009-gap}.md
git reset -q --hard "$before_sparse"

it "malformed sparse archive fields fail at their line in doctor and status"
for value in '002; also 006-004; @' '002; also 004-006, 006-008; @' '002; also 008, 004; @' \
             '002; also 001-004; @' '002; also four; @' '002; also 004-; @' '002; also -004; @' \
             '002; also 004,; @' '002; also ; @' '002; also 004' '002 also 004; @'; do
    # shellcheck disable=SC2016 # Markdown code span
    value="${value//@/those entries: \`git show abc1234:.prdkit/history/log.md\`.}"
    printf '# Archive\n\n**Log condensed through**: %s\n' "$value" > .prdkit/history/archive.md
    run bash "$DOCTOR" --json
    assert_eq 1 "$STATUS" "doctor rejects: $value"
    assert_contains "$(jq -r '.findings[]' <<< "$OUTPUT")" '.prdkit/history/archive.md:3:' 'doctor reports the source line'
    run bash .prdkit/scripts/bash/status.sh --json
    assert_eq 1 "$STATUS" "status rejects: $value"
    assert_contains "$OUTPUT" '.prdkit/history/archive.md:3:' 'status reports the same line, not cutoff-only JSON'
    assert_not_contains "$OUTPUT" '"compaction":' 'status does not report partial state'
done

it "all archive readers reject misplaced, misspelled, or split sparse fields before proceeding"
# shellcheck disable=SC2016 # Markdown code span
pointer='those entries: `git show abc1234:.prdkit/history/log.md`.'
kit_index() ( source "$kit_bin/spec-lib.sh"; spec_archive_log_index "$PWD"; )
for value in "002, also 005; $pointer" "002; als 005; $pointer" \
             "002;; also 005; $pointer" "002; also005; $pointer" \
             "002; also 005; $pointer; also 006" \
             $'002\n\n  also 005; '"$pointer" $'002;\n\n  also 005; '"$pointer" \
             $'002\n\n  also: 005; '"$pointer"; do
    printf '**Log condensed through**: %s\n' "$value" > .prdkit/history/archive.md
    line=1
    case "$value" in $'002\n'*) line=3 ;; esac
    for reader in index doctor status bounds new-change close-change; do
        case "$reader" in
            index) run kit_index ;;
            doctor|status) run bash "$kit_bin/$reader.sh" --json ;;
            bounds) run bash "$kit_bin/bounds.sh" 005-probe ;;
            new-change) run bash "$kit_bin/new-change.sh" --no-branch --number 005 --short-name probe 'Probe' ;;
            close-change) run bash "$kit_bin/close-change.sh" --pr https://example.invalid/pull/1 005-probe 'Probe' ;;
        esac
        assert_eq 1 "$STATUS" "$reader rejects $value"
        assert_contains "$OUTPUT" ".prdkit/history/archive.md:$line:" "$reader names the malformed line"
        assert_eq absent "$([ -e specs/changes/005-probe.md ] && echo present || echo absent)" 'no change number reused'
        rm -f specs/changes/005-probe.md
    done
done
rm .prdkit/history/archive.md

it "doctor verifies every sparse number in the local snapshot, and distinguishes shallow history"
# Use the real compaction snapshot; 007 is unused, and no live file can prove it.
# shellcheck disable=SC2016 # Markdown code span
printf '**Log condensed through**: 002; also 004-007, 010; those entries: `git show %s:.prdkit/history/log.md`.\nAllocated through: 010\n' "$folded_sha" > .prdkit/history/archive.md
run bash "$DOCTOR" --json
assert_eq 1 "$STATUS" 'unused number inside the claimed range is a finding'
assert_contains "$OUTPUT" 'is missing closed number(s) 007' 'reports the missing part of the range'
# shellcheck disable=SC2016 # Markdown code span
printf '**Log condensed through**: 002; also 004-999999999; those entries: `git show %s:.prdkit/history/log.md`.\nAllocated through: 999999999\n' "$folded_sha" > .prdkit/history/archive.md
run bash "$DOCTOR" --json
assert_contains "$OUTPUT" 'is missing closed number(s) 007-008' 'even a large range is compared as runs'
# shellcheck disable=SC2016 # Markdown code span
printf '**Log condensed through**: 002; also 005; those entries: `git show deadbeef:.prdkit/history/log.md`.\nAllocated through: 005\n' > .prdkit/history/archive.md
run bash "$DOCTOR" --json
assert_eq 1 "$STATUS" 'unresolvable SHA fails in the full clone'
assert_contains "$OUTPUT" '.prdkit/history/archive.md:1: cannot resolve sparse snapshot deadbeef to a commit'
# shellcheck disable=SC2016 # Markdown code span
printf '**Log condensed through**: 002; also 005; those entries: `git show %s:.prdkit/history/log.md`.\n' "$folded_sha" > .prdkit/history/archive.md
run bash "$DOCTOR" --json
assert_eq 1 "$STATUS" 'a sparse index needs an allocation floor'
assert_contains "$OUTPUT" '.prdkit/history/archive.md:1: a sparse index requires an Allocated through line'
printf 'Allocated through: five\n' >> .prdkit/history/archive.md
run bash "$DOCTOR" --json
assert_eq 1 "$STATUS" 'a malformed allocation floor is refused'
assert_contains "$OUTPUT" '.prdkit/history/archive.md:2: expected Allocated through: followed by one to nine decimal digits'
sed -i.bak '$s/five/004/' .prdkit/history/archive.md; rm .prdkit/history/archive.md.bak
run bash "$DOCTOR" --json
assert_eq 1 "$STATUS" 'the floor cannot be less than the largest indexed ID'
assert_contains "$OUTPUT" '.prdkit/history/archive.md:2: Allocated through is below the highest indexed number 5'
sed -i.bak '$s/004/006/' .prdkit/history/archive.md; rm .prdkit/history/archive.md.bak
git add .prdkit/history/archive.md; git commit -qm 'publish archive with older snapshot'
shallow="$(mktemp -d)"; track_tmp "$shallow"
git clone -q --depth 1 "file://$PROJ" "$shallow" || exit 1
assert_eq true "$(git -C "$shallow" rev-parse --is-shallow-repository)" 'the fixture really is shallow'
shallow_bin="$shallow/.prdkit/scripts/bash"
shallow_doctor() { bash "$shallow_bin/doctor.sh" "$@"; }
run shallow_doctor --json
assert_eq 0 "$STATUS" 'missing shallow history is advisory'
assert_contains "$(jq -r '.advisories[]' <<< "$OUTPUT")" "history unavailable in this shallow clone: cannot verify sparse snapshot $folded_sha"
# A valid index need not have local proof to reserve its number, but invalid syntax must fail.
run bash "$shallow_bin/new-change.sh" --no-branch --number 005 --short-name probe Probe
assert_eq 1 "$STATUS" 'shallow checkout still respects reservations'
assert_contains "$OUTPUT" 'reserved by the condensed log index'
printf '**Log condensed through**: 002\n\n  also: 005; %s\n' "$pointer" > "$shallow/.prdkit/history/archive.md"
run shallow_doctor --json
assert_eq 1 "$STATUS" 'a shallow clone never downgrades malformed syntax to missing history'
assert_contains "$(jq -r '.findings[]' <<< "$OUTPUT")" '.prdkit/history/archive.md:3:'
sed -i.bak '$s/006/005/' .prdkit/history/archive.md; rm .prdkit/history/archive.md.bak
for state in working committed; do
    if [ "$state" = committed ]; then git add .prdkit/history/archive.md && git commit -qm 'lower the floor' || exit 1; fi
    run bash "$DOCTOR" --json
    assert_eq 1 "$STATUS" "$state decrease is refused even though every indexed number is covered"
    assert_contains "$OUTPUT" '.prdkit/history/archive.md:2: Allocated through decreased from 6 to 5'
done
git reset -q --hard "$before_sparse"

it "doctor distinguishes a sparse checkout from a deleted allocation floor"
floor_project="$(make_inited_project)"; track_tmp "$floor_project"
cd "$floor_project" || exit 1
mkdir -p specs .prdkit/history
printf '# Demo product\n' > specs/product.md
printf '**Log condensed through**: 002\n**Allocated through**: 005\n' > .prdkit/history/archive.md
git add -A && git commit -qm 'archive with an allocation floor' &&
    git commit -qm 'leave the floor unchanged' --allow-empty || exit 1
floor_doctor=.prdkit/scripts/bash/doctor.sh
run bash "$floor_doctor" --json
assert_eq 0 "$STATUS" 'the materialized floor passes'

mv .prdkit/history/archive.md .git/saved-archive
run bash "$floor_doctor" --json
assert_eq 1 "$STATUS" 'an unstaged deletion still fails'
assert_contains "$OUTPUT" 'Allocated through decreased from 5 to 0'
git add -u -- .prdkit/history/archive.md
run bash "$floor_doctor" --json
assert_eq 1 "$STATUS" 'a staged deletion still fails'
assert_contains "$OUTPUT" 'Allocated through decreased from 5 to 0'
mv .git/saved-archive .prdkit/history/archive.md
git add .prdkit/history/archive.md &&
    git sparse-checkout set --no-cone '/*' '!/.prdkit/history/archive.md' || exit 1
assert_eq absent "$([ -e .prdkit/history/archive.md ] && echo present || echo absent)"
assert_eq 'S .prdkit/history/archive.md' "$(git ls-files -t -- .prdkit/history/archive.md)"
assert_eq '' "$(git status --porcelain)" 'sparse checkout is clean'
run bash "$floor_doctor" --json
assert_eq 0 "$STATUS" 'the unchanged floor still passes when sparse checkout omits its file'
assert_not_contains "$OUTPUT" 'Allocated through decreased'

floor_shim="$(mktemp -d)"; track_tmp "$floor_shim"
cat > "$floor_shim/git" <<'SH'
#!/usr/bin/env bash
if [ "${3:-}" = show ] && [ "${4:-}" = :./.prdkit/history/archive.md ]; then exit 1; fi
exec "$REAL_FLOOR_GIT" "$@"
SH
chmod +x "$floor_shim/git"
run env PATH="$floor_shim:$PATH" REAL_FLOOR_GIT="$(command -v git)" bash "$floor_doctor" --json
assert_eq 1 "$STATUS" 'unavailable archive evidence is not a passing check'
assert_contains "$OUTPUT" '.prdkit/history/archive.md: condensed log index unavailable from the Git index'
assert_not_contains "$OUTPUT" 'Allocated through decreased'
cd "$PROJ" || exit 1

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

it "trace: a Code path that is not in the repository (advisory)"
mkdir -p src/web/pages; printf 'x\n' > src/web/app.py; printf 'x\n' > src/web/pages/home.py; printf 'x\n' > src/web/pages/helper.py
# shellcheck disable=SC2016 # backticks are Markdown code spans
{ printf '# P1 Web\n\n**What it is**: pages · **Maturity**: validated · **Code**: `src/web`, `src/web/app.py:3-9`,\n'
  printf '`src/web/gone.py` (views in `pages/home.py`), src/web/old.py, and/or `<paths>`, `src/*.py`,\n'
  printf '`org/repo:src/x.py`, `https://example.com/x.py`, `dotnet test` · **Owner**: `src/elsewhere.py`\n\n'
  printf -- '- **P1.B-01 Greeting page**: shows the greeting for R-01. Test: test_greeting.\n'
  printf -- '- Deploy job: ships the pages. Code: `scripts/deploy.sh#L2`; none yet for `src/later.py`.\n'
  printf -- '- Mail job: sends receipts. Code: `myapp.web`, `Company.Product.Api`, `api.example.com`.\n'
  printf -- '- Errors map to a Status Code: `4xx/5xx`.\n'; } > specs/parts/p1-web.md
run bash "$DOCTOR" --json
assert_eq 0 "$STATUS" "an advisory"
assert_contains "$OUTPUT" "Code path not in the repository (4): src/web/gone.py at specs/parts/p1-web.md:3, src/web/old.py at specs/parts/p1-web.md:3, scripts/deploy.sh at specs/parts/p1-web.md:8, src/later.py at specs/parts/p1-web.md:8; name repo-relative paths that exist" "missing spans and bare paths, at their item; a path under one named before it, a :line suffix, placeholders, globs, other repositories, URLs, commands, later labels, a name with no path before it and a label inside a phrase are not judged"
assert_contains "$OUTPUT" '"code-path":4' "counted in JSON"
# shellcheck disable=SC2016 # backticks are Markdown code spans
printf -- '- Helpers. Code: `src/web/pages/home.py`, `helper.py`, `missing.py`.\n\nBuild scripts run in CI.\nCode: `ci/run.sh`.\n' > specs/parts/p1-web.md
run bash "$DOCTOR"
assert_contains "$OUTPUT" "Code path not in the repository (2): missing.py at specs/parts/p1-web.md:1, ci/run.sh at specs/parts/p1-web.md:3;" "a file name resolves in the directory of a file before it; a label opening a line counts"
git checkout -q -- specs; rm -rf src

it "trace: planned: names an open change, else a closed or an unknown one"
mkdir -p specs/changes; printf '# Change: export\n## State\n**Waiting on**: nothing\n**Next**: build\n' > specs/changes/012-export.md
printf -- '- 2026-10-10 010-import: imported.\n' > .prdkit/history/log.md
cat >> specs/product.md <<'MD'
- **R-03 Export** (hypothesis, planned: 012-export): users export.
- **R-04 Import** (hypothesis, planned: 010-import): users import.
- **R-05 Share** (hypothesis): users share,
  planned: `013`.
- **R-06 Print** (hypothesis, planned: 012): users print.
- **R-07 Badge** (hypothesis, planned: M1): a milestone, not a change.
- **R-08 Theme** (hypothesis, planned: 12): too short for a change number.
- **R-09 Archive** (hypothesis, planned: 2026-Q4): a date, not a change.
- **R-10 Sync** (hypothesis, planned: acme/platform#12): another repository's change.
- **R-11 Old badge** (validated): retired: dropped (was planned: M2).
- **R-12 Icon** (hypothesis): users pick one, **planned: M3**.

| Area | Note |
|------|------|
| Zones | planned: both zones |
MD
run bash "$DOCTOR"
assert_contains "$OUTPUT" "advisory: Planned for a closed change (1): 010-import at specs/product.md:7; .prdkit/history/log.md closed it: remove the marker if it was built, or re-plan it to an open change" "a marker naming a closed change"
assert_contains "$OUTPUT" "advisory: Planned for no open change (5): 013 at specs/product.md:8, 2026-Q4 at specs/product.md:13, M1 at specs/product.md:11, 12 at specs/product.md:12, M3 at specs/product.md:16; point it at an open change record (new-change.sh opens one) or remove the marker" "a wrapped marker naming no change, and item markers naming no change number, emphasis stripped"
assert_not_contains "$OUTPUT" "M2" "a retired item's old marker is not judged"
assert_not_contains "$OUTPUT" "012" "an open change, with or without its slug"
assert_not_contains "$OUTPUT" "acme/platform" "another repository's change is not judged"
assert_not_contains "$OUTPUT" "both zones" "a table cell is not an item marker"
git checkout -q -- specs; rm -rf specs/changes .prdkit/history/log.md

it "trace: a retired ID cited in spec text (advisory)"
mkdir -p specs/architecture
cat >> specs/architecture.md <<'MD'

## Notes

- The greeting keeps R-02's wording.
- The footer keeps R-02's wording too.
- R-02 was retired for R-01.
- R-01 replaced R-02.
MD
printf '# Demo — retired\n\n## Retired\n\n- **P1.B-09 Old page**: now P1.B-01, as R-02 asked.\n' > specs/architecture/retired.md
printf '# Demo — old notes (retired: folded into architecture.md)\n\nR-02 lived here.\n' > specs/architecture/old-notes.md
printf '# D-02 Cache pages\n\nIt amended R-02.\n' > specs/decisions/D-02.md
run bash "$DOCTOR" --json
assert_contains "$OUTPUT" "Retired ID cited in the spec (1): R-02 at specs/architecture.md:9; cite what replaced it, or drop the reference" "a live line citing a retired ID, once per file; not its retiring line, a line saying retired or replaced, architecture/retired, a retired file or a decision record"
assert_contains "$OUTPUT" '"retired-cited":1' "counted in JSON"
git checkout -q -- specs; rm -rf specs/architecture specs/decisions/D-02.md

it "trace: an R or Q no part or architecture file cites; a part needed by nothing (advisory)"
mkdir -p specs/product
printf '# Demo — lifecycle\n\n**Now**: MVP · **Next**: GA\n' > specs/product/lifecycle.md
cat >> specs/product.md <<'MD'
- **R-10 Search** (hypothesis): users search.
- **R-11 Filter** (hypothesis): users filter.
- **R-12 Sort** (hypothesis): users sort by R-13 tags.
- **R-13 Tag** (hypothesis): users tag.
- **Q-05 Plan limits** (hypothesis, from: ga): per plan. Enforced by: owner review.
- **R-14 Old search** (hypothesis): retired: now R-10.
MD
cat >> specs/architecture.md <<'MD'
| P2 Jobs | runs jobs | hypothesis | none | nightly | parts/p2-jobs.md |
| P3 Feed | lists pages | hypothesis | none | R-01 | none yet |
MD
printf '# P1 Web\n\n## Why it exists\n\nServes R-10 to\nR-12.\n' > specs/parts/p1-web.md
printf '# P2 Jobs\n\n## Why it exists\n\nRuns the nightly work.\n\n## Behaviors\n\n- **P2.B-01 Reindex**: keeps R-01 pages fresh. Test: unenforced.\n' > specs/parts/p2-jobs.md
printf '# P4 Mail\n\n## Why it exists\n\nSends R-01 receipts.\n' > specs/parts/p4-mail.md
run bash "$DOCTOR" --json
assert_contains "$OUTPUT" "R or Q no part or architecture file cites (1): R-13 at specs/product.md:9;" "only an item no part or architecture file cites: a range across lines covers its middle, a later-stage item waits, a retired one is gone, another product item does not allocate"
assert_contains "$OUTPUT" "Part citing no journey, R or Q (1): P2 at specs/architecture.md:6; say in Why it exists" "a part whose row and Why it exists cite none, though a behavior does"
assert_contains "$OUTPUT" '"unallocated":1,"part-need":1' "counted in JSON"
rm -rf specs/product specs/parts/p2-jobs.md specs/parts/p4-mail.md; git checkout -q -- specs

it "trace: a change record restating a spec item or citing an ID defined nowhere (advisory)"
mkdir -p specs/changes
cat > specs/changes/014-search.md <<'MD'
# Change: search

## Spec edits

| Level | ID | Edit | Note |
|-------|----|------|------|
| L0 | R-20 | add | search |

## Intent

- **R-01 Greet users** (validated): restated here.
- **R-21 Filter** (hypothesis): proposed in this record.

Builds R-20 and R-21 for R-01; touches R-99.

- Then R-99 again.
MD
run bash "$DOCTOR" --json
assert_contains "$OUTPUT" "Change record restates a spec item (1): R-01 at specs/changes/014-search.md:11 (spec: specs/product.md:3); cite its ID and edit the spec instead" "a redefinition"
assert_contains "$OUTPUT" "Change record cites an ID defined nowhere (1): R-99 at specs/changes/014-search.md:14;" "an ID the spec, a record's items and its Spec edits all lack, once per record"
assert_contains "$OUTPUT" '"change-restates":1,"change-undefined":1' "counted in JSON"
rm -rf specs/changes

it "raw evidence tracked under specs/ is an advisory"
mkdir -p specs/changes/results; printf 'output\n' > specs/changes/results/run.log
git add -A >/dev/null
run bash "$DOCTOR"
assert_contains "$OUTPUT" "advisory: Raw evidence tracked under specs/: 1 file(s)" "tracked evidence surfaced"
git rm -rqf specs/changes

it "a tracked raw archive requires the current archive format"
mkdir -p specs/archive/product-spec; printf '# Old product spec\n' > specs/archive/product-spec/product-spec.md
run bash "$DOCTOR"
assert_not_contains "$OUTPUT" "Archive on main" "an untracked folder is not on main"
git add specs/archive
run bash "$DOCTOR"
assert_eq 1 "$STATUS" "unsupported layout is a finding"
assert_contains "$OUTPUT" "Unsupported specs/archive/ layout:" "the old path is named"
assert_contains "$OUTPUT" ".prdkit/history/archive.md history" "the current path is named"
run bash "$DOCTOR" --strict
assert_eq 1 "$STATUS" "--strict fails it"
git rm -rqf specs/archive

it ".prdkit/history/archive.md: its links resolve, a git path is code, its budget grows into git"
# shellcheck disable=SC2016 # backticks are Markdown code spans, not command substitution
{ printf '# Demo — archive\n\n**Base**: `abc1234`. Details: `git show abc1234:specs/features/003-x/spec.md`, `[x](gone-in-code.md)`.\n\n'
  printf 'See [the product](/specs/product.md) and [the old spec](/specs/features/003-x/spec.md).\n'
  i=0; while [ "$i" -lt 150 ]; do echo "line $i"; i=$((i + 1)); done; } > .prdkit/history/archive.md
run bash "$DOCTOR"
assert_contains "$OUTPUT" "Link at .prdkit/history/archive.md:5 points to specs/features/003-x/spec.md, which does not exist" "a link into a removed folder"
assert_not_contains "$OUTPUT" "points to specs/product.md" "a link to the live spec resolves"
assert_not_contains "$OUTPUT" "gone-in-code" "a git path or a link in code is no link"
assert_contains "$OUTPUT" "Budget: .prdkit/history/archive.md has 155 lines that read as 156 at 100 characters a line, over its 150-line reading budget" "condensed past its budget"
assert_not_contains "$OUTPUT" "Archive on main" "the condensed file is no raw archive"
rm .prdkit/history/archive.md

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
printf '## Split\n- **Environment**: elsewhere.\n' > "$EN/specs/product/lifecycle/split.md"
run bash -c "cd '$EN' && bash .prdkit/scripts/bash/doctor.sh"
assert_contains "$OUTPUT" "Environments: the Private preview stage at specs/product/lifecycle.md:10 runs in none of the environments specs/architecture/environments.md lists (TEST, PROD, EDGE); name one, or add it there" "a stage naming no listed environment, as a whole word, as spelled"
assert_contains "$OUTPUT" "the GA stage at specs/product/lifecycle.md:14" "a name from another table is not an environment"
assert_contains "$OUTPUT" "the Retired stage at specs/product/lifecycle/retired.md:5" "a stage piece is checked too, by whole words"
assert_contains "$OUTPUT" "Environments: a stage at specs/product/lifecycle/sunset.md:3" "a piece without a stage heading"
assert_contains "$OUTPUT" "the Split stage at specs/product/lifecycle/split.md:2 runs" "split lines"
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
fill_seeded_policy "$EX" || exit 1
cp -R "$PK_ROOT/examples/request-service/specs" "$EX/"
run bash -c "cd '$EX' && bash .prdkit/scripts/bash/doctor.sh --strict"
assert_eq 0 "$STATUS" "example has no findings or advisories"

it "ordinary link destinations and paired tags in the filled example pass strict doctor"
arch="$EX/specs/architecture.md"
cp "$arch" "$arch.saved"
printf 'Component definitions are versioned here.\n' > "$EX/specs/components"
cat >> "$arch" <<'MD'

[Component definitions](<components>)

The manifest stores component identifiers in the `<id>` children of <components></components>.
MD
run bash -c "cd '$EX' && bash .prdkit/scripts/bash/doctor.sh --strict --json"
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq 0 "$(jq '.trace["template-placeholder"]' <<< "$OUTPUT")"
mv "$arch.saved" "$arch"
rm "$EX/specs/components"

it "residue cannot leak out of an inline construct in a filled spec"
printf 'Delivery and tooling are documented here.\n' > "$EX/specs/delivery, tooling"
cp "$arch" "$arch.saved"
for boundary in link-comment link-backtick html-comment html-backtick ordered-marker empty-bullet \
        reference-definition inline-unclosed block-comment table-block-comment; do
    cp "$arch.saved" "$arch"
    printf '\n## Markdown boundaries\n\n' >> "$arch"
    expected=1
    case "$boundary" in
        link-comment)
            cat >> "$arch" <<'MD'
[Guide](https://example.org "The <!-- delimiter").

Architecture still needs <delivery, tooling>.
MD
            ;;
        link-backtick)
            cat >> "$arch" <<'MD'
[Guide](https://example.org "A ` delimiter"). Architecture still needs <delivery, tooling>. Then a literal `.
MD
            ;;
        html-comment)
            cat >> "$arch" <<'MD'
The <span title="The <!-- delimiter">guide</span> is deployed.

Architecture still needs <delivery, tooling>.
MD
            ;;
        html-backtick)
            cat >> "$arch" <<'MD'
The <span title="A ` delimiter">guide</span> is deployed. Architecture still needs <delivery, tooling>. Then a literal `.
MD
            ;;
        ordered-marker)
            expected=0
            cat >> "$arch" <<'MD'
Example `raw
2. <delivery, tooling> text`.
MD
            ;;
        empty-bullet)
            expected=0
            cat >> "$arch" <<'MD'
Example `raw
*
<delivery, tooling> text`.
MD
            ;;
        reference-definition)
            cat >> "$arch" <<'MD'
[Guide][docs], [the local notes][local], [the overview][overview], and [the API][api].

[docs]: https://example.org "<delivery, tooling>"
[local]: <delivery, tooling>
[overview]: https://example.org '<delivery, tooling> <!--'
[api]: https://example.org (A ` delimiter and <delivery, tooling>)

Architecture still needs <delivery, tooling>. Then a literal `.
MD
            ;;
        inline-unclosed)
            cat >> "$arch" <<'MD'
Example <!-- raw.

Architecture still needs <delivery, tooling>.

Close here -->.
MD
            ;;
        block-comment)
            cat >> "$arch" <<'MD'
Architecture note with an unmatched `.
<!-- This genuine comment starts on its own line, even with a ` and <delivery, tooling> here.

## Not a heading
The hidden example was <delivery, tooling>.

--> Architecture still needs <delivery, tooling>.
MD
            ;;
        table-block-comment)
            cat >> "$arch" <<'MD'
| Topic | Notes |
|-------|-------|
| First | Details |
<!-- A genuine comment with a pipe | <delivery, tooling>.

More hidden text: <delivery, tooling>.

--> Architecture still needs <delivery, tooling>.
MD
            ;;
    esac
    run bash -c "cd '$EX' && bash .prdkit/scripts/bash/doctor.sh --strict --json"
    assert_eq "$expected" "$STATUS" "$boundary: $OUTPUT"
    assert_eq "[$expected,$expected]" "$(jq -c '[.trace["template-placeholder"], (.findings | length)]' <<< "$OUTPUT")" "$boundary: $OUTPUT"
done
mv "$arch.saved" "$arch"
rm "$EX/specs/delivery, tooling"

it "the real Parts table resolves backticks, comments and escaped pipes within each cell"
cp "$arch" "$arch.saved"
for boundary in code paired-comment open-comment escaped-pipe; do
    case "$boundary" in
        code) before='`'; after='`' ;;
        paired-comment) before='<!--'; after='-->' ;;
        open-comment) before='<!--'; after='example' ;;
        escaped-pipe)
            # shellcheck disable=SC2016 # backticks are literal Markdown
            before='`A\|B`'; after='example'
            ;;
    esac
    ROW_BEFORE="$before" ROW_AFTER="$after" awk '
        function replace_cell(row, col, value,   cells,n,i,out) {
            n = split(row, cells, /\|/)
            cells[col] = value
            for (i = 1; i <= n; i++) out = out (i > 1 ? "|" : "") cells[i]
            return out
        }
        /^\| Part \|/ && /\| Components \|/ {
            n = split($0, columns, /\|/)
            for (c = 1; c <= n; c++) if (columns[c] == " Components ") col = c
            sub(/\| Components \|/, "| Before | Components | After |")
            print
            getline; print replace_cell($0, col, " --- | --- | --- ")
            getline; print replace_cell($0, col, " " ENVIRON["ROW_BEFORE"] " | <components> | " ENVIRON["ROW_AFTER"] " ")
            next
        }
        { print }
    ' "$arch.saved" > "$arch"
    if [ "$boundary" = open-comment ]; then
        cat >> "$arch" <<'MD'

## Markdown boundaries

| Topic | Notes |
|-------|-------|
| First | <!-- example |
| Second | <delivery, tooling> |

Architecture still needs <delivery, tooling>.
MD
        expected=3
    else
        expected=1
    fi
    run bash -c "cd '$EX' && bash .prdkit/scripts/bash/doctor.sh --strict --json"
    assert_eq 1 "$STATUS" "$boundary: $OUTPUT"
    assert_eq "[$expected,1]" "$(jq -c '[.trace["template-placeholder"], (.findings | length)]' <<< "$OUTPUT")" "$boundary: $OUTPUT"
    assert_contains "$OUTPUT" '(<components>)'
done
mv "$arch.saved" "$arch"

it "an untouched caption in the kit's two-stage journey table fails strict doctor"
product="$EX/specs/product.md"
sed -i.bak 's/^\(| Requests | | \)\[J-01\]/\1[J-01 <journey>]/' "$product"
run bash -c "cd '$EX' && bash .prdkit/scripts/bash/doctor.sh --strict --json"
assert_eq 1 "$STATUS" "$OUTPUT"
assert_eq 1 "$(jq '.trace["template-placeholder"]' <<< "$OUTPUT")"
assert_eq 1 "$(jq '.findings | length' <<< "$OUTPUT")" "the caption is the only finding"
assert_contains "$OUTPUT" '(<journey>)'
mv "$product.bak" "$product"

it "a filled spec with bracket notation and non-stock Mermaid lines still passes strict doctor"
cat >> "$EX/specs/architecture.md" <<'MD'

An identifier can look like `<request>` or [status]. [The identifiers part](parts/p9-identifiers.md) serves J-01.

| Format | Example |
|--------|---------|
| Type | `Queue<Entry>` |

```text
P1->>P2: <request>
```

```mermaid
flowchart LR
  C[Client] -->|"Queue&lt;Entry&gt;"| S["Store [active]"]
```

```mermaid
sequenceDiagram
  Client->>Service: <request>
  Client->>Service: <request> (the caller's variable)
  P1->>P2: <request> (the caller's variable)
```
MD
mkdir -p "$EX/specs/parts" || exit 1
cat > "$EX/specs/parts/p9-identifiers.md" <<'MD'
# P9 Identifiers

**What it is**: Formatting conventions for identifiers seen by users in J-01.

## Why it exists

Readers need to recognize identifiers in J-01.

An alert shows `P<n>` as the generic identifier notation when the part index is hidden.

    Code: <path> (a sample line of indented CLI help)
MD
run bash -c "cd '$EX' && bash .prdkit/scripts/bash/doctor.sh --strict --json"
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq 0 "$(jq '.trace["template-placeholder"]' <<< "$OUTPUT")"

it "split requirement and quality metadata survives multiple linked journeys"
journeys="$EX/specs/product/journeys"
sed '1s/J-01 Get a request handled/J-02 Track a request/' "$journeys/j-01-get-a-request-handled.md" > "$journeys/j-02-track-a-request.md"
printf '\n[J-02 Track a request](product/journeys/j-02-track-a-request.md).\n' >> "$EX/specs/product.md"
req="$EX/specs/product/requirements.md"
qual="$EX/specs/product/qualities.md"
sed -i.bak 's/Journeys: J-01\./Journeys: J-01, J-02./' "$req"
sed -i.bak '6s/$/ Source: <owner, date: "<words>"; observed; or the change that introduced it>./' "$req"
sed -i.bak 's/Journeys: J-01\. Enforced by: unenforced\./Journeys: J-01, J-02. Enforced by: <test, metric, owner review or unenforced>./' "$qual"
run bash -c "cd '$EX' && bash .prdkit/scripts/bash/doctor.sh --strict --json"
assert_eq 1 "$STATUS" "$OUTPUT"
assert_eq 1 "$(jq '.findings | length' <<< "$OUTPUT")" "residue is the only failure"
assert_eq 2 "$(jq '.trace["template-placeholder"]' <<< "$OUTPUT")"
assert_contains "$OUTPUT" 'specs/product/requirements.md:5 (<owner, date:'
assert_contains "$OUTPUT" 'specs/product/qualities.md:3 (<test, metric, owner review or unenforced>)'
sed -i.bak 's/Source: <.*>/Source: observed/' "$req"
sed -i.bak 's/Enforced by: <.*>/Enforced by: unenforced/' "$qual"
run bash -c "cd '$EX' && bash .prdkit/scripts/bash/doctor.sh --strict --json"
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq 0 "$(jq '.trace["template-placeholder"]' <<< "$OUTPUT")"

it "the generated catalog detects a new slot and a stale slot independently"
generator="$PK_ROOT/scripts/maintainer/generate-template-residue.py"
catalog="$PK_ROOT/scripts/template-residue.tsv"
MUTANT="$(mktemp -d)"; track_tmp "$MUTANT"
python3 "$generator" > "$MUTANT/fresh.tsv" || exit 1
run cmp -s "$catalog" "$MUTANT/fresh.tsv"
assert_eq 0 "$STATUS" "checked-in catalog must equal regeneration byte-for-byte"
cp -R "$PK_ROOT/templates" "$MUTANT/"
printf '\n- **Rollout when**: <owner-visible rollout conditions>.\n' >> "$MUTANT/templates/lifecycle-template.md"
python3 "$generator" "$MUTANT/templates" > "$MUTANT/mutated.tsv" || exit 1
run cmp -s "$catalog" "$MUTANT/mutated.tsv"
assert_eq 1 "$STATUS" "an addition fails the same equality check"
assert_contains "$(cat "$MUTANT/mutated.tsv")" '<owner-visible rollout conditions>' "new slots enter the catalog"
sed 's/<observable criteria>/filled criteria/' "$PK_ROOT/templates/lifecycle-template.md" > "$MUTANT/templates/lifecycle-template.md"
python3 "$generator" "$MUTANT/templates" > "$MUTANT/mutated.tsv" || exit 1
run cmp -s "$catalog" "$MUTANT/mutated.tsv"
assert_eq 1 "$STATUS" "a removal fails the same equality check"
assert_not_contains "$(cat "$MUTANT/mutated.tsv")" '<observable criteria>' "removing a slot drops the orphaned token"

finish
