# Follow-ups

Known gaps and out-of-scope issues found during fork work. Each entry names where the issue is and a case that shows it. Remove an entry when its fix lands.

## Corpus validation (`docs/corpus-validation.md`)

- **A sweep over seven open-source Odin projects and Odin's core found bugs that are not fixed yet.** `docs/corpus-validation.md` lists them. No bug has a failing test any more: `./build.sh test` and `tools/odinfmt/tests.sh` report no failures. The doc's 11 follow-ups have no harness test and each names a repro. `docs/corpus/triage/` holds the reduced source of every confirmed case, and `python3 docs/corpus/triage/cli.py` reruns the CLI cases.
- **Rerun the sweep after the fixes land.** Follow "Rerunning the sweep" in the doc: run `tools/corpus_smoke.sh`, then the manual checks it lists. Remove fixed items from the doc and this entry when nothing is left.

## Edits (stage S9)

- **Only the simplify and use-stdlib rules skip a range that holds a comment.** `lint_fixes`, `migration_fixes` and the recipe fixes in `rols_modernize.odin` still replace their range without looking for comments, so a comment inside can be deleted. `comments_overlapping` in `rols_action_comment.odin` is the shared check.
- **A type-switch binding is probably not refused by `slice_arg_text`.** In `switch v in u { case [3]int: … }` the value `v` is likely not addressable without `&`, but the check does not look for it. Unverified.

## Lints (`src/server/rols_lint*.odin`)

- **Dead-store silences an assignment followed by a bare `return` for every local, and ignores deferred closures.** `dead_store` cannot tell a named result from a plain pre-declared local, so `x = 1; if c { return }; x = 2` stays silent for a plain local `x`. A `defer` closure that reads a named result is not seen.
- **A bare-bool or numeric constant is not named-checked.** `is_enabled :: true` is classified as an alias, so no naming rule applies. `count :: 5` still must be SCREAMING_SNAKE_CASE.
- **Allocator mismatch recognises `make([dynamic]T, …)` and `make(map[K]V, …)` only by the written type.** `Array :: [dynamic]int` followed by `make(Array, …)` is still recorded as a plain allocation.
- **The ignored-result proc-type check and `compares_non_bool` build a fresh `AstContext` per hit.** `names_proc_type` in `src/server/rols_lint.odin` runs only for `Err`-named results, and `compares_non_bool` in `src/server/rols_simplify.odin` for comparisons with `true` or `false`. `LintContext` could carry the walker's context instead.
- **`bool-compare` keeps the comparison for every non-`bool` boolean operand.** `compares_non_bool` in `src/server/rols_simplify.odin` also keeps `if b32_value == true`, where dropping it is harmless. It judges identifiers, selectors and single-result calls only.
- **`empty-body` still reports a scan loop whose work sits in the post statement.** `for ; i < len(path) - 1 && path[i] != '/'; i += 1 {}` in `core/os/path_linux.odin:29` is reported. Only a procedure call in the condition is exempt.
- **`unused-parameter` sees value uses of a procedure only in its own file.** `value_names` in `rols_lint.odin` walks the open file once. A handler that another file of the package registers still reports. Closing the gap needs a scan of the package's indexed files, so the lint would pay that cost for each file it checks. A same-named local that resolves to a procedure also counts as a use, and a mention that resolves to a variable does not.
- **The printf multi-value expansion resolves plain procedures only.** `expanded_arg_count` in `src/server/rols_lint_printf.odin` counts one argument for a call through a procedure group or an unresolved callee.
- **ignored-result no longer flags a declared poly result.** Judging `orig_return_types` means `proc(x: $T, $E: typeid) -> (T, E)` instantiated with an `Error` is not reported.
- **printf type checks stop at the first multi-value call.** `lint_printf` skips every argument from `spread_at` on. Mapping each format index to its expanded result would keep later arguments checked.
- **printf misses a surplus after `*[n]`, and over-counts `{:*d}`.** `aprintf("%*[1]s", "ab", 6, 7)` is silent, but core:fmt reports `%!(EXTRA 7)`: any index below the argument count that is not in `used` is extra. `{:*d}` reads the same argument for `*` and the value in core:fmt, while the lint asks for two.

## Safe-rename check (`src/server/rols_rename_check.odin`)

