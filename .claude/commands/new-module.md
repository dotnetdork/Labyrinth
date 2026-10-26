---
description: Scaffold a module from its spec — tests first, both platforms, following the module contract
argument-hint: <phase>/<module-name>
---

Scaffold the module `$ARGUMENTS`.

1. Find its spec in `docs/design/` and its row in `docs/Roadmap.md`. If the spec does not settle what the module does, stop and list the open questions.
2. Read the module contract (design 00) and `docs/Conventions.md` for the folder layout, `module.yml`, the six entry points, exit codes, logging, the manifest and approval items. Do not restate them here: follow the documents.
3. Look at an existing module or fixture module (`tests/fixtures/`) for the shape, and reuse `core/` for logging, the manifest, safety gates and probes.
4. Write the tests first, from the spec's acceptance-test list, in bats and Pester 5, including the negative test: protected accounts and scored services are untouched.
5. Then write the entry points for each platform the spec covers. `check`, `plan` and `verify` change nothing.
6. Add the module to its profiles only in the commit that builds it.
7. No secrets, addresses, hostnames or event values: only `*.example` templates with placeholders.

Reply with the files created and anything in the spec that the code showed to be unclear.
