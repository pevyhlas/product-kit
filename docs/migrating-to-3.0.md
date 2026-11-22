# Migrating to 3.0

Stay on the pinned 2.0.x kit, its required check and its receipt publisher until you
can complete the cutover below. Installing files does not change branch protection.

Only the review evidence changes. Keep the **2.x tier minimums**: no approval
for T0; at least one independent `review-publishers` approval for T1–T3; and
also a `review-owner` approval for T3. An ID in both lists is an owner only.
The PR author counts for neither role. Even T0 requires a successful live gate.
As in 2.x, a new commit does not clear an objection. An eligible reviewer’s
`CHANGES_REQUESTED` on any commit of the PR blocks until that reviewer approves
the exact current head in a later submission, or an owner/maintainer dismisses
the objecting review itself on GitHub. A comment is not clearance.

**Before installing:** identify the protected branch's actual rule. This guide
uses a source-bound **required workflow**, not a required status-check name. Confirm
in a sandbox that the merge owner can rerun the exact required workflow, including
a previously green run, and that protection uses its new attempt. Assign an owner
for each review change and the final pre-merge rerun. Read the [rerun procedure
and stale-approval window](ci-gates.md#refresh-the-required-verdict). If you have
only automatic PR dispatch, cannot control when merges occur, use a merge queue,
or cannot accept that window, stay on 2.0.x. An ordinary review-triggered job is
not a substitute for the required workflow.

## Prepare both checks

1. Record the working 2.0.x kit commit, consumer installation commit (including the
   manifest), trusted policy, publisher invocation, and protected branches’ ruleset
   requirements and workflow source identities. Keep the trusted publisher available
   for rollback. Do not copy its credentials into a PR or the kit.
2. On the trusted default branch keep `review-host: github`, `review-publishers`,
   `review-owner` **and `review-publisher-isolation` with its valid 2.0 value**. Keep
   publishing receipts while 2.0 is required, including for the installation PR.
   The 3.0 gate warns about the isolation key but accepts its presence. Use independent
   numeric `bot:<id>`/`user:<id>` publisher accounts or personal `user:<id>` owners.
   The PR author never counts in 3.0, even if listed or if 2.0 uses `shared`.
3. Stage a distinct, trusted 3.0 check alongside the still-required 2.0 check on the
   target branch. Follow the [all-PR execution contract](ci-gates.md#trusted-all-pr-execution--check-pr-reviewsh).
   Give each check a distinct identity and name. The stock launcher loads its gate
   from the **current default branch’s installed files**, not the candidate pin.
   A second job pointing at that same installation is not a parallel version. Before
   updating the default installation, ensure the old job can still run its complete
   trusted 2.0.x verifier and publisher from a separately pinned source against
   current consumer policy. Verify the actual versions both jobs execute. If your
   integration cannot keep both working independently, stay on 2.0.x.
4. Use **two commits on the same upgrade branch and PR**. Start from a clean
   consumer checkout with the trusted default branch fetched. Set `KIT_REV` to
   the selected released 3.0 tag. First commit **only the gitlink**:

   ```bash
   git -C .product-kit fetch --tags
   git -C .product-kit checkout --detach "${KIT_REV:?set the released kit tag}"
   git add -- .product-kit
   git commit -m "Pin Product-Kit $KIT_REV"
   ```

   Check `git status --porcelain` is empty. A staged or unstaged pin is still a
   dirty checkout. From the clean pin commit, run the preflight, then apply:

   ```bash
   bash .product-kit/scripts/init.sh --upgrade --dry-run &&
     bash .product-kit/scripts/init.sh --upgrade
   git status --short
   ```

   Stop on any error. Inspect the install diff and manifest, then stage the
   reviewed changes (including newly installed and retired files) and commit them
   as the **second commit**. Land both commits together through the old protected
   route. Keep old receipt data during the rollback window; 3.0 ignores it.
   No host review is modified by installation.

## Prove enforcement on one pilot PR

Use a disposable T1 PR targeting the actual protected branch, with a valid change record
and otherwise passing checks. Do not merge it. In the active ruleset **add** the trusted
3.0 required workflow for that target while 2.0 remains required. Verify the source
identity and no-bypass policy (not just a display name). Check the merge requirements
on the PR as well as the Actions log. Keep its head SHA `H` fixed. Publish any
necessary 2.0 receipt **before** testing the native approval: the old publisher
posts a `COMMENTED` review, which supersedes that account’s earlier approval on `H`.

| Action | Evidence to record for `H` |
| --- | --- |
| Open the PR without an eligible approval. | The new required check runs and fails for missing approval; branch protection lists it as blocking. |
| Have an independent non-author publisher submit `APPROVED` on `H` (`commit_id: H` when using the API). The reviewer or owner reruns all jobs of the required run. | Record the new attempt of the **same run**, the live approval and host pass on `H`. Confirm protection accepts that attempt. |
| Dismiss that approval, leaving no qualifying approval. The dismisser or owner reruns **the previously green run** without a push. | Record the incremented attempt, its failure on `H`, and the protected PR blocking again. The earlier green result must no longer satisfy the rule. |

Save the PR, review, run ID and attempt numbers, and ruleset evidence. Opening,
reopening or synchronizing a PR triggers the required workflow; review changes
require the explicit rerun above. A shell invocation or optional job is not proof.
If the new attempt is not bound to the trusted source and reflected in protection,
**stop the cutover**; retain the old requirement. Remove a failed staged
requirement only after confirming the old one is still enforcing.

## Switch and retire

After the pilot, confirm the 3.0 requirement is active on every intended target.
Only then remove the 2.0 requirement, retire or repurpose the old publisher, remove
`review-publisher-isolation` from trusted policy, and drop receipt replay and
`--review-plan` steps. Keep `review-publishers` and `review-owner`. For each account,
only its latest submitted review on the exact PR head counts toward approval. A pending review
does not count; a later submitted comment, dismissal or changes request on that
head supersedes its approval. Commit authorship is irrelevant. Obtain the tier’s required approvals for
each open PR’s current SHA, including any new SHA created by `close-change.sh`.

## Roll back to 2.0.x

Keep the enforcing 3.0 requirement during rollback. Restore the recorded 2.0.x
trusted verifier/workflow, publisher and valid trusted 2.0 policy (including the
isolation key) through the protected route. Stage the old check again. On a test PR,
publish fresh 2.0 evidence for that PR using the old publisher; verify the old
receipt check rejects missing evidence and accepts valid evidence. A 3.0 approval
or a saved local file alone is not a 2.0 receipt.

Reinstate the recorded 2.0 requirement alongside 3.0 and verify the ruleset
actually blocks on the old check. Then remove the 3.0 requirement. Restore the
exact 2.0.x gitlink, installed files and manifest from the recorded consumer commit
via a reviewed revert, preserving subsequent project-owned changes. Verify the
restored installation and required receipt check on the protected target before
retiring the staged 3.0 workflow. If 2.0 cannot enforce, keep 3.0 enforcing and
leave the rollback incomplete; never disable both checks to land a revert.
