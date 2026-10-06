# Corpus validation

rols was run over seven open-source Odin projects and the Odin standard library on 2026-10-02, at rols `2c89a95a` with Odin `dev-2026-09:a2fb372b7` on macOS arm64. The sweep looked for crashes, hangs, edits that break `odin check`, false lints and wrong query results. A rerun on 2026-10-04 at rols `5d2021f9` (after stages S1 to S16) used the same Odin version and the same pinned commits, and so did a second rerun on 2026-10-05 at rols `ac740c8c` (after stages S17 to S22 and the sweep over mirage). This file records the corpus, the rerun results, the follow-ups that have no passing harness test, and how to repeat the sweep.

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

## Rerun on 2026-10-05

`./build.sh test` (2382 tests) and `tools/odinfmt/tests.sh` passed. `tools/corpus_smoke.sh --lsp` reported 5 `FAIL` lines, against 48 on 2026-10-04. The formatter, symbols and LSP passes were clean in every project.

| project | packages | baseline | check/lint | symbols | modernize | format | lsp |
|---|---|---|---|---|---|---|---|
| ols | 33 | 14 | 33/33 | 155/155 | 44 files | ok | ok 155 |
| tina | 8 | 7 | 8/8 | 121/121 | 25 files | ok | ok 121 |
| Skald | 66 | 66 | 66/66 | 175/175 | 30 files | ok | ok 175 |
| karl2d | 56 | 53 | 54/56 | 102/102 | 14 files | ok | ok 102 |
| examples | 95 | 78 | 95/95 | 140/140 | 17 files | ok | ok 140 |
| odin-godot | 14 | 3 | 14/14 | 41/41 | 4 files | ok | ok 41 |
| odin-http | 14 | 11 | 13/14 | 39/39 | 4 files | ok | ok 39 |
| core | 264 | 245 | 262/264 | 1281/1281 | dry run | ok | ok 1281 |

All 5 `FAIL` lines are `lint false error` lines, and none is a false positive. One is the known `pt_rescale` corpus bug, reported for `crypto/_weierstrass`. The other 4 come from the script. `ols query lint DIR` now covers every package directory below `DIR`, but the script still blames each error on the package it linted, and that package compiles. The `pt_rescale` line appears a second time for `crypto`. karl2d `build_web/web_entry_templates/web_entry_template.odin:15` (`ex.init()` without arguments) appears twice, and odin-http `examples/tcp_echo/main.odin:7` imports `../../nbio/poly`, which does not exist. `odin check` fails both leaf packages with the same errors.

Beyond the script, `modernize --apply --no-check` ran on scratch copies of all eight trees, `core` included, followed by `odin check` of every package that passed before. A second `modernize` listed nothing in any tree, so every default fix applied. A text search of the results for the forms that the `migration` rules replace found only strings, comments and files that already carry the `#+feature` tag. In core, `nested-if`, `array-broadcast` and three `use-stdlib` rules broke four packages that compiled before (see Follow-ups, "Edits"). The script misses these because it runs core as a dry run.

The manual checks of "Rerunning the sweep" ran on karl2d, tina and ols, with `odin check` on every target that the edit touched. tina was also checked with `-define:TINA_SIM=true`, because its simulation code sits in `when` blocks that the default build skips. These checks applied about 195 code actions at about 100 positions without a crash or hang. They also ran about 30 refactor commands and judged 61 lint hits by reading the code. 55 hits were correct and 6 were debatable noise: naming on C callback parameters, float equality in comparators, and a layout constant summed with `+ 0`. `docs/corpus/triage/cli.py` reported 46 of 46 cases clean and `edit.py` 16 of 16. The new bugs are under Follow-ups. Each one was reproduced on a reduced file.

## Rerun on 2026-10-04

`./build.sh test` (2236 tests) and `tools/odinfmt/tests.sh` passed before the sweep. `tools/corpus_smoke.sh` and `tools/corpus_smoke.sh --lsp` then reported 48 `FAIL` lines. The LSP pass added none: every file of every project answered all requests without a crash, hang or error (`ok` in the last column).

