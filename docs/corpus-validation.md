# Corpus validation

rols was run over seven open-source Odin projects and the Odin standard library on 2026-10-02, at rols `2c89a95a` with Odin `dev-2026-09:a2fb372b7` on macOS arm64. The sweep looked for crashes, hangs, edits that break `odin check`, false lints and wrong query results. This file records the corpus, the follow-ups that did not become harness tests (every bug that did is fixed), and how to repeat the sweep.

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

## Follow-ups

These findings have no harness test, because they live in the CLI or the compile gate, depend on timing, or were not reduced. Each item names a repro.

### Formatter

- **`fits` measures a later statement under the enclosing group's break mode.** A group nested in the rest of the document inherits `Break`, so the first `break_with("", true)` inside it (an index expression, for example) ends the measure early. That made a `;`-joined line fit when it did not. The fix keeps the last one-line statement of a `;` chain in one piece (`enforce_fit`), and a `Fit` group now measures with its breaks as spaces. A middle statement is still measured the old way. Other callers of `fits` do too, and treating nested rest groups as flat changes `tests/calls.odin`, so it needs its own review.
- **A `;`-joined statement after the first line of a block is never wrapped, and a split one is not stable.** The group that holds the `; ` break is skipped when the parent mode is flat and no newline was just emitted. Repro: in a `case` body, `x := 1` followed by `a := 1; long_call(…)` wider than the width stays on one line, and a first-statement `a := 1; long_call(…); b := 2` prints the call wrapped on `a := 1; long_call(`, and the second pass splits it at the `;` with the call on one over-width line. The third pass wraps the arguments again, and the output keeps alternating. The base formatter behaves the same, and `rols_semicolon_line_middle_over_width.odin` holds the stable layout.
- **A disabled struct field still starts its region at the line start.** `visit_struct_field_list` emits `info.text` without the comment-offset rule that `visit_disabled` has, so a multi-line field that ends on a trailing `// odinfmt:disable` line prints its end twice.
- **Other `visit_begin_brace` callers key the Indent comment option on the line only.** The comp lit and matrix comp lit cases are fixed. Repro to check: `s := struct{a: int}{} // c`, and the same with a trailing comment after the closing brace of an enum, union or block that opens on that line.

### Hangs and crashes not reduced

- **A code action on a 1.8 MB generated file segfaults** when the package also contains odin-godot's `libgd/classdb/bind.odin`. The setup is in the sweep's scratch copy of `libgd/classdb`, with `bind.gen.odin` repeated 12 times. Possibly fixed by the default-parameter fix; not rechecked.

### Performance

- **Opening a 2 MB file takes 1.3 to 2.4 s.** The lints resolve every node of `core/rexcode/isa/ppc/mnemonic_builders.odin` (13,308 declarations), about 2 s of it. Before S15 the open took 15 to 25 s, because `lint_deprecated` and `lint_test_attribute` scanned every top-level declaration for each identifier. After the open, documentSymbol answers in about 1.6 to 2.1 s, a code action in 1.5 s and inlay hints in 1.8 s (before: 17 to 26 s, 25 to 34 s and 51 s). A synthetic 2 MB file (16,000 procedures, 64,000 hints) answers inlay hints in 5.7 s, against 144 s before.
- **A file that names a large enum is slow to open.** `ppc/mnemonics.odin` (55 KB) takes about 3 s because the whole-file resolve rebuilds the enum symbol for each use. `ols query symbols FILE` now opens the file without lints and answers in 0.5 s for that file and 0.3 s for the 2 MB one (before: 3.4 s and 14.2 s), with identical output on 14 files.

### Lint heuristics and noise

- **`unused-parameter` misses a callback type that another file fixes.** The lint skips a procedure that its own file uses as a value (an argument, an assignment, a composite literal element), and a literal passed to a call, stored in a composite literal or assigned. A handler registered from a second file of the package still reports. Checking that needs a scan of the package's open or indexed files for each hit. A sweep of ols and karl2d went from 159 hits to 71; the rest are mostly per-platform implementations that a struct of procedures in another file selects.
- **`naming` still fires on C names that carry no marker.** The lint skips `foreign` blocks, `@(link_name)`, `@(export)` and tagged struct fields. LSP protocol structs in ols (`workspaceFolders`, `rootUri`, 116 field hits) have no tag or attribute, and karl2d's `platform_bindings` load their C functions with `dlopen` instead of `foreign`, so 193 karl2d hits and 175 ols hits remain. A marker for these would need a new attribute or comment convention, so no rule was added.

### Edits

- **"Invert if" on an `if` without `else` leaves an empty then-branch** (`if !c {} else {…}`). This is upstream OLS's tested behavior (`action_invert_if_simple_edit`), kept for compatibility.
- **The harness's `expect_*` procs leak their message builders when an assertion fails**, so a failing test also reports memory leaks under `ODIN_TEST_FAIL_ON_BAD_MEMORY`.
- **The upstream ols test suite hung for more than 20 minutes** on the tree that `modernize --apply` rewrote. This was not investigated.

## Findings in the corpus itself

The lints found real bugs in the projects. They are listed here so that a rerun does not mistake them for false positives.

- `core/flags/internal_validation.odin:121` passes its last two `printf` arguments in the wrong order.
- `vendor/wasm/WebGL/webgl.odin:402` `CompressedTexImage2DSlice` calls itself.
- `core/encoding/base32/base32.odin:195` allocates with `allocator` and frees with the context allocator.
- `print-directive` hits in odin-lang/examples (`nbio/udp-echo`, `sdl3/microui`) and karl2d (`log.error` with `%v`).

## Rerunning the sweep

Run the sweep again after the follow-ups above are settled.

1. Run `./build.sh test` and `tools/odinfmt/tests.sh`, which must both report no failures.
2. Run `tools/corpus_smoke.sh`, and `tools/corpus_smoke.sh --lsp` for the stdio pass. The script clones the corpus at the pinned commits into `${ROLS_CORPUS_DIR:-$HOME/.cache/rols-corpus}`. It runs the baseline `odin check`, `check`, `lint`, `symbols`, `modernize --apply` with a plain `odin check` afterwards, and the formatter round trip. It exits 1 and prints one `FAIL` line per problem. A run on the pinned commits should end with no `FAIL` lines.
3. Repeat the manual checks that the script does not automate, on two or three projects:
   - Rename a package proc, a struct field used through `using`, an enum member used inside call arguments, and a local, each with `--apply`.
   - Run `move`, `reorder-params`, `rename-package` on a leaf package, and `attr add`.
   - Request `actions` at about 15 positions, apply each offered action, and run `odin check`.
   - Sample about 15 lint hits per project and judge them by reading the code.
4. Move each fixed follow-up out of this file. Add a test for any new bug the rerun finds.

To move the corpus forward, update the commits in `tools/corpus_smoke.sh` and in the table above together. Then run step 2 on the old commits and the new ones, and record any change in the baseline package list.
