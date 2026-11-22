# Migrating to 3.0

## Switch the review gate to GitHub approvals

1. On the trusted default branch, keep `review-host: github`, `review-publishers` (comma-separated
   `bot:<id>` or `user:<id>`) and `review-owner` (`user:<id>`). Look up numeric IDs with
   `gh api users/<login> --jq .id`. Remove `review-publisher-isolation`; its presence warns,
   and neither former value allows the PR author to approve.
2. Replace `publish-review.sh` calls with a normal pull request review submitted under the
   reviewer’s existing GitHub identity. When submitting via API, explicitly set `commit_id` to
   the inspected SHA. Remove receipt save/replay and `--review-plan` steps. No conversion or
   publisher credential setup is needed. Preserve reports that are still useful evidence.
3. Pin the kit on a clean upgrade branch. Run `init.sh --upgrade --dry-run`, then `init.sh
   --upgrade`. The installer reports once when retiring the old gate. Existing local receipt
   files are ignored and may be deleted; they are not approvals. No existing host review is edited.
4. On each open PR, obtain a fresh native approval for the exact head and run
   `check-review.sh --pr <url> --head <sha> <change-id>`. If `close-change.sh` creates a closing
   commit, push it and approve that SHA before merging. Require passing checks on that head.

The gate reads every page of the PR’s GitHub reviews. For each account listed in
`review-publishers` or `review-owner`, only its latest submitted review on the exact PR head
counts. At least one must be `APPROVED`. A later comment, dismissal or request for changes on
that head replaces the same account’s approval; a pending review does not. The PR author
never counts, even if listed. Commit authorship is irrelevant. Every new SHA needs approval,
including a rebase, an empty commit and a record-only closing commit.
