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
- `tools/cli_smoke.sh`
- `tools/invert_if_smoke.sh`
- `tools/save_imports_smoke.py`
- `misc/claude-plugin/`: `.claude-plugin/plugin.json`, `.lsp.json`, `skills/ols/SKILL.md`
- `CLAUDE.md`
- `FORK.md`
- `.claude/skills/rebase/SKILL.md`

Whole fork-only package: `src/cli`.

Confirm with `git diff --name-status upstream/master..HEAD | grep '^A' | grep -v '\.odin$'`.

## Hook points in upstream files

Registration:

- `src/server/action.odin`: `action_procs` table plus the fork action run, package file collection for cross-file actions, the shared edit builder and the import edits organize-on-save reuses.
- `src/server/requests.odin`: `call_map` entries for the fork handlers.

Config:

- `src/common/config.odin`: range formatting, extra inlay hint kinds, fork code action, lint, lens and checker flags, client file-creation support.
- `src/server/types.odin`: the same flags as `Maybe(bool)` in `OlsConfig`.
- `src/server/requests.odin`: initialize-option merge for those flags, and `apply_default_config` holding every default so the CLI can reuse them.

Capabilities:

- `src/server/requests.odin`: initialize response: range formatting, fork action kinds and providers, the hint kinds that turn the provider on, organize-on-save and file-creation client support.
- `src/server/types.odin`: capability and payload types for the fork requests, server-initiated request payloads, and the named response union that lets `workspace/applyEdit` be sent.

CLI:

- `src/main.odin`: `ols query` dispatch and the reused logger.

Rewritten procs:

- `src/server/response.odin`: all four senders frame through `write_message`; ids for server-initiated requests.
- `src/server/lens.odin`: `textDocument/codeLens` handler and the budgeted reference sweep.
- `src/server/file_resolve.odin`: the resolve cache gets its own arena and heap-allocated symbols so the map can hold pointers.
- `src/server/references.odin`: reference search callable without a cursor, and the shared file list the code lens uses.
- `src/server/action_invert_if_statements.odin`: takes an `ActionContext`, offers the early-exit variant, keeps labels, do-bodies and indentation.
- `src/testing/testing.odin`: selection sources, a shared document fixture, a checker stand-in, and the `expect_*` assertions for the fork features.

Small fixes:

- `src/server/analysis.odin`: `@(deprecated)` sets the deprecated flag.
- `src/server/locals.odin`: no preallocation for name groups.
- `src/server/symbol.odin`: symbols stored by pointer in the resolve map.
- `src/server/ast.odin`: end positions for `break` and `continue`.
- `src/server/build.odin`: drop stale symbols on removal and reindex.
- `src/server/generics.odin`: keep procedure tags when solving a generic.
- `src/server/writer.odin`: framed write of one message.
- `src/server/diagnostics.odin`: fork producers, and the merge that runs under the lock.
- `src/server/hover.odin`: struct layout and field offsets.
- `src/server/inlay_hints.odin`: fork hint kinds, enclosing procedure tracking, and a resolve context built only when a kind needs it.
- `src/server/check.odin`: never block the request thread, drain the pipe incrementally, reap killed processes, vet and style flags from the config, vet findings as warnings.
- `src/server/documents.odin`: resolve cache arena lifetime, reject a change before touching the document, refresh lint diagnostics.

Tests:

- `tests/action_invert_if_test.odin`: the early-exit variant and the fork behaviour.
- `tests/inlay_hints_test.odin`: the fork hint kinds.

## Fork-only config keys

Regenerate with:

```bash
diff <(git show upstream/master:misc/ols.schema.json | grep -o '"enable_[a-z_]*"' | sort -u) <(grep -o '"enable_[a-z_]*"' misc/ols.schema.json | sort -u) | grep '^>' | tr -d '>" '
```

### `enable_code_action_*` (28)

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
- `enable_code_action_rewrite_expression`
- `enable_code_action_split_merge_if`
- `enable_code_action_ternary`
- `enable_code_action_unwrap`

### `enable_lint_*` (30)

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
- `enable_linked_editing`
- `enable_organize_imports_on_save`
- `enable_range_format`
- `enable_selection_range`

## Fork-only LSP requests

Client-to-server, added to `call_map`:

- `textDocument/rangeFormatting`
- `textDocument/foldingRange`
- `textDocument/selectionRange`
- `textDocument/linkedEditingRange`
- `textDocument/implementation`
- `textDocument/prepareCallHierarchy`
- `textDocument/codeLens`
- `callHierarchy/incomingCalls`
- `callHierarchy/outgoingCalls`

Server-to-client:

- `workspace/applyEdit`: sent by `src/server/rols_save_imports.odin` for organize-imports on save.

Confirm with `git diff upstream/master..HEAD -- src/server/requests.odin | grep '^+.*"textDocument/\|^+.*"callHierarchy/\|^+.*"workspace/'`.

## Fork sections in README.md

- `## Command line queries`
- `### Claude Code`

The fork's option bullets in README are the config keys listed above.
