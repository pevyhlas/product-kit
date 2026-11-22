# Migrating to 3.0

Stay on the pinned 2.0.x kit, its required check and its receipt publisher until you
can complete the cutover below. Installing files does not change branch protection.

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
4. On a clean upgrade branch pin the released 3.0 kit; run
   `bash .product-kit/scripts/init.sh --upgrade --dry-run`, then the same command
   without `--dry-run`. Inspect and commit the pin, installed files and manifest.
   Land the installation through the existing protected route. Old receipt files
   may stay on disk: 3.0 ignores them and reports their retirement once. Keep them
   during the rollback window. No host review is modified by installation.

## Prove enforcement on one pilot PR

Use a disposable PR targeting the actual protected branch, with a valid change record
and otherwise passing checks. Do not merge it. In the active ruleset **add** the trusted
3.0 workflow/check for that target while 2.0 remains required. Verify the source
identity and no-bypass policy (not just a display name). Check the merge requirements
on the PR as well as the Actions log. Keep its head SHA `H` fixed. Publish any
necessary 2.0 receipt **before** testing the native approval: the old publisher
posts a `COMMENTED` review, which supersedes that account’s earlier approval on `H`.

| Action | Evidence to record for `H` |
| --- | --- |
| Open the PR without an eligible approval. | The new required check runs and fails for missing approval; branch protection lists it as blocking. |
| Have an eligible non-author submit a normal `APPROVED` review of `H` (`commit_id: H` when using the API). | `pull_request_review: submitted` starts a fresh evaluation; the **same required check** passes on `H`. |
| Have an authorized user dismiss that approval, leaving no qualifying approval. | `pull_request_review: dismissed` starts another evaluation without a push. It fails and the ruleset blocks again; the earlier green run no longer satisfies it. |

Save the PR, review, run and ruleset evidence. PR open/reopen, synchronize, retarget/edit
and draft/ready transitions also trigger checks. A shell invocation, an optional job,
or a dismissal that leaves the old green result effective is not proof. If the host
does not deliver those events to the enforcing check or cannot bind it to the trusted
source, **stop the cutover**; retain the old requirement. Remove a failed staged
requirement only after confirming the old one is still enforcing.

## Switch and retire

After the pilot, confirm the 3.0 requirement is active on every intended target.
Only then remove the 2.0 requirement, retire or repurpose the old publisher, remove
`review-publisher-isolation` from trusted policy, and drop receipt replay and
`--review-plan` steps. Keep `review-publishers` and `review-owner`. For each account,
only its latest submitted review on the exact PR head counts. A pending review
does not count; a later submitted comment, dismissal or changes request on that
head supersedes its approval. Commit authorship is irrelevant. Obtain approval for
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
