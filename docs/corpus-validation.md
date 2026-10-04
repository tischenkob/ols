# Corpus validation

rols was run over seven open-source Odin projects and the Odin standard library on 2026-10-02, at rols `2c89a95a` with Odin `dev-2026-09:a2fb372b7` on macOS arm64. The sweep looked for crashes, hangs, edits that break `odin check`, false lints and wrong query results. This file records the corpus, the bugs that became failing tests (the edit bugs are fixed, the formatter cases remain), the follow-ups that did not, and how to repeat the sweep once the fixes land.

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

Each bug below has a snapshot case that fails today and passes once the bug is fixed. The reduced source of each case is in the case itself. Every bug that had a harness test is fixed: `./build.sh test` reports no failures. The tests assume a darwin host, where the corpus ran: the build-tag cases use `linux` and `windows` files as the excluded platforms.

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
- **`-vet-unused-variables` findings still show as `error`** while the other vet flags show as `warning`. Odin prints the same text, `declared but not used`, without a vet flag for `if c { x := 1 }`, which is a compile error, and the JSON output cannot tell the two apart. `map_diagnostic_severity` in `check.odin` therefore keeps the message as an error. An AST check of the position could tell them apart.

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

- **`unused-parameter` misses a callback type that another file fixes.** The lint skips a procedure that its own file uses as a value (an argument, an assignment, a composite literal element), and a literal passed to a call, stored in a composite literal or assigned. A handler registered from a second file of the package still reports. Checking that needs a scan of the package's open or indexed files for each hit. A sweep of ols and karl2d went from 159 hits to 71; the rest are mostly per-platform implementations that a struct of procedures in another file selects.
- **`naming` still fires on C names that carry no marker.** The lint skips `foreign` blocks, `@(link_name)`, `@(export)` and tagged struct fields. LSP protocol structs in ols (`workspaceFolders`, `rootUri`, 116 field hits) have no tag or attribute, and karl2d's `platform_bindings` load their C functions with `dlopen` instead of `foreign`, so 193 karl2d hits and 175 ols hits remain. A marker for these would need a new attribute or comment convention, so no rule was added.

### Edits

- **"Invert if" on an `if` without `else` leaves an empty then-branch** (`if !c {} else {…}`). This is upstream OLS's tested behavior (`action_invert_if_simple_edit`), kept for compatibility.
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

1. Run `./build.sh test`, which must report no failures, and `tools/odinfmt/tests.sh`, where every case listed under "Bugs with a failing test" must pass.
2. Run `tools/corpus_smoke.sh`, and `tools/corpus_smoke.sh --lsp` for the stdio pass. The script clones the corpus at the pinned commits into `${ROLS_CORPUS_DIR:-$HOME/.cache/rols-corpus}`. It runs the baseline `odin check`, `check`, `lint`, `symbols`, `modernize --apply` with a plain `odin check` afterwards, and the formatter round trip. It exits 1 and prints one `FAIL` line per problem. A run on the pinned commits should end with no `FAIL` lines.
3. Repeat the manual checks that the script does not automate, on two or three projects:
   - Rename a package proc, a struct field used through `using`, an enum member used inside call arguments, and a local, each with `--apply`.
   - Run `move`, `reorder-params`, `rename-package` on a leaf package, and `attr add`.
   - Request `actions` at about 15 positions, apply each offered action, and run `odin check`.
   - Sample about 15 lint hits per project and judge them by reading the code.
4. Move each fixed follow-up out of this file. Add a test for any new bug the rerun finds.

To move the corpus forward, update the commits in `tools/corpus_smoke.sh` and in the table above together. Then run step 2 on the old commits and the new ones, and record any change in the baseline package list.
