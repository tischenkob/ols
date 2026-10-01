---
name: ols
description: Navigate, refactor, check and test Odin code with the ols language server through the LSP tool and `ols query`. Use whenever reading or editing .odin files.
---

# ols

Positions are `file:line:col`, 1-based, columns in bytes, in every input and output. `ols query` with no arguments lists the commands.

## Find code with the server, not grep

- LSP tool: `workspaceSymbol` (fuzzy, half a name is enough), `goToDefinition`, `findReferences`, `incomingCalls`, `hover`.
- Without the LSP tool: `ols query find NAME`, `def`, `refs`, `callers`, `callees`, `hover FILE:LINE:COL`.

## Learn a package without reading its source

- `ols query api core:strings` lists the exported symbols with the first line of each doc comment.
- `ols query api core:strings clone` prints one full signature and doc comment.
- Any directory or collection path works, `ols query api src/game` included.

## After every edit

- `ols query check DIR` prints compiler errors and lints without building or running. Fix everything it prints.
- `ols query lint FILE` when the package does not compile yet.

## Refactor with edits, not by hand

- `ols query actions FILE:LINE:COL` lists what applies at a position, `FILE:L:C-L:C` at a selection. `--apply "TITLE"` writes one.
  Available: extract variable, procedure or constant, inline, introduce or remove parameter, generate procedure, generate test, fill struct, add `or_return`, invert if, and more.
- `ols query rename FILE:LINE:COL NEW --apply`, `reorder-params FILE:LINE:COL --order 1,0 --apply` and `move FILE:LINE:COL --to other.odin --apply` update every use across the workspace.
- They also take a symbol path instead of `FILE:LINE:COL`: `ols query rename src/game.Player.hp health`, `core:strings.clone`. `PKG.Name` or `PKG.Name.Member`, where Member is a struct field, enum member or bit_field field.
- `rename` refuses a keyword, an invalid identifier, a builtin name, a name already declared in the same scope, a name that would capture or be captured at a use site, a declaration in `core:`, `vendor:`, `base:` or outside the workspace, and a package qualifier. A `warning:` names filter-skipped files that still contain the old name.
- Without `--apply` they print a unified diff and change nothing. Read it before applying.
- `--apply` writes every file or none. It runs `odin check` on the touched packages and restores every file when the edit adds an error.
- Exit codes: 0 applied or previewed, 1 refused (each `error:` line says why), 2 usage, 3 nothing to change, 4 rolled back after new check errors.
- `ols query modernize [DIR]` lists the exact idiom rewrites (simplifications, core library calls) for every file; `--diff` shows them, `--apply` writes them and adds the imports they need, checked and with the exit codes above. `--list` prints the rules; `--rule ID,…` picks rules or families, like `review` for the fixes that delete code.

## Tests

- `ols query tests DIR` lists the `@(test)` procedures.
- `ols query test DIR [name,...]` runs them with the collections and defines of `ols.json`.
- On a procedure name, `ols query actions FILE:LINE:COL --apply "Generate test for NAME"` adds a stub to `<file>_test.odin`.
