# Follow-ups

Known gaps and out-of-scope issues found during fork work. Each entry names where the issue is and a case that shows it. Remove an entry when its fix lands.

## Corpus validation (`docs/corpus-validation.md`)

- **A sweep over seven open-source Odin projects and Odin's core found bugs that are not fixed yet.** `docs/corpus-validation.md` lists them. 52 have a failing test in `tests/rols_*`, so `./build.sh test` reports 52 failures until they are fixed. One more test hangs today and runs only with `-define:ROLS_HANG_TESTS=true`: the code-action hang on calls of procedures with a default parameter. Three odinfmt snapshot cases named `rols_*` fail in `tools/odinfmt/tests.sh`. The doc's 37 follow-ups have no harness test and each names a repro. `docs/corpus/triage/` holds the reduced source of every confirmed case, and `python3 docs/corpus/triage/cli.py` reruns the CLI cases.
- **Rerun the sweep after the fixes land.** Follow "Rerunning the sweep" in the doc: run `tools/corpus_smoke.sh`, then the manual checks it lists. Remove fixed items from the doc and this entry when nothing is left.

## Safe-rename check (`src/server/rols_rename_check.odin`)

- **Rename is skipped in inactive `when` branches.** `get_locals` in `src/server/locals.odin` takes only the `when` branch it evaluates as active. A local declared in an inactive branch has no symbol, so `ols query rename` on it reports "no symbol to rename at the position".
- **A field rename can capture a name inside a `using` procedure.** Given `limit :: 10` and `f :: proc(using foo: Foo) -> int { return limit }`, renaming `Foo.x` to `limit` passes the check. After the rename, `limit` in `f` means the field. `check_captures` returns early for `.Field` targets.
- **Nested blocks of a `using` procedure are not checked.** The reverse check in `check_embedders` compares the new field name only with the top-level scope of a procedure with a `using` parameter. A local of that name in a nested block is missed.
- **Only direct embedders are checked.** `check_embedders` checks structs with a `using` field of the renamed field's type. It does not check structs that embed those structs in turn.
- **`using` statements are not checked.** A `using x` statement inside a procedure body brings members into scope, and neither the collision scan nor the capture scan covers it.
- **Field renames cost a workspace scan.** Every rename of a field in a named struct runs `find_symbol_references` on the owner type across the workspace, plus one type resolution for each `using` field found.

## Unwrap code action (`src/server/rols_action_unwrap.odin`)

- **"Remove redundant else" still has the old unsafe checks.** `add_remove_else` checks only the `if` itself, as the `redundant-else` simplify rule did before `3d6c7ced`. On `if a { return } else if b { return } else { x = 1 }`, the action on the inner `if` moves `x = 1` after the whole chain. On `if a { return 1 } else { return 2 }` followed by `return 0`, it leaves code after a return. It also accepts a labeled `if`, a `when` body, and an else that redeclares a name from earlier in the block. The guards in `simplify_redundant_else` in `src/server/rols_simplify.odin` cover these cases.

## CLI refactor output (`src/cli/rols_cli.odin`, `src/cli/rols_apply.odin`)

- **`actions --apply` skips `refuse` when the file cannot be opened.** `open_target` calls `refuse` only when `symbol_paths` is set, which `run` sets for rename, reorder-params and move. `ols query actions missing.odin:1:1 --apply TITLE` prints the plain `cannot read` line and exits 1, with no `actions: refused, nothing written` summary and no JSON object under `--json`.
- **`workspace_relative` states its inside-the-root test twice.** The raw comparison and the symlink-resolved comparison each repeat `err == nil && !strings.has_prefix(rel, "..")`. One loop over the two pairs of root and file would state the test once. The prefix test also misreads a file named `..x.odin` at the root as outside it.
- **The `.Refused` summary in `finish` can be shorter.** Two one-line appends and one `tprintf` with "nothing written" as the fallback for an empty list would replace the outer `if`/`else`, about 8 lines fewer.

## Result-union action (`src/server/rols_action_result_union.odin`)

- **Rewriting the result list drops comments and joins lines.** `named_results_edit` writes out the whole list when it names unnamed results or splits a shared last field. Comments inside the list are lost, and a multi-line list ends up on one line. The named-results action avoids this by editing only the names (`db49088f`).
- **A comment before the first result breaks the edit.** `result_list_range` in `src/server/rols_action_named_results.odin` steps back over whitespace only, so it never reaches `(` after a comment such as `-> (\n\t// first\n\tint, Error)`. The replaced range then starts at the first type, and the edit leaves an extra `(`. This comes from reading the code. No test reproduces it yet.

## CLI compile gate (`src/cli/rols_apply.odin` `run_edit`)

