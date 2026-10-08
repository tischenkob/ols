# rols on top of ols

`rols` is a fork of [DanielGavin/ols](https://github.com/DanielGavin/ols) on branch `master`, based on `upstream/master`.
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
The compile gate of `run_edit` also checks the importers of each touched package, directly or through other importers, found by `graph_importers` in `src/server/rols_rename_package.odin` with a visited set, so an import cycle ends. `run_edit` reads the imports of the workspace once into an `Import_Graph` (`import_graph`) and passes it to `gate_targets`, which walks it again for each target. It warns when the check before the write already reports errors in a directory. For `rename` and `rename-package`, it matches an existing error with the old name replaced by `replace_word` in `src/server/rols_rename_check.odin`, only on a line that an edit of the rename changes (`edited_lines` in `src/cli/rols_gate.odin`). `error_key` keys a `Different package name` error by its two names sorted. `tools/cli_smoke.sh` covers all of it.
The gate checks other build targets: `gate_targets` in `src/cli/rols_gate.odin` returns one `Gate_Check` per target. It adds a `-target:` value for each file that the current target does not build (`target_for_file` in `src/server/rols_check_targets.odin`, which uses `file_name_target` and `match_build_tags`) among the touched files, the other files of their directories and the files of every importer directory. That check covers the directories of the files that need the target and their importers, a subset of the packages the current target checks, so `checked` in the summary still counts packages. A `when` condition adds no target (see Known limitations). The existing key `checker_targets` adds its targets to those, each checking every package (`target_name` accepts only the candidates). Verified with `odin` dev-2026-09 on a macOS host with no SDKs: `odin check -target:T` accepts 19 targets (every candidate and `windows_i386`, `freestanding_amd64_win64`), and `tools/cli_smoke.sh` checks a windows-only file that imports `core:sys/windows` on `windows_amd64`. Odin dev-2026-10 refuses a Windows target on another host with "-windows-sdk-root:<path> must be used to target Windows", a flag `odin check` rejects: `record_check_run` in `src/server/rols_check_run.odin` sets `windows_sdk` and adds a hint to the failure, and `gate_baseline` skips such an extra-target or variant check with a warning (`skip_refused_windows_check` in `src/cli/rols_gate.odin`); the check on the current target still refuses. `tools/cli_smoke.sh` covers both with the real odin when it refuses, and with a fake `odin_command` that refuses every Windows target. An importer directory with no file for the current target checks clean on the host (odin exits 0 with no output), so it needs no special case. `server.check` takes a `timeout` argument, default `CHECK_TIMEOUT` (20 s, the editor check); the gate passes 20 s for each batch of cores packages, capped at 10 minutes (`gate_check_timeout`).
`with_variants` in `src/cli/rols_gate.odin` adds one `Gate_Check` per `checker_variants` entry, whose `args` `check_errors_for` appends to `checker_args` after the check's `-target:`, so a `-target:` in the entry wins. `gate_baseline` drops a package whose variant check reports an error outside the workspace, as on an extra target. When the check after the write finds new errors, `run_edit` restores the files, checks the original code again with `recheck_checks` (the checks and directories whose error files, kept by `check_errors`, name a file of a new error), merges that result into the baseline with `union_errors`, writes the edit again (`write_edit`), and when new errors remain runs every check once more (the second check covers every package, like the baseline it is compared with) and keeps only the errors both runs after the write report (`intersect_errors`); `tools/cli_smoke.sh` covers it with a fake `odin_command`.
Its `recipe` rules, parsed from the `modernize_recipes` config key, live in `src/server/rols_modernize_recipe.odin` and share the pattern matcher of `src/server/rols_pattern.odin` with the use_stdlib lint; `tools/cli_smoke.sh` covers one.
Its `find` command runs `find_symbols` in `src/server/rols_find.odin`, which reads every `.odin` file of the workspace instead of asking the index, so it reports private declarations and those of other targets with flags; it scans the identifiers of each file first and parses only a file where one passes the fuzzy matcher. `workspace_package_dirs` in `src/server/rols_find.odin` lists the package directories that `check` and `tests` cover without an argument; `package_dirs_below` walks a directory that the workspace filter skips without the filter. `find_tests` in `src/server/rols_tests.odin` keeps the files that `builds_on` accepts for the target of `checker_args`, else the host, and for a single file only its tags (`tags_build_on`), as `odin test FILE -file` does. `check` exits `1` on an error-severity diagnostic, and `test` refuses a name that `find_tests` does not list. `collect_lints` in `src/cli/rols_cli.odin`, which `lint` and `check` share, drops the files of a directory that the workspace filter skips unless the filter skips the directory itself, and `lint` builds that filter once (`workspace_lint_filter`) for its directory walk too. `lint` notes a file that does not parse on stderr and still reports its lints. `tools/cli_smoke.sh` covers all of it.

Confirm with `git diff --name-status upstream/master..HEAD | grep '^A' | grep -v '\.odin$'`.

## Hook points in upstream files

Registration:

- `src/server/action.odin`: `action_procs` table plus the fork action run, package file collection for cross-file actions, the shared edit builder and the import edits organize-on-save reuses.
- `src/server/requests.odin`: `call_map` entries for the fork handlers.

Config:

- `src/common/config.odin`: range formatting, extra inlay hint kinds, fork code action, lint, lens and checker flags, workspace filter keys, client file-creation and file-rename support.
- `src/server/types.odin`: the same flags as `Maybe(bool)` in `OlsConfig`, and the workspace glob lists.
- `src/server/requests.odin`: initialize-option merge for those flags, and `apply_default_config` holding every default so the CLI can reuse them. Each `checker_skip_packages` entry is also stored with symlinks resolved.

Capabilities:

- `src/server/requests.odin`: initialize response: range formatting, fork action kinds and providers, the hint kinds that turn the provider on, organize-on-save, file-creation and file-rename client support.
- `src/server/types.odin`: capability and payload types for the fork requests, server-initiated request payloads, the `CreateFile` and `RenameFile` document changes, and the named response union that lets `workspace/applyEdit` be sent.

Workspace filter (`src/common/rols_workspace_filter.odin`), applied to workspace symbols (directories only), the reference file list behind references, rename, change signature, incoming calls, code lens and the CLI, the checker's fallback package list, and the collection package aliases behind import completion, auto-import and add-import:

- `src/server/workspace_symbols.odin`: the package walk skips filtered directories.
- `src/common/util.odin`, `src/common/util_windows.odin`: `search_for_odin_files` takes the filter, and `run_executable` spawns under `process_spawn_lock`.
- `src/server/references.odin`: `workspace_odin_files` builds a filter per workspace root.
- `src/server/build.odin`: `append_packages` takes the filter.
- `src/server/check.odin`: the fallback package list for workspace diagnostics filters each root, and `odin check` spawns under `process_spawn_lock`.
- `src/server/caches.odin`: `find_all_package_aliases` walks each collection with the filter of the workspace folder that contains it or lies inside it (`src/server/rols_package_aliases.odin`). A folder builds its filter, which runs git, on first use only, once per call, so a folder no collection overlaps runs no git. A collection outside every workspace folder is walked unfiltered.

CLI:

- `src/main.odin`: `ols query` dispatch and the reused logger.
- `src/server/rename.odin`: `get_rename` takes the files that stand in for the workspace walk, for the tests.
- `src/server/when.odin`: `resolve_when_ident` reads `ODIN_OS` and `ODIN_ARCH` from `when_target_ident` first, so a file that `build_target_package` collects for another target evaluates `when` for that target; `host_target` in `src/server/build.odin` reads the same `when_target`.
- `src/server/references.odin`: `resolve_references` passes those files on.
- `src/server/rename.odin`: `get_rename` takes its locations from `resolve_references`, which adds the platform variants of a package-level declaration (`declaration_variants` in `src/server/rols_variants.odin`), or of a member the same-named members of its type's variants (`field_variants`); `reorder_params`, the remove-parameter action and the safe-rename check use the same variants. The safe-rename check drops a declaration of the new name, in a sibling file, in the renamed declaration's own file or in a variant's file, that no OS, architecture and project name builds together with a renamed one (`builds_together` in `src/server/rols_check_targets.odin`, which tries each name of the files' `#+build-project-name` tags and one name none lists), or whose `when` branch such a build cannot take together with the renamed one's (`branch_possible_on`, which folds only `ODIN_OS`/`ODIN_ARCH` comparisons with implicit selectors, `true`, `false`, `!`, `&&`, `||` and parentheses). It also drops a declaration in another arm of the same `when` statement as a renamed one, whatever the condition (`in_other_when_arms` in `src/server/rols_rename_check.odin`).
- `src/server/rename.odin`: `get_prepare_rename` and `get_rename` first try an import name, the alias of an import or a qualifier `x` of `x.y` or `alias :: x` that resolves to an import, through `import_name_at` and `rename_import` in `src/server/rols_rename_import.odin`. Such a rename changes the alias, or inserts one before the path of an import without one, and the qualifiers of that file only. It shares `check_import_name` and `import_qualifiers` with `rename-package` (`src/server/rols_rename_package.odin`), and `check_rename` runs the same refusals.
- `src/server/rename.odin`: `get_prepare_rename` first tries the name of the `package` clause, through `package_clause_at` in `src/server/rols_rename_package_clause.odin`, and prepares it without a `_test` suffix.
- `src/server/requests.odin`: `request_rename` runs `rename_package_clause` (`src/server/rols_rename_package_clause.odin`) first, which renames the package of the document with `rename_package` when the client can rename files (`client_rename_file_support`) and sent workspace folders, and refuses otherwise. `check_rename` refuses the clause and names `rename-package`.
- `src/server/requests.odin`: `request_rename` runs `rename_import` itself, once, and answers with its edit, or with a `RequestFailed` error whose message lists the causes; `src/common/types.odin` adds that LSP code (-32803) to `Error`.
- `src/server/references.odin`: `find_symbol_references` takes `variants`, matches a reference to any of them like one to the symbol, and adds each variant's declared name once. `resolve_references` passes the variants of a package-level declaration, or of the type of a member, unless the search is limited to the current file, so the references request and rename share them.
- `src/server/check.odin`: `start_check_process` takes its command line from `check_command` in `src/server/rols_check_args.odin`, which drops repeated flags (checker_args wins), and `check` passes each error through `check_error_severity` in `src/server/rols_check_severity.odin`, which parses the file to tell the hard `declared but not used` error from the `-vet-unused-variables` warning. `split_checker_args` splits `checker_args` on whitespace; a quoted text with whitespace groups and loses its quotes, other quotes and backslashes stay literal (odin reads `-define:T="x"` with the quotes in the value). `src/server/rols_check_style.odin` holds the style rerun: when a process with a style flag (`-vet-style`, `-vet-semicolon`, `-vet-tabs`, `-strict-style`) reports a Syntax Error or the `-vet-tabs` finding, `check` queues the same package again without those flags (`pending_reruns`, budget doubled to `2 * timeout`), unless `has_real_syntax_error` finds that a file a Syntax Error names does not parse with rols' parser either, and `merge_style_rerun` keeps the first run's errors that the rerun did not report with type `style`, which `check_error_severity` maps to warnings. A process that a signal killed before it printed anything (`child_exit_signal` in `src/server/rols_check_crash.odin` and `rols_check_crash_windows.odin`, a `waitid` peek before `os.process_wait` reaps the child, since core:os stores the signal in `exit_code`) is logged, marked `crashed` and queued again once (`retry`) in the same budget; `record_check_run` skips a crashed process, so only a second crash fails the check. `gate_config` in the args file is what the compile gate of `ols query --apply` checks with: no vet flags, `-max-error-count:100000`. `test_command` in `src/server/rols_tests.odin` drops repeated flags the same way. README "Command line queries" lists the contract, including the exit `1` of `ols query check` for a check that did not run.
- `src/server/check.odin`: `run_check_consumer` shows the failure of an editor check that did not run, such as odin refusing a Windows target, in a `window/showMessage` error once until a check succeeds (`report_check_failure` in `src/server/rols_check_run.odin`); a timeout stays in the log. It also notes each process's exit status and records whether every package check ran to a parsed result, so the refactor compile gate of `ols query` can tell no errors from a check that did not run, and records per package check path the files its errors name, so the gate can drop a package on an extra target when its baseline errors lie outside the workspace.

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
- `src/server/ast.odin`, `src/server/symbol.odin`, `src/server/collector.odin`, `src/server/completion.odin`, `src/server/build.odin`: the index also keeps the declarations of `when` branches the host does not build, flagged `Fallback`, so code in such a branch resolves a type that another file declares in one. `collect_when_stmt` collects them on the index path only, `collect_symbols` stores a fallback only under an absent name and lets an active declaration replace it, and completion, fake methods, ObjC class members, `ols query api`, `pkg.NAME` in `when` conditions, the lints in code the host builds (through `lint_symbols`) and the unused-declaration lint skip them, and `lint_fallback` reads them for dead-store and duplicate-condition. The lints in `resolving_lints` (`src/server/rols_lint.odin`) and the use-stdlib hints skip inactive branches, where a name can resolve to the host's declaration. Both also skip every file the host does not build (`document_build`), where a name can resolve to a declaration that the target building it does not have. The naming and deprecated lints stay silent in inactive branches and excluded files on a name whose declaration has platform variants (`ambiguous_in_inactive`). Hover, definition and rename reach a fallback from code the host builds too: the resolver cannot tell a name that no build declares from one in a branch that the `when` evaluator misjudges as false, and there the fallback is the right answer. A fallback that another declaration hides waits in `SymbolPackage.hidden_fallbacks`, and `index_file` and `remove_index_file` give it the name back when that declaration goes (`restore_hidden_fallbacks` in `src/server/rols_when.odin`). `internal_resolve_type_identifier` and `resolve_location_identifier` in `src/server/analysis.odin` set a fallback aside through `lookup_active` (`src/server/rols_when.odin`) and return it only when the builtins miss too. Of several fallbacks of one name, the index keeps the first that it reads, and every lookup returns that one.
- `src/server/when.odin`, `src/server/ast.odin`: package constants fold for `when` conditions in dependency order (`src/server/rols_when_fold.odin`). `register_when_consts_from_globals` calls `fold_when_globals`, and `collect_globals` folds the file's constants outside any `when` through `fold_when_file_consts` before its walk, so a constant may name one declared further down. A constant folds after the names its value reads. A declared name that does not fold, such as a variable or a member of a cycle, reads as unknown. An undeclared name, a procedure or a type still reads as false. In `collect_globals`, a constant that reads a name declared in a `when` branch stays out of the pre-fold and folds in declaration order as before.
- `src/server/indexer.odin`, `src/server/documents.odin`, `src/server/build.odin`, `src/server/methods.odin`, `src/server/symbol.odin`, `src/testing/testing.odin`: a file that the host does not build, such as `socket_linux.odin` on darwin, sees the declarations of the target that builds it (`src/server/rols_excluded.odin`). Each such target has its own symbol collection of every file that it builds, with `when` evaluated for it, so a host-only sibling answers nothing there. `lookup` (`lookup_other_target`), completion (`fuzzy_search_other_target`), fake methods and ObjC class members (`package_in`) read it. The index answers for a package of which that target builds no file that declares something, and for the builtins. The collection is filled per package on the first lookup into that package, which reads and parses every file of the package: the first `textDocument/semanticTokens/full` on `core/sys/linux/sys.odin` on darwin takes about 180 ms against 70 ms, and peak memory grows from 86 MB to 142 MB. `parse_document` records the target of each document, the test harness hands each test source to `note_unsaved_file`, since those files are not on disk, `index_file` and `remove_index_file` drop the package from those collections, and `free_index` frees them.
- `src/server/indexer.odin`: `lookup` reuses the package and uri of the last file it ran for.
- `src/server/build.odin`: drop stale symbols on removal and reindex.
- `src/server/generics.odin`: keep procedure tags, attributes and the diverging flag when solving a generic.
- `src/server/writer.odin`: framed write of one message.
- `src/server/diagnostics.odin`: fork producers, a file-private mutex, and the merge that runs under the lock.
- `src/server/document_symbols.odin`: a value declaration, a compound literal or `#config` included, is a Variable when mutable and a Constant otherwise; the literal's field map lives in temp memory.
- `src/server/hover.odin`: a variable of an imported package keeps its package, the `offset_of` member hovers as the field of T, and a group call that picks no member shows the group.
- `src/server/inlay_hints.odin`: fork hint kinds, enclosing procedure tracking, and a resolve context built only when a kind needs it.
- `src/server/check.odin`: never block the request thread, drain the pipe incrementally, reap killed processes, vet findings as warnings, and a `Syntax Error` that `-json-errors` types as a warning, such as a missing import path, as an error.
- `src/server/documents.odin`: reject a change before touching the document, refresh lint diagnostics. `document_apply_changes` also relints each open file of the package whose `unused-parameter` verdict on another file the new text may turn (`relint_package_siblings` in `src/server/rols_lint_refresh.odin`), before the refresh pushes the diagnostics. `document_open` relints them after it stores the document, when the buffer differs from the disk text that they read before (`relint_siblings_on_switch`). `document_close` and `document_storage_shutdown` drop the recorded verdicts.
- `src/server/requests.odin`: `notification_did_save` runs the lints, and relints the open files of the package as a change does. `notification_did_close` relints them against the disk text when the closed buffer differed from it, and `notification_did_change_watched_files` relints them with the new disk text of each changed or deleted file that is not open (`relint_siblings`).
- `src/server/position_context.odin`, `src/server/file_resolve.odin`: a call argument drops the enclosing comp literal, so a comp literal in the argument resolves against the parameter type.
- `src/server/signature.odin`: inside a comp literal passed to a call, the comp literal signature comes before the procedure signature.
- `src/server/analysis.odin`: `resolve_implicit_selector` resolves an implicit selector inside a comp literal on the right of an assignment against the literal, not against the assigned name.
- `src/server/analysis.odin`: `expand_call_args` passes the member of `offset_of(T, member)` without a symbol, so a member named like a package keeps the two-argument overload. A local, global or package declaration named `offset_of` or `offset_of_member` shadows the builtin (`offset_of_member_arg` in `src/server/rols_offset_of.odin`), so the arguments of a user procedure of that name resolve as usual.
- `src/server/file_resolve.odin`: the `offset_of` member resolves to the field of T, and struct and bit_field field names are not resolved as identifiers.
- `src/server/references.odin`: the `offset_of` member is a reference to its field.
- `src/server/file_resolve.odin`: `resolve_binary_expr` resolves each operand with its own parent expression as `binary`, so in `.X == a + b` the implicit selector resolves against `==`, not against `a + b`.
- `src/server/analysis.odin`: `resolve_identifier_expr` flags a variable or parameter declared with an inline struct, union, enum, bit_set or bit_field type `Anonymous`, so "Add explicit type" and the variable type inlay hint do not write the variable name as its type. `resolve_local_identifier` and `resolve_global_identifier` keep that inline type expression for a copy (`x := p`), whose declaration has no type expression, so a poly parameter takes the full type.
- `src/server/imports.odin`: `find_unused_imports` counts an import as used only where the file names its package, not where a value of one of its types appears, and never reports an `@(require)` import. A package named only in a `when` branch the host does not build counts as used, so organize-imports on save keeps an import that another target needs.
- `src/server/file_resolve.odin`: the where clauses of a union and the paths of a foreign import are resolved, so a package named only there counts as used.
- `src/server/analysis.odin`: `resolve_slice_expression` gives a slice an anonymous type, so hover and "Add explicit type" print `[]int` for `s.arr[:2]` where upstream printed the field name.
- `src/server/requests.odin`: the Odin root lookup runs `<workspace>/odin` only when it is a file, so a package directory named `odin`, such as `core/odin`, is not run.
- `src/server/locals.odin`: `get_local` skips a local for a name in another top-level declaration of the file (`in_local_top_level_decl` in `src/server/rols_resolve.odin`), so the initializer of a global does not see the locals of a procedure that uses the global. A declaration inside a top-level `when` counts as top-level.
- `src/server/analysis.odin`: `resolve_function_overload` caches each result, failures included, with the `OverloadMode` it resolved in (`src/server/rols_resolve.odin`), and ignores a cached result of another mode. The in-progress marker hits in every mode. A tie between members whose results differ picks no member when the call result is wanted (`top_candidates_agree`), as for `f()` in `f()()`. `resolve_implicit_selector` and implicit completion name the call and argument whose parameter they read (`overload_arg_call`, `overload_arg_index`), and a tie between members whose parameters differ there yields the tied members as an aggregate (`tied_candidates_at_arg`): hover and definition then give nothing, and completion offers the values of every tied member (`src/server/completion.odin`, `append_tied_member_arg_completions` in `src/server/rols_completion.odin`). `resolve_implicit_selector` resolves the callee against its call, and reads the parameter through `get_call_arg_field`, which binds the positional arguments of `x->f(...)` after the receiver. A poly-type argument leaves that mode with the top or tied members, where the other modes resolve every member. In the `All` and `Member` modes `expand_call_args` keeps an argument that resolves to no symbol (`keep_unresolved`), which rules no member out, so signature help on `g(.A, n)` with an undeclared `n` lists the tied members.
- `src/server/completion.odin`, `src/server/analysis.odin`: selector completion on an identifier that resolves to nothing and that the file does not declare as a local or global, like `mem.` without `import "core:mem"`, lists the members of the package whose last path element matches and that the file does not import, preferring the `core` collection, then the shortest path (`rols_unimported_package_symbol` in `src/server/rols_completion_auto_import.odin`). The import edit, placed like the one of `append_non_imported_packages`, waits in the `auto_import_edit` field of `AstContext`, and `convert_completion_results` adds it to every item. Gated by `enable_auto_import`.
- `src/server/analysis.odin`, `src/server/file_resolve.odin`: the whole-file resolve sets `whole_file_resolve` on its `AstContext`, and `resolve_function_overload` then drops a member that takes fewer arguments than the call passes, and one that needs more when the value count of every argument is known (`proc_required_arg_count`, `call_arg_counts_known` in `src/server/rols_resolve.odin`). A bad expression or an unresolved argument leaves the count unknown. A comma after the last argument on the line of `)`, as in `g(1, )` while the next argument is typed, keeps the members that need more (`call_has_trailing_comma`). The comma that ends the last argument of a multi-line call does not count. Completion and signature help keep every member, as upstream does. To match a member, `resolve_function_overload` counts the values an argument passes through `expand_call_args`: one per result name, one for an `#optional_ok` procedure, every result of `x->f()`, and one for a conversion to a procedure type (`is_proc_type_conversion`).
- `src/server/file_resolve.odin`, `src/server/documents.odin`: the whole-file resolve records argument callees in `Document.arg_callees`, cleared with `symbols`.
- `src/server/documentation.odin`: `write_signature` writes the pointers of a struct, union, enum or bit_field printed by its body, so hover on `q := &p` for `p: struct {...}` shows `^struct {...}`.
- `src/server/hover.odin`: hover on the callee of a group call that picks no member, such as a tie between different results, shows the group.
- `src/server/analysis.odin`: `get_proc_return_types` resolves the callee of a call that a builtin such as `max` returns against that call, so a group member is picked by its own arguments.

