# Troubleshooting

| Symptom | Next action |
|---------|-------------|
| Public commands unavailable | Run the installer for the selected harness; or ask the agent to read `.prdkit/workflows/protocol.md` |
| Missing workflow or template | `/prdkit-doctor`, then inspect `init.sh --check` before reinstalling |
| Doctor or init: "needs a cutover" / 0.x layout | Between changes, run `/prdkit-init`; see [migrating to 1.0](migrating-to-1.0.md) |
| Doctor: two canons | Finish the cutover (`compact.md`, Cutover): condense `specs/product-spec/`, `specs/targets/` and `specs/features/` into the spec and `specs/archive.md`, turn a feature the owner keeps open into a change record, then `git rm` them |
| Doctor: archive on main | Condense `specs/archive/` into `specs/archive.md` and remove it with `git rm` (`compact.md`, Restructure); git keeps the files |
| Doctor: `specs/archive.md` has no readable Last line or Base commit; `new-change.sh` stops: "an old feature number could be reused" | Write `**Base**: <sha>` (the main commit the cutover started from) and `**Last 0.x feature**: <NNN, or none>` as in `archive-template.md`, or pass `--number` |
| Doctor: agent context names removed 0.x paths | Point `CLAUDE.md`/`AGENTS.md` at the current spec, and history questions at `specs/archive.md`; qualify another repository's path as `owner/repo:path` |
| CI fails: a kit helper such as `check-artifacts.sh` not found | 1.0 removed it: `init.sh --check` lists each call under RETIRED; replace it ([migrating](migrating-to-1.0.md)); a `check-signoff.sh` step becomes `check-review.sh` ([CI gates](ci-gates.md)) |
| Doctor: undefined or retired ID cited | Fix the citation, or retire the test that still cites a retired line in the same PR |
| Doctor: malformed record | Each `specs/records.md` line is `TYPE id key=value … — reason`; the template comment lists the keys |
| Doctor: file over its reading budget | Tighten the wording or split the file ([spec.md](../workflows/spec.md), Layout); never drop an item to fit, never pad up to a budget |
| Doctor: a spec file "is reached from no summary" | Give it a line and a link in its parent (the file it was split from, or `architecture.md` for a topic or `retired.md`); a retired file needs `retired:` in its heading |
| Doctor: a stage "runs in none of the environments" | Name the environment in the stage's **Environment** line as `specs/architecture/environments.md` spells it, or add a row for it there; `none` suits a stage with nothing running |
| Doctor: "Link at … points to …, which does not exist" | Fix the path; name a file removed from main on purpose as code, `git show <sha>:<path>`, not as a link |
| Doctor: closed without a `specs/log.md` line | Add `- <date> <id>: <what changed>` to `specs/log.md` in the PR that deletes the change record |
| Doctor: local machine path | Rewrite it relative to the repository, or as `org/repo` plus a path for another repository |
| Doctor: raw evidence under `specs/` | `git rm --cached` it, keep it under `.prdkit/cache/evidence/`, and link it from Acceptance |
| The owner's answer was asked for again | Record owner words relayed verbatim in `specs/inbox.md` with date and source; they need no re-asking |
| The same check keeps failing | After three attempts, or two without new information, stop: alternatives note in the change and NEEDS_DECISION in the inbox |
| A typo, rejected patch or local setup error | Fix it and continue; it is no attempt or fix round and grants no extra authority |
| Verification timed out without a verdict | A failed tool run is not a product FAIL; rerun within existing authority, never past an owner limit or hold |
| Independent reviewer unavailable | Arrange a distinct context or human; review stays pending |
| Tests pass but the change cannot close | Live acceptance items need a real run; a green PR does not pass an acceptance item |
| Merged but not live | Deployment is a separate claim: look for a `DEPLOY` record in status |
| Missing usage numbers | Provide optional documented enrichment, or accept unknown usage |
| `new-change.sh`: branch already exists | Continue it (`git checkout <id>`) or choose another short name |
| Harness cannot enter or resume a worktree | A worktree directory was removed without `git worktree remove`; run `.prdkit/scripts/bash/cleanup-change.sh --prune` |
| Finished change worktree lingers | From the main checkout, run `.prdkit/scripts/bash/cleanup-change.sh <change-id>` |
| Agent context file huge, slow costly turns | Keep `CLAUDE.md`/`AGENTS.md` to orientation and pointers within `context-budget-bytes` |
| Old `/prdkit-*` commands or helpers still installed | Run `init.sh --upgrade`; it removes kit files no longer shipped (`--check` lists them as RETIRED) |
| Upgrade kept an edited retired template | Fold what you need into the constitution or a 1.0 template, then delete it |
| A helper exits 2: resolved root has no `.prdkit/` | Run the installed copy under `<project>/.prdkit/scripts/bash/` from a project whose Git root holds `.prdkit/` |
| `init.sh` exits 2: unknown harness, or the list would drop a recorded one | Separate names with commas or spaces and keep every recorded harness; see [removing a harness](harnesses.md#removing-a-harness) |
| Slash commands missing in a change worktree; `new-change.sh` warns that links do not resolve | The install uses `--symlink` and the worktree lacks the kit: run the `git submodule update --init` it names, or switch once with `init.sh --upgrade --copy` and commit |
| Doctor or gate: kit-named command not recorded in the manifest | Re-run `init.sh --upgrade` with the full `--harness` list, or remove the file |
| Agent definition: `'harnesses:' must be a bracketed list` | Write `harnesses: [opencode]` (or `[claude, opencode]`), or delete the line |
| Agent projection is unowned | Add a neutral definition and run `render-agents.sh`, remove the file, or list it under `Hand-owned agents:` in `.prdkit/memory/agents.md` |

Status and doctor are read-only. Neither repairs files or grants execution authority. Doctor
advisories never fail it unless `--strict` is passed. For interrupted work, ask
`/prdkit continue`; it checks actual repository state and the change's State.