- **Only direct importers are checked.** `importer_dirs` in `src/server/rols_rename_package.odin` returns the packages that import a touched package. Given `a` imports `b` and `b` imports `c`, an edit in `c` checks `b` and not `a`. `odin check` on `b` does not check `a`, so a break that reaches `a` through a type that `b` re-exports passes the gate.
- **Only the host build target is checked.** `odin check` runs once with the current target. A file with `#+build windows` or a `_js.odin` suffix is not compiled on another host, so an edit that breaks it passes the gate. There is no multi-target check.
- **The 20 s timeout is shared, not scaled.** `server.check` gives every package one wall-clock budget. An edit to a package with many importers can time out and be refused with exit 1 although each package alone checks in time.
- **The name rewrite can match an error about another symbol.** After a rename, `new_errors` rewrites the old name to the new name in the leftover before errors. An existing error about an unrelated identifier with the old name then cancels a new error with the same text about the new name. This happens only after the unchanged key fails to match.
- **`scan_import_dirs` leaks one string per relative import.** `path.dir(file)` in `src/server/rols_rename_package.odin` uses `context.allocator`, and `importer_dirs` calls the scan for every workspace file. Pass `context.temp_allocator`.
- **`importer_dirs` repeats work on large workspaces.** It calls `canonical_dir(dir)` once per file of a directory that does not import a target, because `seen` is set only on a match. It also tests each import with `slice.contains(targets, …)`. A map of canonical dirs and a map of targets remove both costs, which matter for a whole-workspace `modernize --apply`.
- **An importer with no file for the host target may refuse the edit.** If `#+build` tags or name suffixes exclude every file of an importer directory, `odin check` there may fail without JSON, and `record_check_run` in `src/server/rols_check_run.odin` would then refuse the whole edit. This comes from reading the code. A smoke case with an importer guarded by `#+build windows` would settle it.
- **The importer smoke case asserts only the exit code.** The `imp/` case in `tools/cli_smoke.sh` checks exit 4 and the restored file. It does not assert the `rolled back, … 2 packages checked` summary, and no `--json` case shows the warning in `reasons` or the count in `summary`.
- **`new_errors` repeats its matching loop.** Both passes take errors from a count map in the same way. One helper that returns the unmatched errors would state the loop once, about 8 lines fewer.

## `do` bodies (`src/server/rols_edit.odin` `block_inner_text`)

- **The identical-branches lint flags `do` branches that differ.** For a `do` body, `open` is the statement start and `close` is its end, so `block_inner_text` returns the statement without its first character. `lint_identical_branches` in `src/server/rols_lint.odin` does not check `uses_do`, so `if c do foo()` followed by `else do goo()` compares `oo()` with `oo()` and reports `identical-branches` on code that passes `odin check`.

## Test harness (`build.sh`)

- **A test hung instead of failing on a reversed slice.** Before c5c8fa27, `./build.sh single_test invert_if_early_exit_do_body` spun at 100% CPU for 10 minutes until it was killed. The test build keeps bounds checks on, so the slice `src[p+1:p]` should have panicked at once. The cause is unknown.

## Whole-file resolve (`src/server/file_resolve.odin`)

- **The `Call_Expr` case restores the wrong value into `position_context.call`.** Its `defer` sets `data.position_context.call = old_call`, but `old_call` holds `data.ast_context.call`, not the previous `position_context.call`. After a nested call, the walker may treat later nodes as part of the wrong call.
- **A failed overload resolution is cached for the rest of the file.** `resolve_function_overload` stores an empty result in `ast_context.call_expr_recursion_cache` before it expands the call arguments, and a failure leaves it there. Every later resolution of the same call returns that failure. The parameter-length `make` hang was one trigger and is fixed at its cause (parameters are now stored before body locals). Another failing argument still poisons the call.
- **The whole-file resolve now allocates its temp memory from the document cache arena.** This keeps the cached symbols valid after the request frees temp memory. It also retains the resolve scratch until the document is reparsed or caches are invalidated. Measured `symbol_cache_arena.total_used` after `resolve_entire_file`: 23.9 MB without the swap and 29.1 MB with it for a 100 KB file (+5.2 MB, +22%), and 57.7 MB and 70.5 MB for a 250 KB file (+12.9 MB, +22%). A targeted copy of the escaping data (`pkg` strings, docs, synthesized nodes such as `wrap_pointer`) would remove the extra share. It needs an audit of every default `context.temp_allocator` that a cached symbol can point to.
- **Inlay hints on a very large file are slow.** Over stdio, one inlayHint request took about 1 s on a 100 KB synthetic file, about 3 s on 250 KB, and did not answer within 15 s on 2 MB. The memory is about 520 MB and 790 MB for the first two. The growth was not profiled. Repro: repeat `p :: proc(m: int, s: ^S) -> int { c := one(); d := make([]u8, m) ... }` with unique names.
