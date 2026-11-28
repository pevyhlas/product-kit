# Troubleshooting

| Symptom | Next action |
|---------|-------------|
| Public commands unavailable | Run the installer for the selected harness; or ask the agent to read `.prdkit/workflows/protocol.md` |
| Missing workflow or template | `/prdkit-doctor`, then inspect `init.sh --check` before reinstalling |
| Doctor or init: unsupported spec layout or install manifest | Use the current layout and manifest format named in the error. The kit does not convert older installations. |
| Doctor: undefined or retired ID cited | Fix the citation, or retire the test that still cites a retired line in the same PR |
| Doctor: malformed record | Each `specs/records.md` line is `TYPE id key=value … — reason`; the template comment lists the keys |
| Doctor: file over its reading budget | Tighten the wording or split the file ([spec.md](../workflows/spec.md), Layout); never drop an item to fit, never pad up to a budget |
| Doctor: a spec file "is reached from no summary" | Give it a line and a link in its parent (the file it was split from, or `architecture.md` for a topic or `retired.md`); a retired file needs `retired:` in its heading |
| Doctor: a stage "runs in none of the environments" | Name the environment in the stage's **Environment** line as `specs/architecture/environments.md` spells it, or add a row for it there; `none` suits a stage with nothing running |
| Doctor: "Link at … points to …, which does not exist" | Fix the path; name a file removed from main on purpose as code, `git show <sha>:<path>`, not as a link |
| Doctor: closed without a log entry | Add `.prdkit/history/log/<id>.md` holding `- <date> <id>: <what changed>` in the PR that deletes the change record |
| `close-change.sh`: “could not create the hard link” | Check the `ln` error. If the filesystem does not support hard links in `.prdkit/history/log/`, move the checkout to one that does and retry the same close. The record is still open; no log entry needs cleanup. |
| Status or doctor: missing, blank or duplicate State field | In `## State`, give `**Waiting on**:` and `**Next**:` one nonblank line each. For examples, use a fence or start an HTML comment on its own line. Inline `<!--` is ordinary field text. |
| Doctor: malformed log entry | Make `.prdkit/history/log/<id>.md` one line, `- <date> <id>: <what changed>`, naming the change its file name gives |
| Old history paths remain | Move them with the `git mv` commands in the diagnostic and commit the move. Refresh stale worktrees and integration refs before allocating or closing a change |
| Doctor: close row over 200 characters | Keep intent, IDs and parts, disposition, and PR. Leave details on the PR |
| Status or doctor: merged without closing | Close the non-specified record in the next relevant PR, carried by that PR's record before final review ([review workflow](../workflows/review.md#review-carrier)). Editing Step only on the implementing branch does not change the default-branch check. |
| Doctor: specified with no open tasks | Close it in this PR with `close-change.sh`, or change Step in a reviewed edit. |
| `close-change.sh`: specified and still has open tasks | Finish and delete the remaining task lines, or change Step in a reviewed [owner disposition](../workflows/review.md#closing). An open checkbox line anywhere, even in a comment or code example, blocks closing until removed. |
| Doctor: local machine path | Rewrite it relative to the repository, or as `org/repo` plus a path for another repository |
| Doctor: raw evidence under `specs/` | `git rm --cached` it, keep it under `.prdkit/cache/evidence/`, and link it from Acceptance |
| The owner's answer was asked for again | Fold the answer into the canonical spec/policy with its words, date and source; then remove the resolved inbox item. Relayed verbatim answers need no re-asking |
| The same check keeps failing | After three attempts, or two without new information, stop: alternatives note in the change and NEEDS_DECISION in the inbox |
| A typo, rejected patch or local setup error | Fix it and continue; it is no attempt or fix round and grants no extra authority |
| Verification timed out without a verdict | A failed tool run is not a product FAIL; rerun within existing authority, never past an owner limit or hold |
| Independent reviewer unavailable | Arrange a distinct context or human; review stays pending |
| Tests pass but the change cannot close | Live acceptance items need a real run; a green PR does not pass an acceptance item |
| Merged but not live | Deployment is a separate claim: look for a `DEPLOY` record in status |
| `new-change.sh`: branch already exists | Continue it (`git checkout <id>`) or choose another short name |
| Harness cannot enter or resume a worktree | A worktree directory was removed without `git worktree remove`; run `.prdkit/scripts/bash/cleanup-change.sh --prune` |
| Cleanup refuses an unsupported layout or filesystem | Embedded stores, submodules with dependent linked worktrees, and stores that borrow objects may need relocation first. The admin and checkout must support a rename to the common Git directory on the same filesystem. `--force` only relaxes cleanliness. |
| Cleanup reports `prdkit-retired/<slot>` | In the main checkout, inspect `git log refs/prdkit-retired/<slot>/HEAD` (replace `<slot>` with the reported directory name). `git show refs/prdkit-retired/<slot>/index:<path>` reads a staged file. Inspect uncommitted files under `checkout/` and submodule refs and reflogs with `git --git-dir=<slot-path>/admin/modules/<name> --work-tree=. reflog show --all`. |
| Ready to purge a slot | First preserve any needed files and commits outside that slot and its refs. List its exact refs with `git for-each-ref --format='%(refname)' refs/prdkit-retired/<slot>/`; delete each confirmed ref with `git update-ref -d <full-ref>`, then manually delete only that quarantine directory. Cleanup never purges it. |
| Retirement refused before moving | Never clean a worktree in use or during Git garbage collection. Stop writers, finish merges or rebases, resolve index conflicts, and commit an unborn branch first. If evidence is linked, preserve it separately and replace the link with an ordinary path before retrying. |
| Interrupted after the final admin rename | If the slot contains `admin/` and `git worktree list --porcelain` no longer lists the checkout, verify `git rev-parse --verify "$ns/HEAD^{commit}"` and `git rev-parse --verify "$ns/index^{tree}"` from the main checkout, where `ns=refs/prdkit-retired/<slot>`. If both resolve, **leave the slot retired**; moving back `checkout/` alone would break its Git pointer. Inspect staged and working files as above. |
| Interrupted with a locked registration still listed | Stop writers and confirm cleanup has exited. Match the registration's `gitdir` and `locked` with the slot's `lock-reason`. For a `.retiring` registration set `holding` to its full path, `original` to its original admin path (strip the timestamp and random suffix from the slot name), `slot` to the reported directory, and `path` to the original checkout path. For a moved live checkout, first verify **both** destinations are unused, including dangling links, then restore the pair: `mv "$holding" "$original" && mv "$slot/checkout" "$path"`. If the admin is already at its original path, restore only the moved checkout. Verify `git -C "$path" status --short`, the staged content and the working files. Remove only an empty `prdkit-cleanup.lock` left by this run, then `git worktree unlock "$path"` from the main checkout. Keep the slot and refs until recovery is verified. |
| Interrupted `--prune` with a locked `.retiring` registration and no checkout | Identify the registration and slot as above. Confirm both `"$path"` and `"$slot/checkout"` are absent. Restore **only the admin**: `test ! -e "$original" && test ! -L "$original" && mv "$holding" "$original"`. From the main checkout, verify `git --git-dir="$original" rev-parse --verify 'HEAD^{commit}'` and `git --git-dir="$original" ls-files --stage`; inspect staged content with `git --git-dir="$original" show :<file>`. If verification succeeds, remove only this run's leftover empty lock with `rmdir "$original/prdkit-cleanup.lock"` if present. Run `git worktree unlock "$path"`, then `.prdkit/scripts/bash/cleanup-change.sh --prune`. |
| Finished change worktree lingers | From the main checkout, run `.prdkit/scripts/bash/cleanup-change.sh <change-id>`, or `cleanup-change.sh --closed` for every closed change's worktree (needs `origin/HEAD`: `git remote set-head origin --auto`) |
| `cleanup-change.sh` says git refused the removal | The message carries git's reason, such as a locked worktree (`git worktree unlock <path>`); uncommitted changes are reported as such. Submodules alone never block it |
| `cleanup-change.sh --closed` leaves a closed change's worktree | It removes only the layout `new-change.sh` creates, `.worktrees/<id>` on branch `<id>`. Remove any other worktree by id |
| Agent context file huge, slow costly turns | Keep `CLAUDE.md`/`AGENTS.md` to orientation and pointers within `context-budget-bytes` |
| `--check` reports retired kit files | Run `--upgrade` from a clean checkout. Review the kept files and update any tracked references to removed files. |
| A helper exits 2: resolved root has no `.prdkit/` | Run the installed copy under `<project>/.prdkit/scripts/bash/` from a project whose Git root holds `.prdkit/` |
| `init.sh` exits 2: unknown harness, or the list would drop a recorded one | Separate names with commas or spaces and keep every recorded harness; see [removing a harness](harnesses.md#removing-a-harness) |
| Slash commands missing in a change worktree; `new-change.sh` warns that links do not resolve | The install uses `--symlink` and the worktree lacks the kit: run the `git submodule update --init` it names, or switch once with `init.sh --upgrade --copy` and commit |
| Doctor or gate: kit-named command not recorded in the manifest | Re-run `init.sh --upgrade` with the full `--harness` list, or remove the file |
| Agent definition: `'harnesses:' must be a bracketed list` | Write `harnesses: [opencode]` (or `[claude, opencode]`), or delete the line |
| Agent projection is unowned | Add a neutral definition and run `render-agents.sh`, remove the file, or list it under `Hand-owned agents:` in `.prdkit/memory/agents.md` |

Status and doctor are read-only. Neither repairs files or grants execution authority. Doctor
advisories never fail it unless `--strict` is passed. For interrupted work, ask
`/prdkit continue`; it checks actual repository state and the change's State.
