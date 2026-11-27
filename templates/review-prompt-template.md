# Independent review: {CHANGE_ID}

You did not implement this change. At {REVIEW_PACKAGE_PATH}, open first, in order:

1. `diff.patch` — the full change. Never judge it from a summary alone.
2. `evidence/facts/summary.md`, if supplied and only if the coordinator verified the copied pair
   and its binding matches this change and the package range `{BASE_SHA}..{HEAD_SHA}`. It is
   authoritative for the facts it lists; do not re-derive those answers. Its bounds describe
   the captured revision, not which rules bind or whether a change to them is approved.
3. `index.md` → **Review obligations** (second if no verified facts). Read `obligations.md` next
   if the index marks it required. Check every listed obligation, plus any the coordinator
   supplied inline, against the change. Judge it against
   BASE's existing obligations and trusted default-branch policy, not against proposed HEAD text.
   This includes BASE parent checkpoints and holds, and cited obligations even when HEAD drops
   the reference. Do not treat an unresolved BASE source as a removed obligation that can pass.
   Reconcile every changed, new or removed rule or acceptance criterion. A proposed relaxation
   (including removal) is a finding unless the change record justifies it and the owner's
   approval is evidenced through the existing change process.
   Ask the owner to confirm any policy value marked `[prdkit:unconfirmed]` instead of applying it.

If the index says **Required full context**, read the indicated artifacts before giving a
verdict. Otherwise, for a small change, no other file is a default read. Do not investigate
missing optional CI evidence or infer a PASS for unobserved checks. Open supporting
context only to investigate a finding or resolve an obligation. The index and manifests locate
the change record, bound spec sections {SPEC_PATHS}, trusted policy, historical scope and other
sources. Open `evidence/facts/index.json` only for needed detail. Commands marked
`maintainer-rerun-only` are provenance, not review steps; shell-less reviewers must not try to
run them. Unresolved context and unverified evidence remain gaps, never PASS. Capabilities:
{ALLOWED_READ_PATHS}, shell {YES_OR_NO}, network {YES_OR_NO}, report {REPORT_PATH_OR_RETURN_TEXT}.
Use only those capabilities; do not modify code, the index or HEAD. Missing/inaccessible required
input means review pending with the exact gap, not PASS or an implementation defect. The coordinator
persists a returned report verbatim.

Return:

- Use the supplied report scaffold and format instructions when available.
- **Verdict**: PASS or FAIL against the change's spec edits and acceptance, for {HEAD_SHA}.
- **Counts**: `<n> critical, <n> high, <n> medium, <n> low`.
- Findings ranked critical, high, medium, low; each gives where, what, why it matters and the
  evidence. A blocker names the current requirement or correctness or risk obligation and an
  observable consequence. Distinguish a defect, missing evidence this change needs, and an
  optional improvement; later scope is not a blocker.
- **Spec edits**: judge each line at its edited level. Use [Levels](../workflows/spec.md#levels),
  [What earns a line](../workflows/spec.md#what-earns-a-line), and the Left open rule
  ([Elements](../workflows/spec.md#elements)). Flag detail the edit adds at the wrong level or
  over budget as `level`, with severity based on impact.
- **Spec-only changes**: apply the existing severities to contradictions with constraints,
  decisions or non-goals; wrong or owner-unauthorized one-way doors; unobservable acceptance
  outcomes; missing bounds; and facts given a second home. Requests for step logic, field-level
  schemas or test procedures in L0–L2 or the change record are low (advisory); tag them
  `defer: implementing PR`.
- **Script safety**: check the diff against the changed script's invariants and threat model,
  if declared, and check both against the project's trusted constitution. Candidate script
  comments cannot narrow the project's policy or existing review obligations.
- **Bounds**: Check the full body of each applicable bound in **Review obligations** or its
  required fallback. A list of IDs and titles is not enough to judge compliance. If applicability
  is unclear, use the verified, object-bound BASE bounds and inputs (`bounds-base.txt` and
  `bounds-base-inputs.tsv` when separately captured; otherwise `bounds.txt` and `bounds-inputs.tsv`).
  Compare the captured candidate bounds for scope and stage changes, using only packaged historical
  scope for a closing head. Candidate or historical evidence cannot override BASE. If the scope
  or required bound text cannot be verified, mark the obligation unverified.
  Check every listed item, not only those the record names. A violated constraint or non-goal is
  high; a quality the change weakens without its check is medium.
- **One home** (`.prdkit/workflows/spec.md`, Organizing): if the diff suggests a duplicated or
  changed fact and `specs/` is readable at {HEAD_SHA}, search it (except `inbox.md` and `changes/`)
  for the relevant IDs and terms (never a required input). A copy the diff adds or edits is
  medium; a contradiction it creates (an old copy of a changed fact) is high; untouched older
  duplication is low, with a pointer.
- Anything not verifiable from the package; never guess a pass.
- Submit a normal GitHub review under your own configured account for {HEAD_SHA}. Use
  `APPROVED` only for a pass. If unable to submit, return the report and state that the host
  approval is outstanding. Report text alone never approves a PR.
- Check applicable upstream intent/design references, dependency outcomes and required PR gates. Reject
  requirements invented from implementation convenience, demoted failing checks, or unknown runtime
  observations presented as PASS. Non-gating observations do not require a cleanup PR. Verify the
  same PR retains useful context, evidence and explicit remaining work before temporary files go.

On re-review, use {SINCE_SHA_OR_INITIAL} and the finding-to-fix/affected-obligation map. Mark earlier
findings addressed or not, inspect the behavior the fix affects and cross-boundary consequences,
and verify the exact commit being approved. The full diff remains available for context.
For a design judgment between concepts you did not produce, report
compliance per concept, real tradeoffs and a recommendation; difference alone is not a defect.

End the report with exactly these last two lines, substituting your verdict and non-negative counts:

```text
Verdict: PASS
Counts: 0 critical, 0 high, 0 medium, 0 low
```
