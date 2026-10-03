# Brief: write FAILING regression tests for confirmed rols bugs

## Goal
Add one test per assigned case so that each test **fails today** because of the bug and **will pass once the bug is fixed**. Do NOT fix any bug. Do NOT commit, push or create branches. Work only inside your worktree (given in your prompt).

## Inputs
- Case list: /tmp/rols-corpus/triage/TRIAGE.md (your group's table). The exact reproducing source of each case is in /tmp/rols-corpus/triage/<case>/ (inlay cases: triage/inlay_<case>/a.odin). Source reports: /tmp/rols-corpus/findings-{A,B,C,D}.md.
- Read the worktree's CLAUDE.md first. Key rules: tests use the OLS harness in `src/testing` (never a separate runner); fork test files are `tests/rols_*_test.odin`; do not add tests to upstream (non-`rols_`) test files. Look at the existing `rols_*_test.odin` file of the same feature and copy its style (Source, `{*}` cursor, `{[ ]}` selection, `files`, `packages`, `config`, `collections = {"core" = "test"}` + inline BUILTINS for multi-package tests).
- Use the `lsp` MCP (lookup_symbol with root_dir = your worktree) to find harness procs and the feature code you need to understand; read files only for what lookups do not return.

## Rules for each test
1. Put it in the existing `tests/rols_<feature>_test.odin` that matches the feature when one exists, else in a new `tests/rols_corpus_<area>_test.odin`. Only touch the files your prompt assigns to your group.
2. Name it after the correct behavior, e.g. `dead_store_ignores_package_global`. Start each test with a one-line comment `// Corpus: <project> <file:line or "reduced">, see docs/corpus-validation.md.`
3. Assert the CORRECT behavior with the matching `expect_*` proc (for "no false lint", assert the exact expected diagnostics list, usually empty for that code). Use the smallest source from the triage dir.
4. Run `./build.sh single_test <name>` and confirm it **compiles and fails on its assertion**, with a message that shows the bug. A compile error is not acceptable.
5. If the harness cannot reproduce a case (it passes today because the bug lives outside the harness path, e.g. temp memory freed by the request loop, or the CLI), do not keep a passing test: drop it and report the case as "not harnessable" with the reason.
6. Hangs and crashes must not block the suite. For a case that hangs or segfaults, first check what the Odin test runner does with `testing.set_fail_timeout` and with a crash. If `./build.sh test` cannot still complete and report the other tests, wrap such tests in `when ROLS_HANG_TESTS { ... }` with `ROLS_HANG_TESTS :: #config(ROLS_HANG_TESTS, false)` (declared once, in the file that needs it) and say so in the report, with the exact command to run them (`./build.sh single_test NAME -define:ROLS_HANG_TESTS=true` or whatever works; check build.sh).
7. Format the files you touched with odinfmt (`./odinfmt.sh` builds it; config odinfmt.json) only if the repo formats tests that way; match the neighbouring file.

## Final checks
- `./build.sh single_test <all your test names comma-separated>`: every one fails on its assertion.
- `./build.sh test`: completes; the only failures are your new tests. Report the summary line.

## Report (your final message, as text)
For each case: test name, file, one-line failure message observed, or "not harnessable: <reason>". Then the `./build.sh test` summary line, and the list of files you changed.
