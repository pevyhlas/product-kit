# Adopting an existing product

Install the kit and run `/prdkit-init`. Existing code is a baseline, not a request to rewrite
the product. The agent infers commands, structure and present behavior; it asks for purpose,
authority and uncertain product choices, and preserves the project's own policy and documents.

Start thin. The first `specs/product.md` states what is true now; inferred intent is
`hypothesis`, and code establishes observed behavior, not product purpose. `specs/architecture.md`
lists every part, but a part file is written only where real obligations exist; other parts
link their existing document as `legacy` until a change first touches them. A part has one
authority: its part file or its legacy document. Where existing documents contradict each
other or the code, the agent does not pick: it adds an inbox question citing both sources.

Then work in changes against what already works. Spec lines are added in the PR whose code
and tests realize them, so the spec grows only where it narrows real choices.

Long-lived consumers can check the adoption contract mechanically with the installed
[CI gates](ci-gates.md): the pinned kit revision, manifest and command surface
(`check-adoption.sh`), and optionally `doctor.sh --strict`.

A project already on Product-Kit 0.x follows [migrating to 1.0](migrating-to-1.0.md): upgrade,
then one cutover between changes.
