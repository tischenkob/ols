# Corpus validation

rols was run over seven open-source Odin projects and the Odin standard library on 2026-10-02, at rols `2c89a95a` with Odin `dev-2026-09:a2fb372b7` on macOS arm64. The sweep looked for crashes, hangs, edits that break `odin check`, false lints and wrong query results. This file records the corpus, the bugs that became failing tests, the follow-ups that did not, and how to repeat the sweep once the fixes land.

## Corpus

| Project | Commit | `ols.json` | What it stresses |
|---|---|---|---|
| [DanielGavin/ols](https://github.com/DanielGavin/ols) | `146d5e3dcc8bde5a23cf3a4893f30fc631d9d46e` | collection `src=src`, every `enable_checker_vet_*` key false | A large multi-package app with collections |
| [pmbanugo/tina](https://github.com/pmbanugo/tina) | `a2e8d4dc53394dd6772d08e79a41d6b56ba3a65e` | `{}` | Generics, unions, `when` blocks and per-platform files |
| [BuLEEto/Skald](https://github.com/BuLEEto/Skald) | `6bbb664b9f421c25aa9be4540d5c9dedd20d32ca` | collection `gui=.` | Large GUI code, overload groups, 66 packages |
| [karl-zylinski/karl2d](https://github.com/karl-zylinski/karl2d) | `0b8c66358a07261b259f724dae1d163830f2facc` | `{}` | Per-platform backends, `#+build` tags, `#+private file`, `foreign` |
| [odin-lang/examples](https://github.com/odin-lang/examples) | `dcc6128eca09e01e3585d9cbcb9a21b5cf621c22` | `{}` | 95 small packages, 78 of which pass `odin check` on macOS |
| [dresswithpockets/odin-godot](https://github.com/dresswithpockets/odin-godot) | `93395901a76f62a9f2adff76c2eb38a185d91513` | collection `godot=.`, `checker_args` `-vet -strict-style -define:REAL_PRECISION=single` | Large generated binding files |
| [laytan/odin-http](https://github.com/laytan/odin-http) | `fac113fbd828aad3d71479a534b5de4358b6a07b` | `{}` | Platform files and `@(test)` suites |
| Odin `core/` and `vendor/` | the installed `odin root` | none | Read-only: lint, symbols and LSP on 1568 files |

The sweep's raw material is in `docs/corpus/`. `findings-A.md` to `findings-D.md` are the four sweep reports, with corpus locations; their `/tmp/rols-corpus` paths point to scratch copies that were not kept. `triage/TRIAGE.md` lists every confirmed case. `triage/<case>/` holds its reduced source. `triage/cli.py` and `triage/edit.py` rerun the CLI and edit cases against `./ols`, and `triage/lsp_one.py` sends one LSP request for the inlay cases. `BRIEF.md` and `triage/TEST_BRIEF.md` are the briefs the sweep and the test writers followed.

odin-godot's own generated bindings could not be produced, because its generator no longer compiles with Odin `dev-2026-09`. The sweep used a synthetic 1.8 MB file instead.

## Bugs with a failing test

Each bug below has a test that fails today and passes once the bug is fixed. The reduced source of each case is in the test itself. At the time of writing, the 14 tests that `./build.sh test` reports as failing are exactly the tests below. The tests assume a darwin host, where the corpus ran: the build-tag cases use `linux` and `windows` files as the excluded platforms.

### Edits

| Test | File | Bug |
|---|---|---|
| `modernize_fill_slices_fixed_array` | `rols_modernize_test.odin` | `slice.fill(buf, v)` on a fixed array does not compile; an enumerated array cannot be sliced at all |
| `modernize_fill_skips_value_using_index` | `rols_modernize_test.odin` | `s[i] = i` becomes `slice.fill(s, i)` |
| `modernize_sum_skips_interval_range` | `rols_modernize_test.odin` | `for i in 1 ..= 10` becomes `math.sum(1 ..= 10)`, which does not parse |
| `modernize_redundant_parens_keeps_comment` | `rols_modernize_test.odin` | a comment inside the parentheses is deleted |
| `modernize_bool_return_keeps_comment` | `rols_modernize_test.odin` | a comment before the final `return true` is deleted |
| `modernize_nested_if_one_line_body_indents_with_tabs` | `rols_modernize_test.odin` | the merged one-line body is indented with tab, tab, space |
| `action_unwrap_not_offered_on_range_loop_using_its_variable` | `rols_action_unwrap_test.odin` | "Unwrap block" deletes a loop header the body depends on |
| `action_unwrap_not_offered_when_body_returns_before_statements` | `rols_action_unwrap_test.odin` | "Unwrap block" leaves unreachable code |
| `invert_if_one_line_body_indents_with_tabs` | `rols_action_invert_if_test.odin` | the moved body is indented with one space |
| `add_ok_result_updates_callers` | `rols_action_add_ok_result_test.odin` | callers keep one value and stop compiling |
| `add_ok_result_not_offered_with_or_return_on_unnamed_results` | `rols_action_add_ok_result_test.odin` | `or_return` needs named results once there are two |
| `generate_test_enum_result_uses_typed_zero_value` | `rols_generate_test_test.odin` | `expect_value(t, result, {})` does not compile for an enum |
| `action_add_explicit_type_slice_of_field` | `rols_action_add_explicit_type_test.odin` | `r := s.arr[:2]` becomes `r: arr = …` |
| `rename_package_rewrites_bare_package_name` | `rols_rename_package_test.odin` | `_ :: old` is not rewritten |

Some edit tests assert one of two acceptable fixes, and a comment in each says which. The comment tests assert "no fix". `add_ok_result_updates_callers` asserts that callers are updated. A fix that refuses the action instead must switch the assertion.

### Formatter

These are snapshot cases in `tools/odinfmt/tests`, run by `tools/odinfmt/tests.sh`. The suite stops at the first failing file, so fix them in this order to see each one fail.

| Case | Bug |
|---|---|
| `rols_disable_region_no_stray_line.odin` | a stray line holding one byte (`t`) appears above an `//odinfmt:disable` region, and the file no longer compiles |
| `rols_idempotent_comp_lit_comment.odin` | `x = T{a = {9, 9}} // c` is expanded with `} \t// c`, and a second pass changes it again |
| `rols_idempotent_semicolon_line.odin` | a long line of `;`-separated statements is split again on the second pass |

Each snapshot holds the second-pass layout. A fix that reaches a different fixed point needs a new snapshot.

## Follow-ups

These findings have no harness test, because they live in the CLI or the compile gate, depend on timing, or were not reduced. Each item names a repro.

### Hangs and crashes not reduced

- **A code action on a 1.8 MB generated file segfaults** when the package also contains odin-godot's `libgd/classdb/bind.odin`. The setup is in the sweep's scratch copy of `libgd/classdb`, with `bind.gen.odin` repeated 12 times. Possibly fixed by the default-parameter fix; not rechecked.

### Compile gate and checker

- **`checker_args` containing `-no-entry-point` drops every compiler error.** `check.odin` always adds `-no-entry-point` or `-file`, odin rejects the duplicate flag, the JSON parse fails, and `ols query check` exits 0. Repro: `ols.json` `{"checker_args": "-no-entry-point"}` and `f :: proc() { x: int = "s"; _ = x }`. odin-godot's checked-in `ols.json` has this setting.
- **The default `-vet-style` hides type errors and blinds the `--apply` gate.** A struct field list without a trailing comma (`a, b: int` on its own line) becomes a Syntax Error that stops checking. In Skald, a vendored file does this, so the gate saw the same error before and after an edit and wrote code that plain `odin check` rejects (`modernize` with a `slice.fill` on a fixed array, and "Unwrap block" leaving unreachable code). The gate should check without the style vets, or with the user's own flags. Upstream ols itself reports these Syntax Errors with the default config.
- **The gate rolls back safe edits when Odin reports pre-existing errors nondeterministically.** Two sources were seen. A package over Odin's error limit prints a different subset of errors on each run, because procedures are checked in parallel. A directory with two package names reports "Different package name" against whichever file Odin parses first. Repro: one safe `if (x > 0)` fix plus 60 procedures that each call an undeclared name; `ols query modernize --apply` exited 4, 4, 4, 0, 0 over five runs.
- **`-vet-unused-variables` findings show as `error`** while the other vet flags show as `warning`. `vet_messages` in `check.odin` lists only the shadowing and cast messages.

### CLI

- **A relative `--root` limits workspace searches to the current file.** `refs`, `callers`, `find` and `rename` with `--root .` miss other files, and a rename then rolls back. An absolute root, or no `--root`, works. Repro: `a.odin` declares and uses `helper`, `b.odin` also calls it, then run `ols query refs a.odin:3:1 --root .`.
- **`move --to` resolves a relative path against the declaration's directory**, unlike every other path argument, and refuses an absolute path that goes through a symlink such as macOS `/tmp`. Repro: `ols query move pkg/a.odin:3:1 --to pkg/b.odin` is refused, while `--to b.odin` works.
- **`symbols` text output is not stable and lacks the `file:` prefix** that the README contract states. Its order changes between runs because it follows map iteration.
- **`tests` and `check` with no argument read only the cwd package.** At a root without `.odin` files, `tests` exits 1 and `check` prints an error with an empty file path and exits 0. `check` also exits 0 when it reports errors.
- **`test DIR NAME` exits 0 when no test matches the name.**
- **`tests` lists tests from `#+build ignore` files but drops `_windows.odin` files.**
- **A symbol path cannot name the package in the cwd.** `.Name` and `./Name` are refused.
- **`find` omits `@(private)`, `#+private` and other-platform declarations**, which hides most of karl2d's backend code.
- **`reorder-params` refusals list six possible reasons at once**, and the README does not list them.

### Performance

- **The formatter is quadratic in the number of elements of one composite literal.** 16,000 elements take 0.95 s and 32,000 take 3.8 s. Formatting `core/rexcode/isa/ppc/tablegen/generated/decode_tables.odin` (950 KB) takes 11 to 13 s.
- **documentSymbol and code actions are slow on 2 MB files.** On `core/rexcode/isa/ppc/mnemonic_builders.odin`, documentSymbol takes 20 s and each code action 8 s, even where no action applies.
- **`ols query symbols FILE` indexes the whole package** before it outlines one file. A 55 KB file with one symbol takes 2.7 s.

### Lint heuristics and noise

- **`error-not-last` fires on any enum with a `None` member.** That shape is also common for non-error enums such as `Kind :: enum { None, Box }`.
- **`lock-by-value` fires on `curr_state: Atomic_Mutex_State`** in `core/sync/primitives_atomic.odin`, an enum. It did not reproduce outside `core:sync`.
- **`unused-parameter` fires on procedures whose signature a callback type fixes.** Most hits in Skald, tina and examples are handlers passed as values, or per-platform implementations.
- **`float-equality` fires on comparisons with a literal `0` or `1`.** These are 118 of 145 Skald hits and bury the real ones.
- **`naming` fires on C bindings and on LSP protocol structs** whose names must stay camelCase. This accounts for most naming hits in ols and karl2d.
- **`ignored-result` prints an absolute package path** for a type from a package that the file does not import, and prints `(Error)` without the `os.` qualifier.

### Edits

- **"Inline procedure call" inlines a body that calls a `@(private="file")` procedure into another file**, and the result does not compile. Repro: `a.odin` has `@(private = "file") norm :: proc(v: int) -> int` and `draw :: proc(x, y: int) { _ = norm(x); _ = y }`, and `b.odin` calls `draw(1, 2)`. Run `ols query actions b.odin:4:2`. The harness cannot show it: `find_proc_lit` in `rols_action_inline_proc.odin` builds its `Call_Hierarchy` with no files, so a callee in another file is read from disk, and the harness's in-memory files are never seen. Passing `ctx.files` there would make the case testable. The same gap applies to types: a typed local or a `T(lit)` cast copies the parameter's type text from the callee file, so a package-qualified type such as `time.Duration` needs an import the caller file may lack.
- **"Invert if" on an `if` without `else` leaves an empty then-branch** (`if !c {} else {…}`). It compiles but is not a useful rewrite.
- **Duplicate action titles** such as "Use compound assignment" and "Merge nested if" make `--apply TITLE` ambiguous. "Add doc comment" also writes `// name ` with a trailing space.
- **`redundant-parens` on a multi-line condition** leaves the opening brace on its own line, or an empty line before `}`. The result compiles.
- **The odinfmt snapshot suite ignores failures in subdirectories.** `snapshot_directory` in `tools/odinfmt/snapshot/snapshot.odin` drops the result of its recursive call, so `tools/odinfmt/tests.sh` exits 0 after a mismatch in a subdirectory. A mismatch also leaves `.snapshots/*_failed` files that git does not ignore.
- **The harness's `expect_*` procs leak their message builders when an assertion fails**, so a failing test also reports memory leaks under `ODIN_TEST_FAIL_ON_BAD_MEMORY`.
- **The upstream ols test suite hung for more than 20 minutes** on the tree that `modernize --apply` rewrote. This was not investigated.

## Findings in the corpus itself

The lints found real bugs in the projects. They are listed here so that a rerun does not mistake them for false positives.

- `core/flags/internal_validation.odin:121` passes its last two `printf` arguments in the wrong order.
- `vendor/wasm/WebGL/webgl.odin:402` `CompressedTexImage2DSlice` calls itself.
- `core/encoding/base32/base32.odin:195` allocates with `allocator` and frees with the context allocator.
- `print-directive` hits in odin-lang/examples (`nbio/udp-echo`, `sdl3/microui`) and karl2d (`log.error` with `%v`).

## Rerunning the sweep

Run the sweep again after the bugs above are fixed.

1. Run `./build.sh test`. Every test listed under "Bugs with a failing test" must pass.
2. Run `tools/corpus_smoke.sh`, and `tools/corpus_smoke.sh --lsp` for the stdio pass. The script clones the corpus at the pinned commits into `${ROLS_CORPUS_DIR:-$HOME/.cache/rols-corpus}`. It runs the baseline `odin check`, `check`, `lint`, `symbols`, `modernize --apply` with a plain `odin check` afterwards, and the formatter round trip. It exits 1 and prints one `FAIL` line per problem. A run on the pinned commits should end with no `FAIL` lines.
3. Repeat the manual checks that the script does not automate, on two or three projects:
   - Rename a package proc, a struct field used through `using`, an enum member used inside call arguments, and a local, each with `--apply`.
   - Run `move`, `reorder-params`, `rename-package` on a leaf package, and `attr add`.
   - Request `actions` at about 15 positions, apply each offered action, and run `odin check`.
   - Sample about 15 lint hits per project and judge them by reading the code.
4. Move each fixed follow-up out of this file. Add a test for any new bug the rerun finds.

To move the corpus forward, update the commits in `tools/corpus_smoke.sh` and in the table above together. Then run step 2 on the old commits and the new ones, and record any change in the baseline package list.