- **Field renames still read every workspace file.** `check_embedders` passes `require_text = "using"` to `find_symbol_references`, so a file is parsed only when it mentions both the owner type and `using`. The search still reads every file to test that. On 200 files that mention the type, the dry-run `ols query rename` of a field took 0.50 s before and 0.33 s after. A cached word index of the workspace would remove the reads.
- **`using` statements are found only in files that name a carrying type and contain `using`.** `check_using_statements` reads the documents `check_embedders` collects. A `using x` where `x` gets its type from a call, in a file that never names the type, is not checked.
- **Field captures skip uses that already resolve to a field, and alias embedders are missed.** `field_captures` skips a use of the new name that resolves to a `.Field`. Given `proc(using bar: Bar)` with `Bar.limit`, and then `{ using foo; _ = limit }` in its body, renaming `Foo.x` to `limit` misses the capture. `Alias :: Foo` with `using a: Alias` is not followed as an embedder; this predates S5.
- **Implementation requests on a procedure still run a workspace reference scan.** `proc_group_locations` in `src/server/rols_implementation.odin` calls `find_symbol_references`, which now skips a file that has no `proc` followed by `{` (`require_proc_group`), but still parses every other file that names the procedure. The measured gain was not taken on a large workspace.

## Edits (stage S10)

- **"Add ok result" refuses every caller shape it cannot extend.** It adds `, _` to `v := f()`, `v = f()`, `a, b := f()` and the `if` init form, leaves a statement call alone, and refuses the whole action for a call used as an argument, a return value, an `or_return` operand, a typed declaration, a named-argument call and a procedure used as a value. `#optional_ok` would keep most of those compiling but changes the result type the tests expect. A local procedure is refused when its name appears anywhere else in the file.
- **"Add ok result" does not look past the workspace.** `find_call_sites` reads the workspace files, so a caller in a package outside the workspace folders still breaks.
- **"Unwrap block" treats only a direct `return` or branch statement as terminating.** `unwrap_leaves_dead_code` in `src/server/rols_action_unwrap.odin` does not see `if c { return } else { return }`, `panic(...)` or `os.exit(...)` as a terminator, so unwrapping a body that ends that way can still leave unreachable statements. The action also refuses when `enclosing_stmts` finds no statement list, such as an `if` in an `else if` chain.
- **"Inline procedure call" refuses on any identifier match.** `borrows_from_file` in `src/server/rols_action_inline_proc.odin` does not track shadowing, so a parameter or local named like a file-private declaration or an import of the callee's file refuses the action. It does not add the missing import for the caller.
- **"Generate test" refuses a result whose zero value needs a package-qualified type.** `zero_values` in `src/server/rols_action_generate_test.odin` spells an aggregate as `T{}` because `testing.expect_value` cannot infer a bare `{}`. For `time.Time` the test file would need the import, so the action is withheld instead.
- **Slicing resolves to an anonymous slice type.** `resolve_slice_expression` in `src/server/analysis.odin` now clears the symbol's name and pointer count, so hover and "Add explicit type" print `[]int` for `s.arr[:2]` instead of the field name. The upstream test suite passes, but a client that read the old name from a hover will see a different text.
- **`rename-package` rewrites a bare package name only as the value of a declaration.** `alias :: old` is rewritten. Any other bare use of the name is left alone because it may be a field or a local.
- **`borrows_from_file` checks one direction.** A local, file-private declaration or import in the caller's file that shadows a package name the copied body uses is not detected. Same-file inlining had this gap before.
- **Generated `T{}` can still fail.** `testing.expect_value(t, x, T{})` does not compile when `T` is file-private in its source file or has slice or map fields, which are not comparable.
- **"Remove redundant else" is refused when the `if` is not the last statement of its block.** This follows from the guards shared with the simplify rule.
- **"Add ok result" refuses any procedure with `or_return`**, because `or_return` assigns the operand's end value to the last result and Odin rejects `Err` to `bool`.

## CLI queries (`src/cli/rols_cli.odin`, `src/server/rols_find.odin`)

