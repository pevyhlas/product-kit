<!--
Open this pull request as a draft. Only the maintainer merges, and review is best effort.
For anything beyond a small fix, open an issue first and agree on the change there.
-->

## What and why

Closes #

## Checklist

- [ ] Opened as a draft, and linked to its issue above (a small fix may skip the issue)
- [ ] `bash tests/run.sh` passes
- [ ] `git diff --check 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD` prints nothing
- [ ] `find scripts tests -name '*.sh' -print0 | xargs -0 shellcheck --exclude=SC1091` is clean (ShellCheck 0.11.0)
- [ ] Stays generic: no project-, product- or stack-specific vocabulary or hard-coded build commands in `commands/`, `workflows/` or `templates/`
