# Independent review: {CHANGE_ID}

You did not implement this change. Start at the package index, context-manifest.tsv and full
change diff at {REVIEW_PACKAGE_PATH} for {BASE_SHA}..{HEAD_SHA}. Read the actual child record,
the bound spec sections {SPEC_PATHS}, the constitution's review policy and the selected parent
checkpoint/obligations, not the whole parent by default. Immutable source/blob/line bindings
distinguish current canon, trusted policy and a recovered historical closing record.
Unresolved context and unverified evidence remain gaps, never PASS. Never judge from a summary. Capabilities:
{ALLOWED_READ_PATHS}, shell {YES_OR_NO}, network {YES_OR_NO}, report {REPORT_PATH_OR_RETURN_TEXT}.
Use only those capabilities; do not modify code, the index or HEAD. Missing/inaccessible required
input means review pending with the exact gap, not PASS or an implementation defect. The coordinator
persists a returned report verbatim.

Return:

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
- **Bounds**: with shell access, run `.prdkit/scripts/bash/bounds.sh {CHANGE_ID}`; otherwise read
  the packaged output and its bound revision/inputs. Check every listed item, not only those the
  record names. Missing/stale bounds output leaves that obligation unverified. A violated
  constraint or non-goal is high; a quality the change weakens without its check is medium.
- **One home** (`.prdkit/workflows/spec.md`, Organizing): if `specs/` is readable at {HEAD_SHA},
  search it, except `archive.md`, `log.md`, `log/`, `inbox.md` and `changes/`, for the touched IDs and
  terms (never a required input). A copy the diff adds or edits is medium; a contradiction it creates (an old copy
  of a changed fact) is high; untouched older duplication is low, with a pointer.
- Anything not verifiable from the package; never guess a pass.
- Identify the eligible registered reviewer context `{REVIEWER_ID}`. The coordinator preserves
  your report verbatim; the trusted publisher runs `publish-review.sh --from-report <file>` to
  bind the verdict and counts to reviewed content; the publisher posts it; never paste it yourself:

```text
<!-- prdkit-review
{"schema":"prdkit.review.v3","id":"<32 hex>","repo":"<owner>/<name>","pr":1,"change":"{CHANGE_ID}","reviewer":"{REVIEWER_ID}","from":"start","to":"fp1:<64 hex>","head":"{HEAD_SHA}","since":"","base":"refs/remotes/origin/<branch>","base_at":"<40 hex>","verdict":"{PASS_OR_FAIL}","critical":0,"high":0,"medium":0,"low":0,"report":"<url>"}
-->
```

The receipt is metadata, not evidence of independence.

- Check the upstream intent/design references, dependency outcomes and required PR gates. Reject
  requirements invented from implementation convenience, demoted failing checks, or unknown runtime
  observations presented as PASS. Non-gating observations do not require a cleanup PR. Verify the
  same PR retains useful context, evidence and explicit remaining work before temporary files go.

On re-review, use {SINCE_SHA_OR_INITIAL} and the finding-to-fix/affected-obligation map. Mark earlier
findings addressed or not, inspect the behavior the fix affects and cross-boundary consequences,
and keep unchanged approvals. dispatch.json separates authenticated retained coverage from
prospective carry: a forecast requires an actual clean native narrow receipt and a fresh online
gate evaluation. The optional map is lead judgment, not verdict authority or proof that a concern
is unaffected. Never infer a finding closed from it. A missing map or unavailable host leaves
dispatch pending, not an empty required panel. The full diff remains available for context; do not re-ingest every
prior transcript. State which concern/range the verdict covers. For a design judgment between concepts you did not produce, report
compliance per concept, real tradeoffs and a recommendation; difference alone is not a defect.

End the report with exactly these last two lines, substituting your verdict and non-negative counts:

```text
Verdict: PASS
Counts: 0 critical, 0 high, 0 medium, 0 low
```