- **`check` and `tests` in a directory without `.odin` files cover every package of the root, with one `odin check` per package.** The run gets the 20 s of an editor check for each batch of cores packages, capped at 10 minutes (`gate_check_timeout`), and the packages share no cache, so a large repository takes long.
- **`checker_skip_packages` compares the literal path.** The CLI resolves symlinks in its paths, so an entry that goes through a symlink such as macOS `/var` or `/tmp` never matches, and `ols query check` still checks the package. The smoke case `check-skipped-package` passed only because `check` always exited `0`.
- **`find` parses every workspace `.odin` file on each call.** The LSP workspace symbols read the index, which parses each package once. `find_symbols` reads all files again, so a call on a large tree such as Odin's `core/` costs one parse of the tree. A cache across calls does not help a one-shot CLI process.
- **`find` does not evaluate `when` conditions.** It reports a declaration in every branch of a `when` block, so the branch that the target does not take shows without a mark. The index evaluates the conditions it can.
- **`tests FILE` drops a file that the target does not build.** `odin test -file` may still build a file with `#+build` tags that exclude the host; this was not checked.
- **`test DIR NAME` checks the names against `find_tests` before it starts `odin test`.** An `@(test)` in a `when` branch counts whatever the condition, so a name from a branch that the target does not take passes the check and `odin test` then reports "No tests to run" with exit `0`.

## CLI compile gate (`src/cli/rols_apply.odin` `run_edit`)

- **The gate checks only the targets that touched files and target-less importer directories need.** A sibling file that the host excludes, such as `lib_windows.odin` next to an edited `lib.odin`, and the excluded files of an importer directory that also has a host file are not checked on their targets. A break there passes the gate unless `checker_targets` names the target.
- **Every extra target checks every package.** `gate_targets` in `src/cli/rols_gate.odin` returns one list, so a `_windows.odin` edit in a workspace with many importers runs all packages again for `windows_amd64`. Checking only the importers of the packages that need the target would cost less.
- **The rename rewrite uses lines, not columns.** `on_edited_line` in `src/cli/rols_gate.odin` lets a before error on a line the rename edits match the renamed form. An unrelated error on the same line still can. An error whose position is on another line of a multi-line call is not rewritten.
- **The style rerun ignores the concurrency cap and any genuine Syntax Error also pays for it.** `check` starts reruns beside the regular processes, and the whole run gets `2 * timeout` (not one extra per rerun). A file with a real syntax error always runs twice.

## Large-file performance (stage S15)

- **Opening a 2 MB file still takes 1.3 to 2.4 s.** On `core/rexcode/isa/ppc/mnemonic_builders.odin` (13,308 declarations), `didOpen` spends about 0.3 s parsing and about 2 s in `resolve_entire_file` for the lints. The stacks show no single hot spot: `clone_node`, `resolve_function_overload`, `create_uri` and `store_local` each hold a few percent. A request on that file after the open takes 0.2 s or less (codeAction 1.5 s total, documentSymbol about 1.6 to 2.1 s, inlayHint 1.8 s).
- **The whole-file resolve rebuilds an enum symbol for every use of the enum.** `make_symbol_enum_from_ast` walks every member (`get_enum_field_name_range_value`, `get_field_docs_and_comments`) on each use of an enum such as `Mnemonic`, so `didOpen` of the 55 KB `ppc/mnemonics.odin` takes about 3 s (sampled stacks: `make_symbol_enum_from_ast` under `resolve_selector_expression`). `ols query symbols` no longer pays this, since it opens the file without lints. A cache keyed by the enum node would have to live in the document cache arena.
- **Code actions still recompute `lint_fixes`, `simplifications` and `stdlib_matches` per request.** After the quadratic lint scans went, a code action on the 2 MB file costs 0.2 s or less beyond the open, so no cache was added. Revisit if a file with many more lint hits shows up.
- **`find` parses every workspace file once per call.** `find_symbols` in `src/server/rols_find.odin` took 0.22 to 0.27 s over this repository's 300 files. A text prefilter would have to follow the fuzzy matcher, so none was added.

## Test harness (`build.sh`)