Tests:

- `tests/action_invert_if_test.odin`: the early-exit variant and the fork behaviour.
- `tests/inlay_hints_test.odin`: the fork hint kinds.
- `tests/imports_test.odin`: takes turns on the global diagnostics maps with the other tests that replace them (`lock_global_diagnostics` in `tests/rols_lint_refresh_test.odin`), and resets the document storage after its shutdown.
- `build.sh`: `single_test` checks the status of `odin test` itself, so it exits 1 when `odin test` fails, as `test` does. The environment variable `ROLS_TEST_TIMEOUT=SECONDS` bounds `test` and `single_test`: `odin test` runs in its own process group, which gets SIGKILL on timeout, and the run exits 1. Unset means no limit. Set it lower than any outer timeout, because an outer kill of the `build.sh` process group does not reach the test group.

## Changed upstream defaults

Set in `apply_default_config` in `src/server/requests.odin`, and in `misc/ols.schema.json` and README.md:

- `enable_comp_lit_signature_help`: true, upstream false.

## Changed upstream formatter output

The fork formatter differs from upstream OLS in these cases. Each has a `tools/odinfmt/tests/rols_*.odin` snapshot, except the first, which edits an upstream snapshot, and the last, which a snapshot covers only through the others.

- `tools/odinfmt/tests/random/.snapshots/demo.odin`: a one-line block followed by a trailing comment (`for !did_acquire(&print_mutex) {thread.yield()} // Allow one thread ...`) loses the tab upstream prints before the comment. The tab came from the Indent comment option leaking from the opening brace to a comment after the closing brace (stage S19). The user approved this snapshot change. Stage S20 also changes `for i := 0; i < len(threads);  /**/{` to `/**/ {`, as the source has it, by the block comment rule below. The user approved this change.
- A one-line block of `;` joined statements that does not fit opens a normal block (`rols_when_block_semicolon_line`).
- A `;` joined line after the first line of a block breaks at its `; ` when it does not fit, and a statement between two `; ` counts in full when the line is measured (`rols_semicolon_line_wraps_after_first_line`, `rols_semicolon_line_over_width_late_statement`).
- A one-line `if` or `when` chain, `else if` and `else when` included, breaks every block when the line does not fit and one of its blocks holds `;` joined statements. Two one-statement blocks keep upstream's layout. An `else if` or `else when` header that holds a `{`, such as a procedure literal or a composite literal, pairs as well, and a fit check inside the header measures the paired block in the mode that format already decided for the then-block (`chain_fit_mode` in `src/odin/printer/rols_chain.odin`). A fit check measures the `else` block in full even when it holds a procedure literal or a composite literal, because `fits` in `src/odin/printer/document.odin` measures a `rest_flat` group in Fit mode, where a nested group does not end the measure at its first break (`rols_if_else_one_line_else_overflows`, `rols_if_else_one_line_pair_mixed`).
- A block comment before an item on its line stays before the item with one space after it. The items are struct and bit_field fields, parameters, call arguments, enum and union members, composite literal elements, and an expression that starts on the comment's line, such as a right operand on the operator's line. Upstream prints it as a trailing comment of the previous token, which moves it to its own line or drops the space after it. A comment that shares a source line with the previous item also leads the next item now: `.Free, /* .Free_All, */ .Resize` prints `.Free,` and then `/* .Free_All, */ .Resize`. A right operand on its own line still takes the comments above it, as before. Field, value and bit_field name alignment counts the comment, also when the comment and the name together are wider than the longest name (`rols_block_comment_first_item`, `rols_block_comment_after_line_comment`, `rols_block_comment_later_item`, `rols_block_comment_alignment`, `rols_block_comment_bit_field_union`, `align_declarations/rols_block_comment_declarations`). The rule also covers the `package` clause and file tags, a statement, a declaration and its attributes, an import, a foreign import, a foreign block, a file-level `#assert`, a block's opening brace and the post statement of a `for` (`rols_block_comment_before_statement`). A comment before the `;` that ends a `for` condition stays before that `;` with one space before it: `for i := 0; /**/; i += 1 {` and `for i := 0; i < n /**/; i += 1 {` keep their layout, where upstream prints `;;  /**/i += 1`. The rule also covers a field or parameter that starts with a flag or `using`, where the comment leads the flag (`rols_block_comment_field_flag`). A comment before a closing `}` keeps upstream's placement.
- A comment on the operator's line in a binary chain stays on that line, and a comment above the first call argument stays above it (`rols_idempotent_binary_trailing_comment`, `rols_idempotent_call_arg_comments`).
- Struct field alignment counts `#subtype` in the longest name, so `#subtype base: Base,` and `z:             int,` line up. Upstream counts it only on the declaration-alignment path (`rols_block_comment_field_flag`). The user approved this change.
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

