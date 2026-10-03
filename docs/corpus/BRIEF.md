# Sweep brief: validate the rols Odin language server on a real codebase

You test a fork of the Odin language server (OLS) called rols. Find crashes, wrong edits, false lints and wrong query results. You do not fix anything.

## Hard rules
- Never modify /Users/bogdan/Projects/odin/rols or /Users/bogdan/Projects/odin/rols-corpus. Read them only (README.md "Command line queries" section is the CLI contract; tools/save_imports_smoke.py shows how to drive the LSP over stdio).
- Work only inside /tmp/rols-corpus/<project> and /tmp/rols-corpus/scratch-<you>. Restore each project with `git checkout . && git clean -fd` between edit runs.
- Never `--apply` inside the Odin installation (`odin root`). It is read-only.
- Wrap every ols call in a timeout, e.g. `timeout 120` (use `gtimeout` if `timeout` is missing). A timeout is a finding.

## Tools
- Binary: /tmp/rols-corpus/bin/ols with `export OLS_BUILTIN_FOLDER=/tmp/rols-corpus/bin/builtin`. Formatter: /tmp/rols-corpus/bin/odinfmt.
- `odin` is on PATH (dev-2026-09).
- CLI: `ols query <cmd> ... [--root DIR] [--json]`. Positions are FILE:LINE:COL, 1-based, byte columns.

## Steps per project
1. Read the project's build script / README to find package dirs and collections. If it has no ols.json, write a minimal one at the project root (`{"collections":[{"name":"shared","path":"..."}]}` etc.) matching how it builds. Record what you wrote.
2. Baseline: `odin check <pkgdir> -no-entry-point` (plus needed `-collection:` flags) for each package. Record which pass. Only passing packages are used for edit checks.
3. Read-only queries, record exit codes, crashes, stderr panics and wall time:
   - `ols query check [DIR]` and `ols query lint DIR` per package. Sample lint hits (at least 15 per project) and judge each by reading the code: true or false positive?
   - `ols query symbols FILE` on every .odin file (loop). Any crash or non-zero exit is a finding.
   - `find`, `tests`, and `def`, `refs`, `hover`, `callers`, `impl` on ~20 varied positions (proc calls, struct fields, enum members, generic procs, package-qualified names, `using` fields, overload groups). Verify each answer by reading the source.
4. Edits (dry-run first, then `--apply` on the clone, then `odin check` yourself too; then restore):
   - `ols query modernize --diff` then `--apply` over the whole project. Read the diff for meaning changes.
   - 3+ `rename`s (package proc, struct field, local, enum member), 1 `move`, 1 `reorder-params`, 1 `rename-package` on a leaf package, 1 `attr rename` or `attr add` where sensible.
   - `actions FILE:LINE:COL[-LINE:COL]` at ~15 varied positions/selections; apply each offered action once (`--apply TITLE`) and check the result compiles and means the same.
   An edit that is refused for a documented reason is not a bug. An edit that is refused for no stated/valid reason, produces wrong code, rolls back (exit 4), or exits 1 unexpectedly is a finding.
5. LSP over stdio: write a Python driver in your scratch dir. initialize with rootUri = project, then for every file: didOpen, documentSymbol, semanticTokens/full, inlayHint (whole file), codeAction at 3 positions, formatting, and hover at 3 positions. Record crashes (process exit), error responses, and any request slower than 2 s.
6. Formatter: copy the project to scratch, run odinfmt on every file in place (check `odinfmt -h` for flags), then `odin check` the copy's packages. A newly failing package is a finding; reduce it to the offending file and construct.

## Report
Write /tmp/rols-corpus/findings-<you>.md with:
- Project commit, ols.json used, baseline pass/fail per package, timing.
- Findings, each with: class (crash | wrong-edit | false-lint | wrong-result | slow | improvement), exact repro command, observed vs expected, and the SMALLEST Odin snippet you could reduce it to (try hard to reduce: write it to scratch and confirm it still reproduces). Mark whether you confirmed the reduced repro.
- A short list of what passed cleanly.
Your final message: the path to the findings file and a one-paragraph summary with finding counts by class.
