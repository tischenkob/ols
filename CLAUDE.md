# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`rols`: a fork of the Odin language server [DanielGavin/ols](https://github.com/DanielGavin/ols). Branch `rols`, remote `upstream`. Sync with `git rebase upstream/master`. Keep it drop-in compatible with OLS: clients that must keep working are Zed, Helix and the Claude Code LSP plugin.

Fork rules:
- New features go in new files. Touch upstream files only at hook points: the `action_procs` table in `action.odin`, `requests.odin`, `config.odin`, `types.odin`, `misc/ols.schema.json`, `main.odin`.
- One `enable_*` config key per feature, default true, documented in README.md.
- Tests use the OLS harness in `src/testing`, never a separate runner.

## Commands

Needs `odin` on PATH (repo tracks Odin master).

```bash
./build.sh                      # build ./ols (release)
./build.sh debug                # build with -debug
./build.sh test                 # all tests in tests/
./build.sh single_test NAME     # one test; NAME is the proc name, package prefix optional, comma-separated for several
./odinfmt.sh                    # build ./odinfmt
tools/odinfmt/tests.sh          # formatter snapshot tests (separate suite)
./install.sh                    # install to ~/.local/bin/ols (wrapper sets OLS_BUILTIN_FOLDER, execs ols-bin)
```

Smoke scripts after a build: `tools/cli_smoke.sh` (every `ols query` subcommand), `OLS=./ols tools/invert_if_smoke.sh` (invert-if round trips through `odin check`), `python3 tools/save_imports_smoke.py` (organize-imports on save over real stdio).

The binary needs the `builtin/` folder next to it or `OLS_BUILTIN_FOLDER` set. Tests use `tests/builtin/`.

Format Odin code with `odinfmt` (config in `odinfmt.json`: tabs, width 120).

## Architecture

Entry `src/main.odin`: `ols version`, `ols query …` (runs `src/cli/cli.odin`), otherwise stdio LSP. `src/session` is an empty stub.

Threads (`src/server/requests.odin`): a reader thread parses JSON-RPC frames into a queue; the main thread runs every handler serially from `call_map`; a checker thread runs `odin check` subprocesses (`check.odin`). The indexer and build cache are thread-local to the main thread. After each request the index cache is cleared and `context.temp_allocator` is freed, so anything that outlives a request must not live in temp memory.

Data flow for a request:
1. `documents.odin`: `Document` holds text, the parsed `ast.File` and a per-document arena. Any change reparses the whole file (no incremental parsing), then runs parser diagnostics, unused-import checks and lints.
2. `position_context.odin`: `get_document_position_context` walks the AST to the cursor and records every enclosing node that matters. The `hint` argument changes what counts as "at" the cursor.
3. `analysis.odin`: `AstContext` is the resolution environment (locals, globals, imports, current package). `resolve_type_expression` turns an expression into a `Symbol`, looking up locals, then globals, then the indexer. Poly params are solved in `generics.odin`.
4. `file_resolve.odin`: `resolve_entire_file` resolves every node of an open document once into a map keyed by node pointer, cached on the document. Semantic tokens, inlay hints, lints and references read that map instead of resolving per node.

Indexing (`build.odin`, `indexer.odin`, `collector.odin`, `symbol.odin`): a `Symbol` is a name, range, package and a `SymbolValue` union holding unresolved AST. Only `builtin` and `runtime` are indexed at startup; other packages index lazily when first referenced. `index_file` reindexes one file on save.

Diagnostics (`diagnostics.odin`): one global map per producer type (syntax, lint, unused, check). `publishDiagnostics` sends the union per URI, so a slow `odin check` never wipes fast results. Shadowing warnings come from `-vet-shadowing` passed to the checker; other lints are in-server tables in `lint.odin`, `lint_naming.odin`, `lint_unused.odin`, each gated by its own `enable_lint_*` flag.

Config: `common.Config` (`src/common/config.odin`) holds plain values. `OlsConfig` in `src/server/types.odin` mirrors it with `Maybe(bool)` so unset is distinguishable. `apply_default_config` in `requests.odin` sets defaults, then `<exe_dir>/ols.json`, `initializationOptions` and `<workspace>/ols.json` merge in that order, last wins.

Formatter: `src/odin/printer` builds a Wadler-style document tree; `src/odin/format` wraps it. The server's `textDocument/formatting` and `tools/odinfmt` both call it. Snapshot tests in `tools/odinfmt/tests` are its test suite.

## Adding a feature

Config flag, all six files: bool in `src/common/config.odin`, `Maybe(bool)` in `src/server/types.odin`, default plus merge line in `src/server/requests.odin`, entry in `misc/ols.schema.json`, option in README.md, early return in the feature file. See the `enable_code_action_move_decl` commit for the shape.

Code action: a new `src/server/action_<name>.odin` with `#+private file`, one `@(private = "package") add_<name>_action :: proc(ctx: ^ActionContext)` that returns early on its flag, then appended to `action_procs` in `action.odin`. `ActionContext` and the shared edit helpers (`range_of`, `node_text`, `reindent`, `fresh_name`, `append_replace_range`, …) live in `src/server/edit.odin`. Cross-file refactorings that the CLI also calls keep their engine in a plain file (`change_signature.odin`, `move_decl.odin`) and a thin `action_*.odin` wrapper.

Test: `tests/<feature>_test.odin` using `src/testing`. A `Source` has `main` with a `{*}` cursor or `{[ … ]}` selection, optional extra `files` and `packages`, and `config` to enable the flag. Assert with the matching `expect_*` proc (`expect_action_applied`, `expect_hover`, `expect_lint_diagnostics`, …). Multi-package tests set `collections = {"core" = "test"}` and inline a `BUILTINS` string because the harness has no runtime package.

CLI: `src/cli/cli.odin` builds the workspace in-process and calls the same `server.get_*` procs as the LSP handlers. `--apply` writes edits with `common.apply_text_edits`.