- **A test that panics or faults never ends in the agent sandbox (found in S16).** `invert_if_early_exit_do_body` at `c5c8fa27^` printed `Invalid slice indices 61:60 is out of range 0..<83` and then spun at about 60% CPU, so the bounds check did panic. A scratch Odin test with a plain `panic("boom")` or an out-of-range index hung the same way. A C program whose `SIGSEGV` and `SIGTRAP` handlers run `write(2, "hit\n", 4); _exit(42);` printed nothing and was still spinning when a 10 s alarm killed it (exit 142), for a null write and for `__builtin_trap()`. So in the sandbox the handler is not reached, and the faulting thread re-traps forever. The same C program without handlers exits 139. The Odin runner relies on such a handler (`stop_test_callback` in `core:testing`) to learn that a test failed. `kill` (SIGTERM) does not end the run, because the first SIGTERM only sets a flag in the runner; a second SIGTERM calls `os.exit`, and `kill -9` on the `tests` process works. Outside the sandbox this was not tried, so it is not confirmed that the runner works there. The orphaned `tests` processes from earlier sessions (12 h old) are probably the same hang. A fix would kill the whole process group from `build.sh`; `perl -e 'alarm N; exec ...'` only kills `odin test`, not its `tests` child.
- **`for x in m[k]` over a map index loops forever when `k` is missing (Odin dev-2026-09).** S16 grepped `src/`, `tests/` and `tools/` for ranges over an index expression and found no remaining site over a map (`importer_dirs` was already rewritten; `untyped_map` and `diagnostics` are enum-indexed arrays, and the rest index slices or fixed arrays). `lint_loops` reports the pattern. Candidate upstream Odin issue, not filed. Repro:

  ```odin
  package main

  main :: proc() {
  	m := make(map[string][dynamic]string)
  	for d in m["x"] { _ = d } // never ends
  	l := m["x"]
  	for d in l {} // ends
  }
  ```

## Whole-file resolve (`src/server/file_resolve.odin`)

- **Other `position_context` fields persist across nodes in the whole-file walker.** `parent_binary`, `index` (with `previous_index`) and `field_value` are set while walking one node and never restored, so a later sibling can read a stale value. They were not audited.
- **A failed overload resolution is cached for the rest of the file.** `resolve_function_overload` stores an empty result in `ast_context.call_expr_recursion_cache` before it expands the call arguments, and a failure leaves it there. Every later resolution of the same call returns that failure. The parameter-length `make` hang was one trigger and is fixed at its cause (parameters are now stored before body locals). Another failing argument still poisons the call.
- **The whole-file resolve now allocates its temp memory from the document cache arena.** This keeps the cached symbols valid after the request frees temp memory. It also retains the resolve scratch until the document is reparsed or caches are invalidated. Measured `symbol_cache_arena.total_used` after `resolve_entire_file`: 23.9 MB without the swap and 29.1 MB with it for a 100 KB file (+5.2 MB, +22%), and 57.7 MB and 70.5 MB for a 250 KB file (+12.9 MB, +22%). A targeted copy of the escaping data (`pkg` strings, docs, synthesized nodes such as `wrap_pointer`) would remove the extra share. It needs an audit of every default `context.temp_allocator` that a cached symbol can point to.

## Overload resolution and hover (`src/server/analysis.odin`, `src/server/hover.odin`)

- **Equal overload scores pick the first member.** `ab(T1, nil)` with `a :: proc($tag: Tag, p: []u8)` and `b :: proc($tag: Tag, p: ^int)` scores both members -2, so hover takes `a`. This is right when the results agree, as in `hover_overload_with_poly_constant_param`, and wrong when they differ.
- **The layout offset of a promoted field resolves the `using` type in the hover's package.** `promoted_field_offset` in `src/server/rols_layout.odin` calls `resolve_type_expression` on the `using` field's type without switching to the package that declares it. A `using` field of a type from another package may not resolve, and then the hover shows no offset.
- **`comp_lit_inside_call` compares source offsets.** `src/server/rols_resolve.odin` decides that an implicit selector belongs to a comp literal when the literal starts after the call. Only `references_enum_in_comp_lit_argument` covers it, with a typed literal as the first argument.

## Build tags and `when` (`src/server/build.odin`, `src/server/when.odin`)

- **Files excluded for the host are not indexed, so a call from an excluded file resolves to the host's sibling.** The open file's own declarations win, and the call-arity and struct-literal lints treat an excluded file like an inactive `when` branch. Navigation from such a file still goes to the wrong platform's declaration (for example `socket_linux.odin` on darwin reaches `errors_posix.odin`). A fix would index excluded files per target.
- **Only `lint_calls` and `lint_struct_literal` skip code in inactive `when` branches.** Other resolution-dependent lints still run there and can resolve names to the active branch's declarations.
- **A `when` condition can read `pkg.NAME` only for a constant whose value folds to a bool, int or string.** Chains through other packages' constants and mutable globals are treated as unknown, which means false.
- **`#+build` project names are matched with an empty project name**, so a `#+build !name` line does not exclude anything.
- **`move_decl` compares the OS and architecture suffix of file names and the `#+build` lines literally.** Two spellings of the same constraint count as different, so the move is refused: `#+build linux, darwin` against `#+build darwin, linux`, or `#+build linux` against a `_linux.odin` name.
