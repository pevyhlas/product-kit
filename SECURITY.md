# Security policy

Product-Kit is experimental and has one maintainer. Security reports are welcome and are handled
on a best-effort basis.

## Supported versions

Only the latest release receives security fixes. A fix ships as a new release; earlier
versions are not patched.

## Reporting a vulnerability

Report vulnerabilities privately. Do not open a public issue, discussion or pull request for one.

- **Preferred:** GitHub's private vulnerability reporting. Open the repository's **Security**
  tab and choose **Report a vulnerability**
  (<https://github.com/pevyhlas/product-kit/security/advisories/new>).
- **Or email** productkit@petrvyhlas.com.

Include the affected version or commit, what an attacker could do, how to reproduce it, and a
suggested fix if you have one. Share only what the report needs: no real secrets or private
project data.

## What to expect

- An acknowledgement within 7 days.
- An assessment, and for a confirmed vulnerability a fix in a new release as soon as the
  maintainer can make one. The advisory is published with or after the fix, and credits you
  unless you prefer otherwise.

This is a solo maintainer's best effort, not a guaranteed service level. If you have heard
nothing after 7 days, send a reminder through the other channel.

## Scope

In scope:

- Scripts that run in a consumer's repository or its CI: everything `scripts/init.sh` installs
  under `.prdkit/scripts/`, and the installer itself. This includes how they handle content from
  pull requests, change records, specs or other input an outside contributor can control.
- Installed templates, command files and agent workflows (`templates/`, `commands/`,
  `workflows/`), for example an instruction that leads an agent to leak data, execute untrusted
  input or weaken a project's review or CI gates.
- This repository's GitHub Actions workflows (`.github/workflows/`) and their release tooling
  (`scripts/maintainer/`).

Out of scope:

- Vulnerabilities in agent harnesses, models, GitHub or other third-party tools; report those to
  their vendors. If Product-Kit's files make one exploitable, that part is in scope.
- A consumer project's own code, CI configuration and constitution.
- Attacks that already need write access to the consuming repository or a shell on the machine.