| project | packages | baseline | check/lint | symbols | modernize | format | lsp |
|---|---|---|---|---|---|---|---|
| ols | 33 | 13 or 14 | 33/33 | 155/155 | 44 files | ok | ok 155 |
| tina | 8 | 7 | 8/8 | 120/121 | 25 files | 1 bad | ok 121 |
| Skald | 66 | 66 | 66/66 | 174/175 | 30 files | 1 bad | ok 175 |
| karl2d | 56 | 53 | 56/56 | 102/102 | 14 files | ok | ok 102 |
| examples | 95 | 78 | 95/95 | 140/140 | 17 files | ok | ok 140 |
| odin-godot | 14 | 3 | 14/14 | 41/41 | 4 files | ok | ok 41 |
| odin-http | 14 | 11 | 14/14 | 39/39 | 4 files | ok | ok 39 |
| core | 264 | 245 | 261/264 | 1279/1281 | dry run | 17 bad | ok 1281 |

The ols baseline was 13 in one run and 14 in the other, so one ols package passes `odin check` only some of the time (the Odin checker is multi-threaded). The other baseline counts did not change between the two runs.

Classification of the 48 `FAIL` lines:

- **1 `core lint false error`: a corpus bug.** `crypto/_weierstrass/point.odin:545` calls `pt_rescale(&tmp)` with one argument for a two-parameter polymorphic procedure. Odin does not check the body of a procedure that nothing instantiates, so this is a true positive in the corpus (see "Findings in the corpus itself"). The 24 other lines were the multi-value call argument bug, fixed in stage S18.
- **2 `format not idempotent` in tina and Skald: two rols formatter bugs (fixed in stage S19).** The tina file holds `when COND { a; long_call(...) }` on one line (test `rols_when_block_semicolon_line`). The Skald file holds `E :: struct { f: int } // c` (test `rols_idempotent_struct_trailing_comment`).
- **9 `format not idempotent` and 2 `format breaks` in core.** The idempotence cases are four more instances of the struct trailing comment bug (`c/libc/threads.odin`, `rexcode/ir/spirv/builder.odin`, `rexcode/ir/spirv/tablegen/gen.odin`, `sys/darwin/Foundation/NSWindow.odin`), a comment above the first parameter of a procedure type (`text/match/strlib.odin`, test `rols_proc_type_param_leading_comment`), trailing comments on foreign procedure parameters (`sys/posix/arpa_inet.odin`, test `rols_foreign_proc_param_trailing_comment`), a block comment after a case list (`odin/parser/parser.odin`, test `rols_case_clause_block_comment`), and two cases that stage S19 reduced: trailing comments in a multi-line `|` chain (`rexcode/isa/arm32/immediates.odin`, test `rols_idempotent_binary_trailing_comment`) and comments in a multi-line `+` argument (`testing/runner.odin`, test `rols_idempotent_call_arg_comments`). The 2 `format breaks` lines (`rexcode/isa/riscv/tablegen`, with and without `cpp-compiler`) are a real formatter bug: `odinfmt` rewrites the triple-backtick raw string ``LOADER_TYPES :: ```…``` `` at `gen.odin:364` into ``` ``; ` ```, which does not parse (fixed in stage S19, test `rols_triple_backtick_raw_string`). The script no longer reports the former 6 `Duplicate declaration of package` lines: it skips a core package whose formatted copy meets the real `core:` collection.

Manual checks on scratch copies of karl2d, tina and ols (`odin check` after each applied edit):

| Check | Result |
|---|---|
| rename a package proc (`calculate_frame_time`, karl2d) | applied, 3 edits, `odin check` clean |
| rename a field used through `using` (`FD_Entry_Payload.writer_isolate`, tina) | applied, 18 edits in 5 files, clean. One of five runs rolled back (see Follow-ups: gate flake) |
| rename an enum member used inside call arguments (`Mouse_Button.Left`, karl2d) | fixed in S18 (test `rename_safe_enum_member_in_call_inside_binary_expression`): the selector inside a call that is an operand of any binary operator now takes its type from the parameter |
| rename a local (`now`, karl2d) | applied, clean |
| `move` | refused with a reason that names the file-private symbol (fixed in S18) |
| `reorder-params` (`point_in_rect`, karl2d) | 31 edits in 6 files, clean |
| `rename-package` (`cocoa_extras`, karl2d) | applied, clean. A leaf package whose clause differs from its directory name (ols `spall`, `format`, karl2d `log`) is refused with a correct reason |
| `attr add` (`require_results`, karl2d) | applied, clean |
| `actions` at 15 positions in each of karl2d, tina and ols; every offered action applied on a scratch copy | 45 positions, about 55 applications. Three broke `odin check`, since fixed (see below) |
| sample of 15 lint hits per project (karl2d, tina, ols) | all 45 judged correct by reading the code. Real corpus bugs found: `render_backend_d3d11.odin:837` repeats the condition of line 831, ols `requests.odin:590` passes one printf argument too many |

Three action bugs found here (counter type of "Convert to C-style for", builtin type qualified by "Add explicit type", name clash of "Use named results") were fixed in stage S18 and checked with `ols query actions --apply` on scratch copies of tina and ols.

Two actions in ols (`Invert if` at `analysis.odin:3390`, `populate remaining switch cases` at `:4951`) once failed with an error in `core/sync/chan/chan.odin:382`; three reruns of the first one did not reproduce it. It is an Odin checker flake.

Fixed since the first sweep, checked on the rerun: the upstream ols test suite no longer hangs on the tree that `modernize --apply` rewrites (1054 tests, all passed in 1 s under a 900 s alarm). The first sweep's other follow-ups still reproduce, except as noted below.

## Follow-ups

These findings have no passing harness test, and each item names a repro. Most live in the CLI, the compile gate or the sweep script, depend on timing, or were not reduced. The items dated 2026-10-05 under "Edits" are reduced and can become harness tests.

### Formatter

- **`fits` measures a later statement under the enclosing group's break mode.** A group nested in the rest of the document inherits `Break`, so the first `break_with("", true)` inside it (an index expression, for example) ends the measure early. That made a `;`-joined line fit when it did not. The fix keeps the last one-line statement of a `;` chain in one piece (`enforce_fit`), and a `Fit` group now measures with its breaks as spaces. A middle statement is still measured the old way. Other callers of `fits` do too, and treating nested rest groups as flat changes `tests/calls.odin`, so it needs its own review.
- **A `;`-joined statement after the first line of a block is never wrapped, and a split one is not stable.** Stage S19 fixed the one-line block (`when C { a; long_call(…) }`, test `rols_when_block_semicolon_line`): it opens a normal block when it does not fit. A `case` body is still affected. The group that holds the `; ` break is skipped when the parent mode is flat and no newline was just emitted. Repro: in a `case` body, `x := 1` followed by `a := 1; long_call(…)` wider than the width stays on one line, and a first-statement `a := 1; long_call(…); b := 2` prints the call wrapped on `a := 1; long_call(`, and the second pass splits it at the `;` with the call on one over-width line. The third pass wraps the arguments again, and the output keeps alternating. The base formatter behaves the same, and `rols_semicolon_line_middle_over_width.odin` holds the stable layout. The same one-line block under `if` or `for` (`if C { a; long_call(…) }`) still prints on one line. The cause is not traced.
- **Formatting an empty `.odin` file writes a newline.** `ols/tests/builtin/intrinsics.odin` is empty. The first `odinfmt` pass writes `\n` into it, and the second pass fails with "Expected a package declaration at the start of the file".

### Hangs and crashes not reduced

- **A code action on a 1.8 MB generated file segfaults** when the package also contains odin-godot's `libgd/classdb/bind.odin`. The setup is in the sweep's scratch copy of `libgd/classdb`, with `bind.gen.odin` repeated 12 times. Possibly fixed by the default-parameter fix. The rerun could not recheck it: the clone has no `bind.gen.odin` (its generator does not compile with this Odin), and the scratch copy was not kept. The LSP pass sent a code action at three positions in every file of the clone, including the 3 odin-godot packages, with no crash.

### Performance

- **Opening a 2 MB file takes 1.3 to 2.4 s.** The lints resolve every node of `core/rexcode/isa/ppc/mnemonic_builders.odin` (13,308 declarations), about 2 s of it. Before S15 the open took 15 to 25 s, because `lint_deprecated` and `lint_test_attribute` scanned every top-level declaration for each identifier. After the open, documentSymbol answers in about 1.6 to 2.1 s, a code action in 1.5 s and inlay hints in 1.8 s (before: 17 to 26 s, 25 to 34 s and 51 s). A synthetic 2 MB file (16,000 procedures, 64,000 hints) answers inlay hints in 5.7 s, against 144 s before.
- **A file that names a large enum was slow to open (fixed in S22).** `core/sys/windows/winerror.odin` (313 KB, a documented enum of about 5,000 members) timed out in the LSP pass: documentSymbol after didOpen took 19.9 to 31 s, and `ols query lint` took 17.6 s. The whole-file resolve rebuilt the enum member table for every use of a member, and each build rescanned every comment of the file, because a missed doc or trailing comment lookup reset its search start to 0. `AstContext.enum_value_cache` now holds the table per enum node, and `get_field_docs_and_comments` keeps its search start on a miss and stops at the first later comment. Now documentSymbol answers in 0.04 s and `ols query lint` in 0.17 s, with byte-identical lint output on 40 files of `core`, `os` and `vendor/vulkan`. Test: `rols_lint_large_documented_enum` (3,000 documented members; 99.6 s before, 0.05 s after). `ols query symbols FILE` skips the lints and answers in 0.5 s for `ppc/mnemonics.odin` and 0.3 s for the 2 MB file (before: 3.4 s and 14.2 s).

### Lint heuristics and noise

- **`unused-parameter` misses a callback type that another file fixes.** The lint skips a procedure that its own file uses as a value (an argument, an assignment, a composite literal element), and a literal passed to a call, stored in a composite literal or assigned. A handler registered from a second file of the package still reports. Checking that needs a scan of the package's open or indexed files for each hit. A sweep of ols and karl2d went from 159 hits to 71; the rest are mostly per-platform implementations that a struct of procedures in another file selects.
- **`naming` still fires on C names that carry no marker.** The lint skips `foreign` blocks, `@(link_name)`, `@(export)` and tagged struct fields. LSP protocol structs in ols (`workspaceFolders`, `rootUri`, 116 field hits) have no tag or attribute, and karl2d's `platform_bindings` load their C functions with `dlopen` instead of `foreign`, so 193 karl2d hits and 175 ols hits remain. A marker for these would need a new attribute or comment convention, so no rule was added.

### Edits

- **The compile gate rolls back on a nondeterministic error set.** `ols query rename tina/src/io_types.odin:287:2 sink_isolate --apply` in a scratch copy of tina rolled back once in five runs: `odin check` of tina's `examples` directory, which already fails, reports 8 to 11 redeclaration errors in varying order and with varying members, and the gate saw a "new" one. The gate warns that the directory already has errors but still compares them. Repro: `for i in 1 2 3 4 5 6; do odin check examples -no-entry-point 2>&1 | grep -c Error; done` in tina. On the 2026-10-05 rerun it rolled back 10 of 29 gated tina edits in `src`, since every edit there re-checks `examples`. The same rerun found two more sources of spurious rollbacks in ols. `odin check tools/odinfmt` already fails with "Different package name", and the file it names varies (1 run in 10 names the other). Also, `core/sync/chan/chan.odin:382` "'where' clause evaluated to false" appears in about 1 of 12 checks of pristine ols. Rechecking a package before a rollback would absorb both. The same rollback on an extra target, such as every `--apply` that touched a `#+build wasm32` file of mirage's `internal/gfx` while native-only importers failed in `core:os` on `js_wasm32`, is fixed: the gate no longer checks a package on an extra target where its baseline reports an error outside the workspace. The current-target case above stays open.
- **A symbol-path target ignores `#+build ignore`.** `ols query rename .Mouse_Button.Left Primary` in karl2d is refused with `Mouse_Button is declared 2 times`, because `karl2d.doc.odin` (`#+build ignore`) declares it too. The position form (`karl2d.odin:6567:2`) works. The lookup that resolves a `PKG.Name` target should skip files that the build tags exclude, as the lints do.
- **Cosmetic edit output** (2026-10-05). `reorder-params` joins a multi-line parameter list into one line (tina: `ols query reorder-params src/allocator_io_fd_table.odin:168:1 --order 3,2,1,0`). `move` puts the imports it adds in a new group above the existing imports, with `src:` paths among `core:` ones (ols: `ols query move src/common/uri.odin:35:1 --to src/common/position.odin`). "Inline procedure call" can leave redundant parentheses (karl2d: `karl2d.odin:5723:20` gives `s.mouse_button_went_down[(.Left)]`). The `unused-declaration` message names the directory instead of the package clause (karl2d copied to a directory `lintcopy`: `render_backend_gl.odin:704` says "never used in package lintcopy" for `package karl2d`).
- **"Invert if" on an `if` without `else` leaves an empty then-branch** (`if !c {} else {…}`). This is upstream OLS's tested behavior (`action_invert_if_simple_edit`), kept for compatibility.

### Sweep script and environment

- **The script blames a child package's lint errors on its parent.** `ols query lint DIR` walks every package below `DIR`. The script lints each package directory and treats any lint error as false when that directory compiles. Four of the five `FAIL` lines of the 2026-10-05 rerun come from this. The fifth is the `pt_rescale` corpus line. The script should count only lines whose file sits directly in the linted directory.
- **The script runs `modernize` on core as a dry run only.** It never checks whether the edits compile, so the core breaks of `nested-if`, `array-broadcast` and `use-stdlib` under "Edits" passed unnoticed. Run `modernize --apply --no-check` on a scratch copy of core, then `odin check` the packages that passed before.
- **tina's simulation code builds only with `-define:TINA_SIM=true`.** Neither the gate nor the script checks it. When rerunning by hand, add `odin check src -no-entry-point -define:TINA_SIM=true`.
- **`modernize` walks hidden directories, but `lint` skips them.** In ols it makes 18 fixes in `tools/odinfmt/tests/.snapshots/*.odin`, which rewrites the formatter's snapshot fixtures. The README documents the skip for `lint` and says nothing about hidden directories for `modernize`.
- **Upstream: the Odin root lookup can pick a directory.** `requests.odin` joins the workspace path with `odin` and uses the result if it exists. In a copy of `core`, that is the `core/odin` package directory, so each run prints "sh: …/core/odin: is a directory" and resolves with a degraded root. With a correct `odin_command`, one more fix appears (`reflect/types.odin:827`, `redundant-partial`).

## Findings in the corpus itself

The lints found real bugs in the projects. They are listed here so that a rerun does not mistake them for false positives.

- `core/flags/internal_validation.odin:121` passes its last two `printf` arguments in the wrong order.
- `vendor/wasm/WebGL/webgl.odin:402` `CompressedTexImage2DSlice` calls itself.
- `core/encoding/base32/base32.odin:195` allocates with `allocator` and frees with the context allocator.
- `core/crypto/_weierstrass/point.odin:545` calls `pt_rescale(&tmp)` with one argument, but `pt_rescale` takes two. The procedure is polymorphic and nothing instantiates the caller, so Odin does not report it.
- `render_backend_d3d11.odin:837` in karl2d repeats the condition of line 831, so that branch never runs. `src/server/requests.odin:590` in ols passes one printf argument too many.
- `print-directive` hits in odin-lang/examples (`nbio/udp-echo`, `sdl3/microui`) and karl2d (`log.error` with `%v`).

## Rerunning the sweep

At `ac740c8c`, `tools/corpus_smoke.sh --lsp` ends with the 5 `lint false error` lines of "Rerun on 2026-10-05". One is the `pt_rescale` corpus line, and the other 4 are true errors that the script blames on a parent package (see "Sweep script and environment"). Once the script attributes lint lines to their own package, only the `pt_rescale` corpus line should remain. `has_decl` skips raw strings and any file with a top-level `when`, and the core format step skips a package that meets the real `core:` collection.

1. Run `./build.sh test` and `tools/odinfmt/tests.sh`, which must both report no failures.
2. Run `tools/corpus_smoke.sh`, and `tools/corpus_smoke.sh --lsp` for the stdio pass. The script clones the corpus at the pinned commits into `${ROLS_CORPUS_DIR:-$HOME/.cache/rols-corpus}`. It runs the baseline `odin check`, `check`, `lint`, `symbols`, `modernize --apply` with a plain `odin check` afterwards (a dry run for core), and the formatter round trip. It exits 1 and prints one `FAIL` line per problem. A run on the pinned commits should end with no `FAIL` lines once the open items are fixed.
3. Repeat the manual checks that the script does not automate, on two or three projects:
   - Rename a package proc, a struct field used through `using`, an enum member used inside call arguments, and a local, each with `--apply`.
   - Run `move`, `reorder-params`, `rename-package` on a leaf package, and `attr add`.
   - Request `actions` at about 15 positions, apply each offered action, and run `odin check`.
   - Sample about 15 lint hits per project and judge them by reading the code.
   - Run `modernize --apply --no-check` on a scratch copy of core, then `odin check` the packages that passed before.
   - Check tina also with `-define:TINA_SIM=true`, and check an edit to a `#+build` file on the targets it builds for.
4. Move each fixed follow-up out of this file. Add a test for any new bug the rerun finds.

To move the corpus forward, update the commits in `tools/corpus_smoke.sh` and in the table above together. Then run step 2 on the old commits and the new ones, and record any change in the baseline package list.