### `enable_lint_*` (32)

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
- `enable_lint_triple_quote`
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
- `enable_excluded_file_targets`
- `enable_organize_imports_on_save`
- `enable_range_format`
- `enable_selection_range`
- `enable_workspace_gitignore`

### Non-flag keys

The regenerate command above lists only `enable_*` keys.

- `workspace_exclude`
- `workspace_include`
- `checker_variants`: extra `checker_args` for one more compile gate check each, on the current target or on the `-target:` that the entry names. It has no `enable_*` flag: an empty list adds no check.
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

- `## Features`: the import rename and package rename notes under Rename
- `## Command line queries`, including the refactor dry run, `--apply` transaction with directory renames, the packages and build targets the compile gate checks (`checker_targets`), `--no-check`, exit codes, symbol path targets, the rename refusals, `rename-package` and `attr`
- `### Claude Code`

The fork's option bullets in README are the config keys listed above.

## Known limitations

These limits stay because a fix needs a change outside rols (Odin, upstream OLS, a client or the environment), would break a documented trade-off, or concerns a crash that was never reduced. Open work that rols can fix lives in `FOLLOWUPS.md`.

### Formatter

- **Known limit: `fits` measures a later group in the rest up to its first possible break, as upstream does.** A construct that needs the whole line measured opts in with `rest_flat`. Changing it globally rewrites upstream's `calls.odin` snapshot and breaks output compatibility with OLS.

