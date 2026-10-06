# rols on top of ols

`rols` is a fork of [DanielGavin/ols](https://github.com/DanielGavin/ols) on branch `rols`, based on `upstream/master`.
`git log upstream/master..HEAD` is the authoritative diff; this file records only what the code cannot mark itself.

## Conventions

- Fork-only `.odin` files carry the `rols_` prefix: `ls src/server/rols_* tests/rols_*`.
- Every fork region in an upstream file starts with a `// rols: …` line: `grep -rn '// rols' src tests`.
- Config keys, LSP requests, README sections and scripts are listed in this file, in the same commit that adds them.
- Sync with upstream through the `rebase` skill in `.claude/skills/rebase`.

## Fork-only non-Odin files

- `install.sh`
- `docs/corpus-validation.md`: the corpus sweep, its failing tests, follow-ups and rerun steps
- `docs/corpus/`: the sweep reports, the triage list with one reduced repro per case, and the triage runners
- `tools/cli_smoke.sh`
- `tools/corpus_smoke.sh`
- `tools/invert_if_smoke.sh`
- `tools/save_imports_smoke.py`
- `misc/claude-plugin/`: `.claude-plugin/plugin.json`, `.lsp.json`, `skills/ols/SKILL.md`
- `CLAUDE.md`
- `FORK.md`
- `.claude/skills/rebase/SKILL.md`

Whole fork-only package: `src/cli`.
Its `ols query rename-package` command runs the engine in `src/server/rols_rename_package.odin` and writes through `run_edit`, whose transaction renames the directory after the files are written; `tools/cli_smoke.sh` covers it.
Its `ols query attr` commands (`src/cli/rols_attr.odin`) run the engine in `src/server/rols_attr_edit.odin`, which edits the attributes where the source writes them, and write through `run_edit`; `tools/cli_smoke.sh` covers them.
Its `ols query modernize` command (`src/cli/rols_modernize.odin`) runs the engine in `src/server/rols_modernize.odin` and writes through `run_edit` in `src/cli/rols_apply.odin`; `tools/cli_smoke.sh` covers it.
The `migration` rules of that command, which rewrite deprecated or removed Odin forms, live in `src/server/rols_modernize_migrate.odin` and have no lint or config key; `tools/cli_smoke.sh` covers `base-imports`.
The compile gate of `run_edit` also checks the importers of each touched package, directly or through other importers, found by `importer_dirs` in `src/server/rols_rename_package.odin` with a visited set, so an import cycle ends. It warns when the check before the write already reports errors in a directory. For `rename` and `rename-package`, it matches an existing error with the old name replaced by `replace_word` in `src/server/rols_rename_check.odin`, only on a line that an edit of the rename changes (`edited_lines` in `src/cli/rols_gate.odin`). `error_key` keys a `Different package name` error by its two names sorted. `tools/cli_smoke.sh` covers all of it.
The gate checks other build targets: `gate_targets` in `src/cli/rols_gate.odin` returns one `Gate_Check` per target. It adds a `-target:` value for each file that the current target does not build (`target_for_file` in `src/server/rols_check_targets.odin`, which uses `file_name_target` and `match_build_tags`) among the touched files, the other files of their directories and the files of every importer directory. That check covers the directories of the files that need the target and their importers (`importer_dirs`), a subset of the packages the current target checks, so `checked` in the summary still counts packages. The existing key `checker_targets` adds its targets to those, each checking every package (`target_name` accepts only the candidates). Verified with `odin` dev-2026-09 on a macOS host with no SDKs: `odin check -target:T` accepts 19 targets (every candidate and `windows_i386`, `freestanding_amd64_win64`), and `tools/cli_smoke.sh` checks a windows-only file that imports `core:sys/windows` on `windows_amd64`. An importer directory with no file for the current target checks clean on the host (odin exits 0 with no output), so it needs no special case. `server.check` takes a `timeout` argument, default `CHECK_TIMEOUT` (20 s, the editor check); the gate passes 20 s for each batch of cores packages, capped at 10 minutes (`gate_check_timeout`).
`with_variants` in `src/cli/rols_gate.odin` adds one `Gate_Check` on the current target per `checker_variants` entry, whose `args` `check_errors_for` appends to `checker_args`. When the check after the write finds new errors, `run_edit` restores the files, checks the original code again with `recheck_checks` (the checks and directories whose error files, kept by `check_errors`, name a file of a new error), merges that result into the baseline with `union_errors`, writes the edit again (`write_edit`), and when new errors remain runs every check once more (the second check covers every package, like the baseline it is compared with) and keeps only the errors both runs after the write report (`intersect_errors`); `tools/cli_smoke.sh` covers it with a fake `odin_command`.
Its `recipe` rules, parsed from the `modernize_recipes` config key, live in `src/server/rols_modernize_recipe.odin` and share the pattern matcher of `src/server/rols_pattern.odin` with the use_stdlib lint; `tools/cli_smoke.sh` covers one.
Its `find` command runs `find_symbols` in `src/server/rols_find.odin`, which reads every `.odin` file of the workspace instead of asking the index, so it reports private declarations and those of other targets with flags; it scans the identifiers of each file first and parses only a file where one passes the fuzzy matcher. `inactive_when_decls` in `src/server/rols_when_inactive.odin` adds the declarations of a `when` branch that the editor's `when` evaluation rules out, only where every condition up to the active branch uses names the evaluator knows, and `find` marks them like those of other targets while `find_tests` drops them. A condition the file's own constants cannot decide reads the constants of the other files of the package (`When_Package`), and `fold_plain_consts` folds each constant after the ones it names. `find_symbols` and `find_tests` evaluate `ODIN_OS` and `ODIN_ARCH` for the `-target:` of `checker_args` through the thread-local `when_target` (`set_when_target`). `workspace_package_dirs` in `src/server/rols_find.odin` lists the package directories that `check` and `tests` cover without an argument; `package_dirs_below` walks a directory that the workspace filter skips without the filter. `find_tests` in `src/server/rols_tests.odin` keeps the files that `builds_on` accepts for the target of `checker_args`, else the host, and for a single file only its tags (`tags_build_on`), as `odin test FILE -file` does. `check` exits `1` on an error-severity diagnostic, and `test` refuses a name that `find_tests` does not list. `collect_lints` in `src/cli/rols_cli.odin`, which `lint` and `check` share, drops the files of a directory that the workspace filter skips unless the filter skips the directory itself, and `lint` builds that filter once (`workspace_lint_filter`) for its directory walk too. `lint` notes a file that does not parse on stderr and still reports its lints. `tools/cli_smoke.sh` covers all of it.

Confirm with `git diff --name-status upstream/master..HEAD | grep '^A' | grep -v '\.odin$'`.

## Hook points in upstream files

Registration:

- `src/server/action.odin`: `action_procs` table plus the fork action run, package file collection for cross-file actions, the shared edit builder and the import edits organize-on-save reuses.
- `src/server/requests.odin`: `call_map` entries for the fork handlers.

Config:

- `src/common/config.odin`: range formatting, extra inlay hint kinds, fork code action, lint, lens and checker flags, workspace filter keys, client file-creation support.
- `src/server/types.odin`: the same flags as `Maybe(bool)` in `OlsConfig`, and the workspace glob lists.
- `src/server/requests.odin`: initialize-option merge for those flags, and `apply_default_config` holding every default so the CLI can reuse them. Each `checker_skip_packages` entry is also stored with symlinks resolved.

Capabilities:

- `src/server/requests.odin`: initialize response: range formatting, fork action kinds and providers, the hint kinds that turn the provider on, organize-on-save and file-creation client support.
- `src/server/types.odin`: capability and payload types for the fork requests, server-initiated request payloads, the `CreateFile` and `RenameFile` document changes, and the named response union that lets `workspace/applyEdit` be sent.

Workspace filter (`src/common/rols_workspace_filter.odin`), applied to workspace symbols (directories only), the reference file list behind references, rename, change signature, incoming calls, code lens and the CLI, and the checker's fallback package list:

- `src/server/workspace_symbols.odin`: the package walk skips filtered directories.
- `src/common/util.odin`, `src/common/util_windows.odin`: `search_for_odin_files` takes the filter, and `run_executable` spawns under `process_spawn_lock`.
- `src/server/references.odin`: `workspace_odin_files` builds a filter per workspace root.
- `src/server/build.odin`: `append_packages` takes the filter.
- `src/server/check.odin`: the fallback package list for workspace diagnostics filters each root, and `odin check` spawns under `process_spawn_lock`.

CLI:

- `src/main.odin`: `ols query` dispatch and the reused logger.
- `src/server/rename.odin`: `get_rename` takes the files that stand in for the workspace walk, for the tests.
- `src/server/when.odin`: `resolve_when_ident` reads `ODIN_OS` and `ODIN_ARCH` from `when_target_ident` first, so `find` and `tests` evaluate `when` for the `-target:` of `checker_args`; `host_target` in `src/server/build.odin` reads the same `when_target`.
- `src/server/references.odin`: `resolve_references` passes those files on.
- `src/server/rename.odin`: `get_rename` takes its locations from `resolve_references`, which adds the platform variants of a package-level declaration (`declaration_variants` in `src/server/rols_variants.odin`); `reorder_params` and the safe-rename check use the same variants.
- `src/server/references.odin`: `find_symbol_references` takes `variants`, matches a reference to any of them like one to the symbol, and adds each variant's declared name once. `resolve_references` passes the variants of a package-level declaration unless the search is limited to the current file, so the references request and rename share them.
- `src/server/check.odin`: `start_check_process` takes its command line from `check_command` in `src/server/rols_check_args.odin`, which drops repeated flags (checker_args wins), and `check` passes each error through `check_error_severity` in `src/server/rols_check_severity.odin`, which parses the file to tell the hard `declared but not used` error from the `-vet-unused-variables` warning. `split_checker_args` splits `checker_args` on whitespace; a quoted text with whitespace groups and loses its quotes, other quotes and backslashes stay literal (odin reads `-define:T="x"` with the quotes in the value). `src/server/rols_check_style.odin` holds the style rerun: when a process with a style flag (`-vet-style`, `-vet-semicolon`, `-vet-tabs`, `-strict-style`) reports a Syntax Error or the `-vet-tabs` finding, `check` queues the same package again without those flags (`pending_reruns`, budget doubled to `2 * timeout`), unless `has_real_syntax_error` finds that a file a Syntax Error names does not parse with rols' parser either, and `merge_style_rerun` keeps the first run's errors that the rerun did not report with type `style`, which `check_error_severity` maps to warnings. A process that a signal killed before it printed anything (`child_exit_signal` in `src/server/rols_check_crash.odin` and `rols_check_crash_windows.odin`, a `waitid` peek before `os.process_wait` reaps the child, since core:os stores the signal in `exit_code`) is logged, marked `crashed` and queued again once (`retry`) in the same budget; `record_check_run` skips a crashed process, so only a second crash fails the check. `gate_config` in the args file is what the compile gate of `ols query --apply` checks with: no vet flags, `-max-error-count:100000`. `test_command` in `src/server/rols_tests.odin` drops repeated flags the same way. README "Command line queries" lists the contract, including the exit `1` of `ols query check` for a check that did not run.
- `src/server/check.odin`: notes each process's exit status and records whether every package check ran to a parsed result, so the refactor compile gate of `ols query` can tell no errors from a check that did not run, and records per package check path the files its errors name, so the gate can drop a package on an extra target when its baseline errors lie outside the workspace.

CI:

- `ci.sh`: self-lint gate, `ols query lint src/server --fail-on …`, after the build.

Rewritten procs:

- `src/server/response.odin`: all four senders frame through `write_message`; ids for server-initiated requests.
- `src/server/lens.odin`: `textDocument/codeLens` handler and the budgeted reference sweep.
- `src/server/file_resolve.odin`: heap-allocated symbols in upstream's resolve cache arena so the map can hold pointers.
- `src/server/references.odin`: reference search callable without a cursor, and the shared file list the code lens uses.
- `src/server/action_invert_if_statements.odin`: takes an `ActionContext`, offers the early-exit variant, keeps labels, do-bodies and indentation.
- `src/testing/testing.odin`: selection sources, a shared document fixture, a checker stand-in serialized by `seed_mutex` for the parallel runner, and the `expect_*` assertions for the fork features.

Small fixes:

- `src/server/analysis.odin`: `@(deprecated)` sets the deprecated flag.
- `src/server/locals.odin`: no preallocation for name groups.
- `src/server/symbol.odin`: symbols stored by pointer in the resolve map.
- `src/server/ast.odin`: end positions for `break` and `continue`.
- `src/server/ast.odin`, `src/server/symbol.odin`, `src/server/collector.odin`, `src/server/completion.odin`, `src/server/build.odin`: the index also keeps the declarations of `when` branches the host does not build, flagged `Fallback`, so code in such a branch resolves a type that another file declares in one. `collect_when_stmt` collects them on the index path only, `collect_symbols` stores a fallback only under an absent name and lets an active declaration replace it, and completion, fake methods, ObjC class members, `ols query api`, `pkg.NAME` in `when` conditions, the lints in code the host builds (through `lint_symbols`) and the unused-declaration lint skip them. The lints in `resolving_lints` (`src/server/rols_lint.odin`) skip inactive branches and files the host does not build, where a name can resolve to the host's declaration. A fallback that another declaration hides waits in `SymbolPackage.hidden_fallbacks`, and `index_file` and `remove_index_file` give it the name back when that declaration goes (`restore_hidden_fallbacks` in `src/server/rols_when.odin`). `internal_resolve_type_identifier` and `resolve_location_identifier` in `src/server/analysis.odin` set a fallback aside through `lookup_active` (`src/server/rols_when.odin`) and return it only when the builtins miss too.
- `src/server/indexer.odin`: `lookup` reuses the package and uri of the last file it ran for.
- `src/server/build.odin`: drop stale symbols on removal and reindex.
- `src/server/generics.odin`: keep procedure tags and the diverging flag when solving a generic.
- `src/server/writer.odin`: framed write of one message.
- `src/server/diagnostics.odin`: fork producers, a file-private mutex, and the merge that runs under the lock.
- `src/server/document_symbols.odin`: a value declaration, a compound literal or `#config` included, is a Variable when mutable and a Constant otherwise; the literal's field map lives in temp memory.
- `src/server/hover.odin`: struct layout and field offsets.
- `src/server/inlay_hints.odin`: fork hint kinds, enclosing procedure tracking, and a resolve context built only when a kind needs it.
- `src/server/check.odin`: never block the request thread, drain the pipe incrementally, reap killed processes, vet findings as warnings, and a `Syntax Error` that `-json-errors` types as a warning, such as a missing import path, as an error.
- `src/server/documents.odin`: reject a change before touching the document, refresh lint diagnostics.
- `src/server/position_context.odin`, `src/server/file_resolve.odin`: a call argument drops the enclosing comp literal, so a comp literal in the argument resolves against the parameter type.
- `src/server/signature.odin`: inside a comp literal passed to a call, the comp literal signature comes before the procedure signature.
- `src/server/analysis.odin`: `resolve_implicit_selector` resolves an implicit selector inside a comp literal on the right of an assignment against the literal, not against the assigned name.
- `src/server/analysis.odin`: `expand_call_args` passes the member of `offset_of(T, member)` without a symbol, so a member named like a package keeps the two-argument overload.
- `src/server/file_resolve.odin`: the `offset_of` member resolves to the field of T, and struct and bit_field field names are not resolved as identifiers.
- `src/server/references.odin`: the `offset_of` member is a reference to its field.
- `src/server/imports.odin`: `find_unused_imports` counts an import as used only where the file names its package, not where a value of one of its types appears, and never reports an `@(require)` import.
- `src/server/file_resolve.odin`: the where clauses of a union and the paths of a foreign import are resolved, so a package named only there counts as used.
- `src/server/analysis.odin`: `resolve_slice_expression` gives a slice an anonymous type, so hover and "Add explicit type" print `[]int` for `s.arr[:2]` where upstream printed the field name.
- `src/server/requests.odin`: the Odin root lookup runs `<workspace>/odin` only when it is a file, so a package directory named `odin`, such as `core/odin`, is not run.
- `src/server/locals.odin`: `get_local` skips a local for a name in another top-level declaration of the file (`in_local_top_level_decl` in `src/server/rols_resolve.odin`), so the initializer of a global does not see the locals of a procedure that uses the global.
- `src/server/analysis.odin`: `resolve_function_overload` caches each result, failures included, with the `OverloadMode` it resolved in (`src/server/rols_resolve.odin`), and ignores a cached result of another mode. The in-progress marker hits in every mode. A tie between members whose results differ picks no member when the call result is wanted (`top_candidates_agree`).
- `src/server/analysis.odin`, `src/server/file_resolve.odin`: the whole-file resolve sets `whole_file_resolve` on its `AstContext`, and `resolve_function_overload` then drops a member that takes fewer arguments than the call passes. Completion and signature help keep every member, as upstream does.
- `src/server/hover.odin`: hover on the callee of a group call that picks no member, such as a tie between different results, shows the group.
- `src/server/analysis.odin`: `get_proc_return_types` resolves the callee of a call that a builtin such as `max` returns against that call, so a group member is picked by its own arguments.

Tests:

- `tests/action_invert_if_test.odin`: the early-exit variant and the fork behaviour.
- `tests/inlay_hints_test.odin`: the fork hint kinds.
- `build.sh`: `single_test` checks the status of `odin test` itself, so it exits 1 when `odin test` fails, as `test` does. The environment variable `ROLS_TEST_TIMEOUT=SECONDS` bounds `test` and `single_test`: `odin test` runs in its own process group, which gets SIGKILL on timeout, and the run exits 1. Unset means no limit. Set it lower than any outer timeout, because an outer kill of the `build.sh` process group does not reach the test group.

## Changed upstream defaults

Set in `apply_default_config` in `src/server/requests.odin`, and in `misc/ols.schema.json` and README.md:

- `enable_comp_lit_signature_help`: true, upstream false.

## Changed upstream formatter output

The fork formatter differs from upstream OLS in these cases. Each has a `tools/odinfmt/tests/rols_*.odin` snapshot, except the first, which edits an upstream snapshot, and the last, which a snapshot covers only through the others.

- `tools/odinfmt/tests/random/.snapshots/demo.odin`: a one-line block followed by a trailing comment (`for !did_acquire(&print_mutex) {thread.yield()} // Allow one thread ...`) loses the tab upstream prints before the comment. The tab came from the Indent comment option leaking from the opening brace to a comment after the closing brace (stage S19). The user approved this snapshot change.
- A one-line block of `;` joined statements that does not fit opens a normal block (`rols_when_block_semicolon_line`).
- A `;` joined line after the first line of a block breaks at its `; ` when it does not fit, and a statement between two `; ` counts in full when the line is measured (`rols_semicolon_line_wraps_after_first_line`, `rols_semicolon_line_over_width_late_statement`).
- A one-line `if` or `when` with `;` joined statements in both blocks breaks both blocks when either one does not fit (`rols_if_else_one_line_else_overflows`).
- A block comment before an item on its line, such as a struct field, a parameter, an argument, an enum or union member, a composite literal element or an expression, stays before the item with one space after it. Upstream prints it as a trailing comment of the previous token, which moves it to its own line or drops the space after it. A struct field's alignment counts the comment (`rols_block_comment_first_item`, `rols_block_comment_after_line_comment`, `rols_block_comment_later_item`).
- A comment on the operator's line in a binary chain stays on that line, and a comment above the first call argument stays above it (`rols_idempotent_binary_trailing_comment`, `rols_idempotent_call_arg_comments`).
- `odinfmt` prints a trailing line comment with a space before it even when the document queued it without one (`flush_line_suffix` in `src/odin/printer/document.odin`).

## Changed odinfmt exit status

`odinfmt FILE` exits 1 and prints `Failed to format FILE` when the file does not parse. Upstream prints the parse error and exits 0 with empty stdout, so `odinfmt f > tmp && mv tmp f` empties the file. The `-w`, `-stdin` and directory modes already exited 1. Every `Failed to …` error line now ends with a newline. `tools/odinfmt/tests.sh` checks the exit status and output of the stdout, `-w` and `-stdin` modes.

## Fork-only config keys

Regenerate with:

```bash
diff <(git show upstream/master:misc/ols.schema.json | grep -o '"enable_[a-z_]*"' | sort -u) <(grep -o '"enable_[a-z_]*"' misc/ols.schema.json | sort -u) | grep '^>' | tr -d '>" '
```

### `enable_code_action_*` (29)

- `enable_code_action_add_explicit_type`
- `enable_code_action_add_ok_result`
- `enable_code_action_checker_fix`
- `enable_code_action_comment`
- `enable_code_action_defer_delete`
- `enable_code_action_do_block`
- `enable_code_action_expand`
- `enable_code_action_extract_constant`
- `enable_code_action_extract_procedure`
- `enable_code_action_extract_variable`
- `enable_code_action_fill_struct`
- `enable_code_action_generate_proc`
- `enable_code_action_generate_test`
- `enable_code_action_if_to_switch`
- `enable_code_action_inline_proc`
- `enable_code_action_inline_variable`
- `enable_code_action_introduce_param`
- `enable_code_action_literal`
- `enable_code_action_loop_label`
- `enable_code_action_merge_cases`
- `enable_code_action_move_decl`
- `enable_code_action_named_results`
- `enable_code_action_remove_param`
- `enable_code_action_result_handling`
- `enable_code_action_result_union`
- `enable_code_action_rewrite_expression`
- `enable_code_action_split_merge_if`
- `enable_code_action_ternary`
- `enable_code_action_unwrap`

### `enable_lint_*` (31)

- `enable_lint_allocator`
- `enable_lint_bool_logic`
- `enable_lint_call_arity`
- `enable_lint_core_misuse`
- `enable_lint_dead_store`
- `enable_lint_deprecated`
- `enable_lint_float_equality`
- `enable_lint_identical_branches`
- `enable_lint_ignored_result`
- `enable_lint_imports`
- `enable_lint_integer_range`
- `enable_lint_invisible_characters`
- `enable_lint_loops`
- `enable_lint_naming`
- `enable_lint_no_op`
- `enable_lint_printf`
- `enable_lint_pure_call`
- `enable_lint_recursion`
- `enable_lint_redundant_type_assertion`
- `enable_lint_result_order`
- `enable_lint_self_assignment`
- `enable_lint_simplify`
- `enable_lint_struct_literal`
- `enable_lint_switch`
- `enable_lint_sync`
- `enable_lint_test_attribute`
- `enable_lint_unreachable_code`
- `enable_lint_unused_declaration`
- `enable_lint_unused_parameter`
- `enable_lint_unused_variable`
- `enable_lint_use_stdlib`

### `enable_checker_*` (7)

- `enable_checker_strict_style`
- `enable_checker_vet_cast`
- `enable_checker_vet_semicolon`
- `enable_checker_vet_shadowing`
- `enable_checker_vet_style`
- `enable_checker_vet_tabs`
- `enable_checker_vet_unused_variables`

### `enable_inlay_hints_*` (4)

- `enable_inlay_hints_comp_lit_fields`
- `enable_inlay_hints_constant_values`
- `enable_inlay_hints_range_types`
- `enable_inlay_hints_variable_types`

### Other (6)

- `enable_code_lens_references`
- `enable_hover_struct_size`
- `enable_organize_imports_on_save`
- `enable_range_format`
- `enable_selection_range`
- `enable_workspace_gitignore`

### Non-flag keys

The regenerate command above lists only `enable_*` keys.

- `workspace_exclude`
- `workspace_include`
- `checker_variants`: extra `checker_args` for one more compile gate check each, on the current target. It has no `enable_*` flag: an empty list adds no check.
- `modernize_recipes`: user rewrite rules of `ols query modernize`. It has no `enable_*` flag: recipes run only when configured, and only from the CLI command.

## Fork-only LSP requests

Client-to-server, added to `call_map`:

- `textDocument/rangeFormatting`
- `textDocument/foldingRange`
- `textDocument/selectionRange`
- `textDocument/implementation`
- `textDocument/prepareCallHierarchy`
- `textDocument/codeLens`
- `callHierarchy/incomingCalls`
- `callHierarchy/outgoingCalls`

Server-to-client:

- `workspace/applyEdit`: sent by `src/server/rols_save_imports.odin` for organize-imports on save.

Confirm with `git diff upstream/master..HEAD -- src/server/requests.odin | grep '^+.*"textDocument/\|^+.*"callHierarchy/\|^+.*"workspace/'`.

## Fork sections in README.md

- `## Command line queries`, including the refactor dry run, `--apply` transaction with directory renames, the packages and build targets the compile gate checks (`checker_targets`), `--no-check`, exit codes, symbol path targets, the rename refusals, `rename-package` and `attr`
- `### Claude Code`

The fork's option bullets in README are the config keys listed above.