### Lints

- **Known limit: `naming` fires on C names in a package without a `foreign import` or an import of `core:dynlib`.** The lint skips `foreign` blocks, `@(link_name)`, `@(export)`, tagged struct fields, parameters of a procedure type with a non-Odin calling convention, and type, field, enum member and constant names in a package where a file has a `foreign import` or imports `core:dynlib`. Nothing in the source marks any other name as foreign: the LSP protocol structs in ols (`workspaceFolders`, `rootUri`, 116 field hits) have no tag or attribute, so those hits remain. A struct tag such as `json:"rootUri"` already exempts a field. Marking other names would need a new attribute or comment marker, which other OLS clients and the Odin compiler do not know, so it would break drop-in compatibility. karl2d's `platform_bindings`, which load their C functions with `dlopen`, were not rechecked against the `core:dynlib` exemption.
- **Known limit: the fill rewrite checks only a pointer's initializer.** The use-stdlib fill rewrite in `src/server/rols_lint_use_stdlib.odin` (`reads_array`) checks only a pointer's initializer, so `q: ^Inner; q = &items[0].inner; for &e in items { e = Item{y = q.x} }` and `r := q` with `q := &items[0].inner` are still offered the rewrite.
- **Known limit: the `range-off-by-one` guard does not see a length held in a parameter or a struct field.** `guarded_by_len` in `src/server/rols_lint_loops.odin` accepts `len(x)` or a local `n := len(x)`, so `if b < count { x[b] }` with `count` a parameter or `if b < s.len { x[b] }` still reports. `names_len_local` refuses a local when any assignment in the top-level declaration targets its name, even one to another variable of that name, or when an assignment after it targets the collection. An assignment to the collection or to a base of its selector chain, such as `s = t` for `s.items`, counts. A change of the collection through a pointer, such as `pop(&x)`, is not seen, so the stale length still counts as a guard.
- **Known limit: `pure-call-unused` skips every procedure with a pointer parameter.** `has_pointer_param` in `src/server/rols_lint_pure_call.odin` treats a `^T` or `[^]T` parameter as an output, so a pure procedure that only reads through a pointer is skipped unless `ACCESSOR_NAMES` lists it. Since `core:slice` is checked, a discarded `slice.unique`, `unique_proc` or `bitset_to_enum_slice_with_buffer` result reports. These procedures change their argument in place, but only the result carries the new length, so the report is a true positive.
- **Known limit: `bool-compare` keeps the comparison of an index or dereference whose operand is not a name or a selector.** `compares_non_bool` in `src/server/rols_simplify.odin` takes the element type of `xs[i]` and the pointee of `p^` from the resolved operand. When the operand does not resolve, as in `f()[i] == true` or `a[i][j] == true`, the comparison is not reported. A comparison that is the condition of an `if`, a `for` or a ternary is reported whatever the operand, because a condition accepts any boolean type.
- **Known limit: `unused-parameter` matches value uses in other files by name and reads every file of the package per lint run.** `used_as_value_elsewhere` in `src/server/rols_lint.odin` runs for a top-level procedure that is not file-private, has an unused parameter and is not a value in its own file. It reads every `.odin` file of the directory (an open file with its unsaved text) and parses only the ones that hold the name as a word, at most 1.5 MB of them per run. The first three names of a run scan the text of each file, and later names use an index of its words built once: a file with 40 such procedures in a copy of `src/server` went from 95 ms to 20 ms. A file past that limit, or one that does not parse, counts as a use when it holds the name. A local of the same name in another file counts as a use too, and a value use in another package is not seen. On this repository's `src/server` (147 files, 1.75 MB), a `didChange` of `rols_folding_range.odin` went from 4.2 ms to 9 to 12 ms, and of `analysis.odin` from 107 to 113 ms to 116 to 124 ms.
- **Known limit: an `unused-parameter` verdict on another file is not refreshed when a file changes outside the editor and the client does not watch files.** `relint_package_siblings` in `src/server/rols_lint_refresh.odin` relints the open files of a package on a change, save, open or dirty close of a sibling and on `workspace/didChangeWatchedFiles`. Without a watched-file notification the server never learns of a change made on disk, so the verdict stays until an open file of the package changes.
- **Known limit: `ols query modernize --rule unused-parameter` judges a parameter by its first pass.** `modernize_document` in `src/server/rols_modernize.odin` keeps the verdict of `param_named_elsewhere` per procedure and parameter name for the run, since other files resolve the procedure through the index built from the original text. A pair that a later pass reports first is refused. Two `when` variants of one procedure in one file share a verdict.
- **Known limit: `unused-parameter` cannot see a procedure that a package outside the workspace uses as a value**, such as a library handler that another project registers, because only workspace importers are read (`src/server/rols_lint.odin` `used_by_importers`).
- **Known limit: enum switch coverage treats a member value it cannot evaluate as distinct.** `enum_member_values` in `src/server/rols_enum_values.odin` (shared by `redundant-partial` and the populate-switch-cases action) folds integer and rune literals, the arithmetic, shift and bitwise binary operators, earlier members and constants declared as such expressions (in their own package) through `const_int`. A value it cannot evaluate gets its own case, so the action may still emit a duplicate for it: a call such as `size_of(T)` or `len(ARR)`, a conversion such as `u8(3)`, a unary `~` (its result depends on the type's width), a ternary, or a constant that does not resolve. `const_int` folds in 64-bit `int`, while Odin folds untyped constants at full precision, so a value that overflows 64 bits differs, and a shift by 64 or more is not folded. A constant that resolves to the wrong declaration gives a wrong value, which can merge two members or split an alias from its target; `const_int` relies on `resolve_type_expression` to find the declaration. Following a constant into another package folds its expression with the caller's locals still active, so a local `M` can shadow the `M` in `other.N :: M`.
- **Known limit: unused imports count a package named in either branch of a `when` as used.** `odin check` checks only the taken branch, so it reports `core:hash` in `internal/engine/unload.odin` of the sweep project when every `hash.` sits under a false `when hostabi.CHECKED`. `find_unused_imports` in `src/server/imports.odin` walks both branches on purpose: organize-imports on save must keep an import that only another target's branch uses, or that target stops building. A separate host-only verdict for the diagnostic alone would repeat the unused-import error that `odin check` already reports on the host. `import_named_only_in_type_expressions_is_used` in `tests/rols_unused_imports_test.odin` pins it, and the `enable_unused_imports_reporting` option in README.md documents it.
- **Known limit: `dead-store` is silent for a store to a `using` field of a pointer or parameter.** `dead_store` in `src/server/rols_lint_dead_store.odin` reports a dead store to a field of a local `using s: S` value that is never read again, but stays silent when the field comes through a pointer or a parameter, such as a `using s: ^S` parameter, because that value usually outlives the store.

### Code actions

- **Known limit: the "organize imports" code action still adds imports at the upstream anchor.** `source_organize_imports` in `action.odin` (upstream) calls `organize_import_edits` without `grouped`, so a new import goes after the first import, or above all imports when the first one is removed. The upstream test `action_organize_imports_add_and_remove` in `tests/actions_test.odin` pins that position. Organize-on-save passes `grouped` and places each import among the kept imports of its collection.
- **Known limit: "Invert if" on an `if` without `else` leaves an empty then-branch** (`if !c {} else {…}`). This is upstream OLS's tested behavior (`action_invert_if_simple_edit`), kept for compatibility.
- **Known limit: the nested-if merge refuses a named callee that does not resolve.** `callee_deferred` in `src/server/rols_action_split_merge_if.odin` falls back from the whole-file resolve map to a resolve with the locals at the callee, which finds a procedure group declared inside a procedure. A group call whose overload does not resolve counts as deferred when any member has a `deferred_*` attribute. A callee that neither finds still counts as deferred, so the merge is refused although the call may be harmless. This is the safe direction, because Odin rejects a call to a deferred procedure inside `&&`.
- **Known limit: "Add ok result" refuses every caller it cannot extend.** `add_ok_to_callers` in `src/server/rols_action_add_ok_result.odin` adds `, _` to `v := f()`, `v = f()`, `a, b := f()` and the `if` init form whatever the arguments, and leaves a statement call alone. It refuses the whole action for a call used as an argument, a return value or an `or_return` operand, because each of those takes exactly the old results. A typed declaration such as `v: int = f()` cannot take a second value, and a procedure used as a value would change its type. A local procedure named anywhere else in its top-level declaration is refused, because its callers are not searched for. `#optional_ok` would keep most of those compiling but changes the result type. Callers are found in the workspace files only, so a caller in a package outside the workspace folders still breaks. A procedure whose body uses `or_return` is refused, because `or_return` assigns the operand's end value to the last result and Odin rejects `Err` to `bool`.
- **Known limit: "Add defer <free>" trusts a call not to keep its argument when the call's result is discarded or holds only scalars.** `escapes_from` in `src/server/rols_action_defer_delete.odin` refuses when the variable, or a value derived from it, is returned, stored, used as a map key, reassigned or passed to a call whose result is kept. A kept result of a non-polymorphic procedure that resolves to only numbers, booleans, runes, enums or bit sets shares nothing, so `n := f(s)` is accepted. A call such as `register(&list, s)` may still store `s` in either case. Only `append`, `append_elem`, `append_elems`, `inject_at`, `assign_at` and `map_insert` are known to store an argument. Proving that a callee does not store its argument needs an analysis of its body, and refusing every call would withhold the action for ordinary calls such as `process(s)`.
- **Known limit: "Unwrap block" refuses an `if` outside a statement list, and counts an unresolved `exit` selector as the end of the flow.** `unwrap_leaves_dead_code` in `src/server/rols_action_unwrap.odin` refuses when `enclosing_stmts` finds no list, such as an `if` that is a `do` body, since the unwrapped statements would need a block of their own. An `else if` without an init statement or an else of its own becomes a plain `else`; one with either is refused. `ends_flow` resolves a called procedure and trusts its `-> !`. A callee that does not resolve counts when it is a selector named `exit`, such as `os.exit(1)` with the import not indexed, so a safe edit may be refused.
- **Known limit: "Inline variable" refuses initializers whose evaluation order it cannot prove.** An initializer moved past a statement must hold no call other than the runtime builtins `min`, `max`, `abs`, `clamp`, `len` and `cap` over an argument that is neither a pointer nor a `cstring`, and the type-only `size_of`, `align_of`, `offset_of`, `type_of` and `typeid_of` (`reads_state` in `src/server/rols_action_inline_variable.odin`). It must also hold no index, slice or deref, no `context`, no selector on a variable or parameter, no read of a global or a `@(static)` local, and no name the resolver misses. A recursive call writes the same static local, so it counts as a global. An initializer that fails this is inlined only into the next statement (`evaluated_in_place`). There, nothing before the use may call, read a global or a static local, or read a local whose address is taken, aliased by a slice or `for &e`, or passed to a `->` call; any plain `=` target is accepted. A literal initializer with more than one use is refused, because each copy would be a fresh value and a `[dynamic]` or map literal would allocate once per copy. A read of a `using` field is refused, because it resolves to the field and the action cannot track writes to it through the struct. An unresolved callee name such as `bar` in `bar(v)` is still accepted, because compiling code can only call a procedure there.
- **Known limit: "Generate test" deletes every slice, dynamic array and map result.** The stub writes `defer delete(result)` and `testing.expect(t, len(result) == 0)`. A procedure that returns a view into memory it does not own, such as a sub-slice of a global, gets a test that frees memory it must not free; the author edits the stub. Whether a returned slice is owned cannot be known from the signature, and leaving the `delete` out would leak every owned result instead.
- **Known limit: "Generate test" does not exclude `freebsd_i386`, where `core:testing` fails to build because of an Odin core bug.** `core/time/time_unix.odin` adds the `i32` field `tv_nsec` to an `i64` on freebsd_i386, so any package importing `core:testing` fails there, while the package without the import checks clean. `NO_TESTING_OSES` in `src/server/rols_check_targets.odin` lists only OSes whose `core:testing` does not build on any architecture. If it is ever needed, the line `#+build !freebsd, !i386` excludes exactly that target. Draft upstream issue, not filed: title "core:time does not compile on freebsd_i386 (tv_nsec is i32)". Body: "`odin check . -target:freebsd_i386 -no-entry-point` (odin dev-2026-09) on a package containing `package tt`, `import "core:testing"` and `@(test) x :: proc(t: ^testing.T) {}` reports `core/time/time_unix.odin(12:40) Error: Mismatched types in binary expression 'i64(time_spec_now.tv_sec) * 1e9 + time_spec_now.tv_nsec' : 'i64' vs 'i32'`, `core/time/time_unix.odin(23:13) Error: Cannot assign value 'nanoseconds' of type 'i64' to 'i32' in a structure literal`, `core/time/time_unix.odin(44:40) Error: Mismatched types in binary expression 'i64(t.tv_sec) * 1e9 + t.tv_nsec' : 'i64' vs 'i32'` and `core/os/process_posix.odin(256:15) Error: Cannot assign value 'i64(timeout % time.Second)' of type 'i64' to 'i32' in a structure literal`. The same package checks clean on freebsd_amd64 and freebsd_arm64."
- **Known limit: "Remove redundant else" refuses an else that ends the flow when statements follow the `if`.** `redundant_else` in `src/server/rols_simplify.odin` would put those already unreachable statements right after the else's terminator, and `odin check` (dev-2026-09) rejects statements after a `return` or `break` in the same block. A field name in a literal, such as `y` in `Point{y = 1}`, still counts as a mention of an else declaration, because a literal key may name a variable.
- **Known limit: `builtin_without_decl` counts a constant named like a builtin type as a type when its value is a name or a call.** `builtin_without_decl` in `src/server/rols_edit.odin` reads the indexed `value_expr` and treats a literal, unary, binary or compound-literal value as a constant. `string :: OTHER` or `string :: f()` cannot be told from an alias without resolving the value. The package can only hold such a constant in a `when` branch that the current target skips, because the constant shadows the builtin type in the whole package.

### Build tags and `when`

- **Known limit: the editor reads a profile define as a bare name.** `make_when_expr_map` in `src/server/when.odin` seeds each profile define under its own name, as upstream OLS does, and a seeded name wins over a package constant of that name. Repro: profile define `DEBUG` set to `false`, `DEBUG :: #config(DEBUG, false) || ODIN_DEBUG` and `when DEBUG { … }` in a debug build; the editor reads `DEBUG` as false and greys out the branch that odin builds. Changing it would break compatibility with upstream OLS and the README profile example, which sets `ODIN_DEBUG` through `defines` and relies on bare names, so this trade-off stays.
- **Known limit: "Introduce parameter" and "Add ok result" are withheld for a procedure with platform variants.** `top_level_variants` in `src/server/rols_variants.odin` finds them, and the two actions return without an action. Each action rewrites the body of the procedure, and the variants' bodies differ, so one edit cannot serve them all. Rename, reorder-params, find references and the `unused-parameter` fix serve every variant. "Remove parameter" removes the parameter from every variant, and a field rename of a struct, enum or bit_field type with variants renames the member in each (`field_variants`). `check_rename` refuses the field rename when a variant is no struct, enum or bit_field type, such as an alias `S :: S_Windows`, or lacks the member but has a `using` field that may bring it in, unless that alias or `using` names a type the rename reaches: the member's type or a package-level alias or `using` embedder of it. The LSP `textDocument/rename` request does not run `check_rename`, so an editor rename applies the edit to the reachable members and leaves such a variant unchanged.
- **Known limit: the resolving lints report nothing in a file the host does not build.** `walk_lints` in `src/server/rols_lint.odin` treats such a file, such as `socket_linux.odin` on darwin, like an inactive `when` branch, so `ignored-result`, `argument-count` and the other lints in `resolving_lints` skip it. A name there can resolve to the host's declaration, and a platform-split helper would get a false argument-count report. `odin check` with that target and the compile gate still report its errors.
- **Known limit: variants are identified without evaluating `when` conditions.** `declaration_variants` in `src/server/rols_variants.odin` counts two declarations in different `when` statements of host-built files as variants even when the conditions overlap, and two declarations in excluded files for the same target as variants of the host's declaration. Both shapes are redeclarations that odin rejects on some target, so renaming them together is harmless; only the duplicate goes unreported here, and `odin check` and the compile gate report it. `branch_possible_on` in `src/server/rols_check_targets.odin`, which the rename collision scan uses, could prune such overlapping pairs later.

### Whole-file resolve

- **Known limit: a failed overload resolution stays cached per mode within a declaration.** `resolve_function_overload` caches each result, failures included, in `ast_context.call_expr_recursion_cache` with the `OverloadMode` it resolved in (`src/server/rols_resolve.odin`), and the whole-file walker clears the cache between top-level declarations. A later resolution of the same call in the same mode inside that declaration returns the failure, even where it would resolve. No reproducing case is known since `get_local` stopped giving the initializer of a global the locals of a procedure that uses the global. Shapes tried: a group call with an implicit selector argument (`g(.A, 1)` over `f1(k: Kind, v: int)` and `f2(k: Kind, v: int, w := 0)`), a tie between members with different results whose call is stored in a local that is used again, references and hover on an implicit selector in such a call, and a field selector on the call result. In those shapes the walker resolved the call in the `All` mode only, and hover on the implicit selector did not read the cached call.
- **Known limit: the whole-file resolve allocates its temp memory from the document cache arena.** This keeps the cached symbols valid after the request frees temp memory. It also retains the resolve scratch until the document is reparsed or caches are invalidated. Measured `symbol_cache_arena.total_used` after `resolve_entire_file`: 23.9 MB without the swap and 29.1 MB with it for a 100 KB file (+5.2 MB, +22%), and 57.7 MB and 70.5 MB for a 250 KB file (+12.9 MB, +22%). An audit found the temp allocations that a cached symbol can point to spread across the resolver: `get_package_from_filepath` (the `pkg` string of every symbol), the synthesized nodes of `builtins.odin`, the poly maps and substituted expressions of `generics.odin`, `symbol.odin` (Objective-C selector nodes, field docs) and `analysis.odin` (the aggregate symbols slice that the printf lint reads, package docs, `uri`, `wrap_pointer`). A targeted copy of that data would have to catch every one of them, and a missed one becomes a silent use-after-free because freed temp memory is not poisoned. The swap stays. Interning the result of `get_package_from_filepath` could be a separate improvement that removes part of the extra share.

### Poly call result symbols

- **Known limit: poly resolution gives a call result the package of its type argument.** `size_buf := unwritten(b.buf)` with `unwritten :: proc(d: [dynamic]$E) -> []E` and `b: bytes.Buffer` resolves `size_buf` to a `[]byte` symbol whose package is `bytes`, not the document's. `find_and_replace_poly_type` in `generics.odin` (upstream) copies the substituted expression's `pos.file` onto the container node on purpose: `pkg` is the package where the child expressions resolve, so an `E = Buffer` written unqualified in package `other` must resolve in `other`. Separating the two needs a per-expression package in `SymbolValue`. `symbol_type_text` in `rols_edit.odin` keeps its consumer guard (a Variable or Constant symbol named like the variable takes the document package), so the add-explicit-type action and the inlay hints print `[]byte`, and `action_add_explicit_type_poly_result_of_foreign_field` pins that behavior. Any other consumer of `symbol.pkg` can still see the type argument's package. Hover on such a variable showed `c1.size_buf: []byte` in a quick check, so it is not visibly affected.

### CLI queries

- **Known limit: `check` and `tests` in a directory without `.odin` files cover every package of the root, with one `odin check` per package.** The run gets the 20 s of an editor check for each batch of cores packages, capped at 10 minutes (`gate_check_timeout`), and the packages share no cache, so a large repository takes long. Odin keeps no cache across processes, and one `odin check` takes one package, so the CLI cannot share the work.
- **Known limit: `check DIR` still runs `odin check` over the gitignored files of `DIR`.** Only the lints follow the workspace filter. `odin check` has no flag to leave out one file of a package, so an error in a gitignored file is reported.

### CLI compile gate

- **Known limit: a `when` branch alone adds no gate target.** `gate_targets` in `src/cli/rols_gate.odin` adds a target only for a file that the current target does not build. On a darwin host, a package whose only file holds `when ODIN_OS == .Windows { x: int = "s" }` passes `ols query attr add … --apply` without a check on `windows_amd64`. List the target in `checker_targets` to check such a branch. Inferring targets from `when` conditions was dropped because no real project needed it.
- **Known limit: each extra target adds checks of its packages.** An edit to an untagged file in a package with OS siblings (`x_windows.odin`, `x_linux.odin`, `x_js.odin`, …) runs one extra check per sibling OS that the current target does not build, each over the package and its transitive importers and each with its own `gate_check_timeout` budget, before and after the write. With all six desktop OSes, js, wasi, orca and freestanding present on a darwin host, that is 9 extra checks per run. In the worst case, a package that every workspace package imports, each check covers the whole workspace and can take up to 10 minutes. The workspace walk is no longer repeated per target: on a copy of this repository, an edit to `src/common/util.odin` (two extra targets) spent 140 to 146 ms in three import walks before stage S24c and 46 to 50 ms in one `import_graph` after it, out of a gate run of about 3.7 s. Odin runs one process per `-target:` value, so the checks cannot share work: pooling them would need a rework of the upstream `check.odin` and diagnostics kept per target. Each target checks only the packages that need it, which `apply_gate_targets_check_each_target_on_the_packages_that_need_it` in `tests/rols_apply_test.odin` pins.
- **Known limit: an extra target or a `checker_variants` check drops a package that builds there but reports an error inside a core generic.** `gate_baseline` in `src/cli/rols_gate.odin` skips a package on an extra target or in a variant check when its baseline check there names a file outside the workspace, and an error that a workspace call raises inside a `core:` generic names a core file, so that package loses its gate on that target. Dropping a package costs a second baseline run of that target. A changing error set is handled by `run_edit` instead: it absorbs an error that the check before the write missed (the check of the original code reports it) and an error that one check after the write reports by chance (the second check after the write does not).
- **Known limit: an error that both checks after the write report by chance still rolls back the edit.** `run_edit` in `src/cli/rols_apply.odin` runs one extra check of every package after the write and treats an error as new when both report it and the check of the original code does not. A flake seen in about 1 of 12 runs, such as `core/sync/chan/chan.odin:382` "'where' clause evaluated to false" in ols, would roll back about 1 edit in 144 if the runs are independent; this was not measured. More reruns would lower that at the cost of a check each.
- **Known limit: the rename rewrite uses lines, not columns.** `on_edited_line` in `src/cli/rols_gate.odin` lets a before error on a line the rename edits match the renamed form, so an unrelated error on the same line still can. Columns cannot narrow it: odin places an error at the start of the expression or statement it reports, not at the renamed identifier (`s = 1 + old_name(1)` reports at the `1`). An error whose position is on another line of a multi-line call is not rewritten.
- **Known limit: a Windows check that comes from the current target still refuses on macOS or Linux since Odin dev-2026-10.** The CLI gate in `src/cli/rols_gate.odin` now skips a refused Windows extra-target check with a warning and keeps gating on the other targets, but when `checker_args` sets `-target:windows_amd64` the current-target check refuses with a hint about the -windows-sdk-root error.
- **Known limit: the cause of the signal 11 crashes of `odin check` is unknown, an unreduced crash.** In Skald (58 packages, `ols query attr add skald/text.odin:L:1 deprecated=1 --apply` on a copy), 6 of 40 gated runs once failed with a check that exited by signal 11 after about 10 ms with no output, a different package each time, while 700 plain `odin check` runs outside ols did not fail. `check` in `src/server/check.odin` now reads the signal with `waitid` before reaping, logs it with the package, and runs that package once more, so the gate no longer refuses on one crash. Unproven whether the child crashes in the fork before `execve` (`core:os` `process_start` runs non-async-signal-safe code there) or `odin` crashes at start. Next step: count the logged crashes over a Skald loop, then try a `posix_spawn`-based launcher.

### Editor check

- **Known limit: the editor check reports the -windows-sdk-root failure only through `window/showMessage`.** When `checker_args` targets Windows on a non-Windows host, `src/server/check.odin` now shows the failure once in `window/showMessage`; a client that ignores showMessage still sees nothing.

### Left open after review

Reviews of fork code found these cases, and no real project or user has hit them. They stay open until one does. The
line names where a fix would go.

- Empty-body lint still flags `for i := 0; i < n; advance(&state) {}`, whose post statement calls a procedure (`rols_lint_no_op.odin`).
- `package_siblings` in `rols_lint.odin` compares directories exactly, so a Windows drive-letter case mismatch drops siblings.
- A file that no target builds (`#+build ignore`) loses the collision check against its own declarations (`check_collisions` in `rols_rename_check.odin`).
- `file_private_global` in `rols_rename_check.odin` evaluates file-scope `when` for the host in a file the host does not build.
- "Inline variable" does not see an `any` value built outside a call, such as `a: any = n`, store `&n` (`stable_locals`).
- The host index folds each file's `when` constants alone, so `when IS_HOST` with `IS_HOST` in another file marks a host declaration `.Fallback` (`collect_globals`).
- Hover, definition, references, semantic tokens and inactive-branch dimming evaluate `when` for the host in a file the host does not build (`active_when_block` and `collect_document_globals` in `when.odin`).
- A `_test.odin` file in a renamed directory that imports its own package may keep `old.x`; Odin may reject that layout anyway.
- Package aliases refresh on a runtime change of `enable_auto_import_skip_hidden_paths` only, and a collection with several workspace folders uses the first folder's filter.
- `ignored-result` skips `f() or_return` with results left over and calls in `defer`; `odin check` reports both.
- An import alias outside ASCII is not found at a qualifier (`import_name_at` in `rols_rename_import.odin`).
- Upstream auto-import completion with `enable_add_import_to_bottom` uses the 1-based end line as a 0-based line (`append_non_imported_packages` in `completion.odin`).
- The editor package rename has been checked only over raw stdio, not applied in Zed or Helix. After it, the index keeps the old package path until it is rebuilt.
- There is no cross-package move: `move_edit` in `rols_move_decl.odin` refuses a target outside the declaration's directory. An estimate is 900 to 1300 lines with tests.
- Performance: `unused-parameter` builds the workspace import graph on each lint that needs importers (about 70 ms for `requests.odin`); a field rename and an implementation request read every workspace file (0.1 to 0.4 s on this repository); a package imported directly and through an import is parsed twice per `find` or `tests` query. Revisit only on a profile of a much larger workspace.
- `tests/rols_lint_refresh_test.odin`, `tests/rols_rename_package_open_test.odin` and `tests/imports_test.odin` call `server.setup_index` outside the harness without `collections_mutex`, a data race under parallel runs.

### Large-file performance

- **Known limit: opening a 2 MB file takes 1.3 to 1.5 s.** On `core/rexcode/isa/ppc/mnemonic_builders.odin` (13,308 declarations), `didOpen` followed by a hover takes 1.31 to 1.52 s, and 0.19 s with `enable_diagnostics` off. The whole-file resolve that the lints start (`resolve_entire_file`) costs about 1.1 to 1.2 s, and parsing and the hover the remaining 0.2 s. Stage S8 removed a second `run_lints` call from `didOpen` (`document_refresh` already lints): before it, the same open and hover took 1.42 to 1.43 s. The whole-file resolve is shared: unused imports, inlay hints and semantic tokens read the same cached map, so inlay hints after the open add almost nothing (1.30 to 1.42 s in total). Earlier stacks showed no single hot spot: `clone_node`, `resolve_function_overload`, `create_uri` and `store_local` each hold a few percent. After the open, documentSymbol answers in 1.36 to 1.39 s in total and a code action in 1.54 to 1.58 s. The overload fixes of stage S3a left it unchanged (1.36 to 1.60 s against 1.36 to 1.91 s in paired runs). Before stage S15 the open took 15 to 25 s, because `lint_deprecated` and `lint_test_attribute` scanned every top-level declaration for each identifier, and documentSymbol, a code action and inlay hints took 17 to 26 s, 25 to 34 s and 51 s. A synthetic 2 MB file (16,000 procedures, 64,000 hints) answers inlay hints in 5.7 s, against 144 s before.
- **Known limit: code actions recompute `lint_fixes`, `simplifications` and `stdlib_matches` per request.** A code action on the 2 MB file costs 0.2 s or less beyond the open, so no cache was added. A cache keyed by document version would also need invalidation on every reparse and every config change.

### Crashes not reduced

- **Known limit: a code action on a 1.8 MB generated file segfaulted once, an unreduced crash that does not reproduce on 95b77b09.** The first sweep saw the server killed by SIGSEGV after about 8 s when the package also held odin-godot's `libgd/classdb/bind.odin` (F26 in `docs/corpus/findings-B.md`). The clone does have `libgd/classdb/bind.gen.odin` (145.7 KB, tracked in git); the earlier note that it was missing was wrong. The recheck rebuilt the setup in a scratch directory `big12`: an `ols.json` with collection `godot` at `.`, copies of `godot/` and `gdext/`, and `libgd/classdb/` with `bind.odin`, `bind.gen.odin` and a 1.79 MB `big.gen.odin`. It tried three forms of `big.gen.odin`: the whole `bind.gen.odin` 12 times, one header followed by 12 copies of its body, and one header followed by 12 bodies whose top-level names carry a per-copy suffix. `REQ_TIMEOUT=120 python3 docs/corpus/triage/lsp_one.py big12 big12/libgd/classdb/big.gen.odin codeAction 20 5` answered in 0.9 s in all 9 runs, 3 per form. A code action at 20:5 and at 224:9 answered in 0.9 to 1.5 s on 95b77b09 and with stage S8. The sweep's scratch copy was not kept, so its exact form is unknown.

### Odin compiler and test environment

- **Known limit: `for x in m[k]` over a map index fails when `k` is missing, an Odin compiler bug.** On Odin dev-2026-09 the loop never ended. On dev-2026-10 (`84bc3fc21`) it crashes with SIGSEGV (exit 139) with and without `-o:none`, while copying the value to a local first still works. S16 grepped `src/`, `tests/` and `tools/` for ranges over an index expression and found no remaining site over a map (`importer_dirs` was already rewritten; `untyped_map` and `diagnostics` are enum-indexed arrays, and the rest index slices or fixed arrays). `lint_loops` reports the pattern. Draft upstream Odin issue, not filed:

  ```
  Title: `for x in m[k]` crashes when k is not in the map

  Context: odin version <paste `odin report`; seen with dev-2026-10:84bc3fc21, and dev-2026-09 hung instead>, OS/arch <paste>.
  Expected: ranging over a map index whose key is missing iterates the zero value (empty [dynamic]string), so the body never runs, as when the value is first copied to a local.
  Current: the first loop crashes with SIGSEGV (exit 139) on dev-2026-10, with and without -o:none and with -debug. On dev-2026-09 it never terminated. The second loop ends immediately.
  Repro:
  package main
  main :: proc() {
  	m := make(map[string][dynamic]string)
  	for d in m["x"] { _ = d } // crashes (dev-2026-10), never ends (dev-2026-09)
  	l := m["x"]
  	for d in l {} // ends
  }
  `odin run repro.odin -file` exits with 139; removing the first loop exits with 0.
  ```

- **Known limit: a test that panics or faults can hang in some agent sandboxes, whose fault handler rols cannot change (found in S16).** There the fault handler that the Odin runner relies on (`stop_test_callback` in `core:testing`) is not reached, and the faulting thread re-traps forever: `invert_if_early_exit_do_body` at `c5c8fa27^` panicked on a bounds check and then spun, and a C program with `SIGSEGV` and `SIGTRAP` handlers behaved the same. This is an environment issue, not a rols bug. On 2026-10-06 a scratch test with `panic("boom")` failed normally in about 0.1 ms, so not every session is affected. `ROLS_TEST_TIMEOUT=SECONDS ./build.sh test` (or `single_test`) now bounds a hang: on timeout it sends SIGKILL to the process group of `odin test`, its `tests` child included, and exits 1. Set it lower than any outer timeout (GNU `timeout`, a CI cancel, an agent tool limit): an outer kill of the `build.sh` process group does not reach the test group. Without the variable a hang still never ends, and a plain `kill` of the run does not stop it, because the runner's first SIGTERM only sets a flag. `kill -9` on the `tests` process does stop it.
