# Corpus validation

rols was run over seven open-source Odin projects and the Odin standard library on 2026-10-02, at rols `2c89a95a` with Odin `dev-2026-09:a2fb372b7` on macOS arm64. The sweep looked for crashes, hangs, edits that break `odin check`, false lints and wrong query results. A rerun on 2026-10-04 at rols `5d2021f9` (after stages S1 to S16) used the same Odin version and the same pinned commits, and so did a second rerun on 2026-10-05 at rols `ac740c8c` (after stages S17 to S22 and the sweep over mirage). A third rerun on 2026-10-06 at rols `223ee8e2` checked the fixes of the 2026-10-05 findings with the same setup. This file records the corpus, the rerun results, the follow-ups that have no passing harness test, and how to repeat the sweep.

## Corpus

| Project | Commit | `ols.json` | What it stresses |
|---|---|---|---|
| [DanielGavin/ols](https://github.com/DanielGavin/ols) | `146d5e3dcc8bde5a23cf3a4893f30fc631d9d46e` | collection `src=src`, every `enable_checker_vet_*` key false | A large multi-package app with collections |
| [pmbanugo/tina](https://github.com/pmbanugo/tina) | `a2e8d4dc53394dd6772d08e79a41d6b56ba3a65e` | `checker_variants` `-define:TINA_SIM=true` (since 2026-10-06, after that day's rerun) | Generics, unions, `when` blocks and per-platform files |
| [BuLEEto/Skald](https://github.com/BuLEEto/Skald) | `6bbb664b9f421c25aa9be4540d5c9dedd20d32ca` | collection `gui=.` | Large GUI code, overload groups, 66 packages |
| [karl-zylinski/karl2d](https://github.com/karl-zylinski/karl2d) | `0b8c66358a07261b259f724dae1d163830f2facc` | `{}` | Per-platform backends, `#+build` tags, `#+private file`, `foreign` |
| [odin-lang/examples](https://github.com/odin-lang/examples) | `dcc6128eca09e01e3585d9cbcb9a21b5cf621c22` | `{}` | 95 small packages, 78 of which pass `odin check` on macOS |
| [dresswithpockets/odin-godot](https://github.com/dresswithpockets/odin-godot) | `93395901a76f62a9f2adff76c2eb38a185d91513` | collection `godot=.`, `checker_args` `-vet -strict-style -define:REAL_PRECISION=single` | Large generated binding files |
| [laytan/odin-http](https://github.com/laytan/odin-http) | `fac113fbd828aad3d71479a534b5de4358b6a07b` | `{}` | Platform files and `@(test)` suites |
| Odin `core/` and `vendor/` | the installed `odin root` | none | Read-only: lint, symbols and LSP on 1568 files |

The sweep's raw material is in `docs/corpus/`. `findings-A.md` to `findings-D.md` are the four sweep reports, with corpus locations; their `/tmp/rols-corpus` paths point to scratch copies that were not kept. `triage/TRIAGE.md` lists every confirmed case. `triage/<case>/` holds its reduced source. `triage/cli.py` and `triage/edit.py` rerun the CLI and edit cases against `./ols`, and `triage/lsp_one.py` sends one LSP request for the inlay cases. `BRIEF.md` and `triage/TEST_BRIEF.md` are the briefs the sweep and the test writers followed.

odin-godot's own generated bindings could not be produced, because its generator no longer compiles with Odin `dev-2026-09`. The sweep used a synthetic 1.8 MB file instead.

## Rerun on 2026-10-06

`./build.sh test` (2491 tests), `./odinfmt.sh` and `tools/odinfmt/tests.sh` passed. `tools/corpus_smoke.sh --lsp` reported 1 `FAIL` line, against 5 on 2026-10-05: the known `pt_rescale` corpus bug in `crypto/_weierstrass` (see "Findings in the corpus itself"). The formatter, symbols, `modernize` and LSP passes were clean in every project, and so were the tina `TINA_SIM` checks that the script now runs.

| project | packages | baseline | check/lint | symbols | modernize | format | lsp |
|---|---|---|---|---|---|---|---|
| ols | 33 | 14 | 33/33 | 155/155 | 42 files | ok | ok 155 |
| tina | 8 | 7 | 8/8 | 121/121 | 24 files | ok | ok 121 |
| Skald | 66 | 66 | 66/66 | 175/175 | 30 files | ok | ok 175 |
| karl2d | 56 | 53 | 56/56 | 102/102 | 14 files | ok | ok 102 |
| examples | 95 | 78 | 95/95 | 140/140 | 17 files | ok | ok 140 |
| odin-godot | 14 | 3 | 14/14 | 41/41 | 4 files | ok | ok 41 |
| odin-http | 14 | 11 | 14/14 | 39/39 | 4 files | ok | ok 39 |
| core | 264 | 245 | 263/264 | 1281/1281 | 209 files | ok | ok 1281 |

The 4 `lint false error` lines that the script blamed on a parent package on 2026-10-05 are gone, so karl2d and odin-http now read 56/56 and 14/14. core's `modernize` now applies its fixes on a scratch copy: 209 files changed and no package that compiled before broke. Seven core packages whose scratch copy meets the real `core:` collection were skipped for format and `modernize`, as designed.

A run without `--lsp` just before reported one more line: `FAIL ols modernize breaks src/testing` with `core/sync/chan/chan.odin:382` "'where' clause evaluated to false". This is the Odin checker flake that the 2026-10-04 rerun recorded, not a rols bug. The same error failed 1 of 40 plain `odin check src/testing` runs on a pristine copy of ols and 2 of 40 on a copy that `modernize --apply` rewrote, and the `--lsp` run's `modernize` step passed.

The manual checks ran on scratch copies of karl2d and tina, with `odin check` after each edit on every target the edit touched. tina was checked on the default target, with `-define:TINA_SIM=true`, and on `linux_amd64`, `windows_amd64` and `freebsd_amd64`. On karl2d's `linux_amd64` and `windows_amd64` targets, `vendor:stb` reports that its compiled libraries are missing, before and after every edit; those targets were compared by error count.

| Check | Result |
|---|---|
| rename a package proc (`calculate_frame_time`, karl2d; `prng_init`, tina) | applied, 3 edits in 2 files and 14 edits in 4 files, clean. Only comments keep the old name |
| rename a field used through `using` (`FD_Entry_Payload.writer_isolate`, tina) | 20 edits in 6 files, applied 3 of 3 times, clean on all five tina configurations. karl2d `Window_Render_Glue.viewport_resized`: 6 edits in 6 files, clean |
| rename an enum member used inside call arguments (`Mouse_Button.Left`, karl2d; `Exit_Kind.Normal`, tina) | 47 edits in 19 files, also gated on `js_wasm32`, every `.Left` of other enums untouched; tina 9 edits in 5 files. Both clean |
| rename a local (`now`, karl2d; `local_seed` and `next` in a nested proc, tina) | applied, clean. Renaming `now` to `time` is refused because the local would shadow the `time` import. `local_seed` rolled back in 3 of 16 runs, counted by hand during the session (see Follow-ups: gate flake) |
| `move` | karl2d `rect_middle` to a new file: applied, and the new file carries `#+vet explicit-allocators`. To `render_backend_gl.odin`: refused, different build constraints. tina `prng_uint_less_than` to a new file: clean. tina `prng_step`: refused, it uses the file-private `_rotl_u64` |
| `reorder-params` (`point_in_rect`, karl2d; `fd_table_handoff`, tina) | 31 edits in 6 files and 25 edits in 4 files, clean. tina's multi-line parameter list is joined into one line (see Follow-ups: cosmetic edit output) |
| `rename-package` on a leaf package | karl2d `platform_bindings/linux/evdev`: 47 edits and the directory rename, also gated on `linux_amd64`, clean. karl2d `gamecontroller`: refused, its clause `karl2d_darwin_gamecontroller` differs from the directory name. tina `datastar`: 3 edits and the directory rename; `tests` and the package are clean, `examples` keeps its 11 baseline errors |
| `attr add` (`require_results`, karl2d `rect_middle`, tina `prng_uint_less_than`) | applied, clean |
| `actions` at 23 positions in karl2d and 17 in tina, every offered action applied on a scratch copy | 94 applications. 92 were clean. In karl2d, 2 "Generate test" applications broke `js_wasm32`, a new bug, since fixed: the created test file now gets `#+build !js` when another file of the package builds only on js, and the compile gate checks the targets of the files next to a touched one (test `generate_test_new_file_excludes_targets_without_core_testing`). The 62 tina applications were clean on all five configurations and on `tests` |
| sample of lint hits, one per lint code (18 hits over 18 codes in karl2d; 17 hits over 16 codes in tina, where two of its three unused-import hits were judged) | 30 correct, 5 debatable noise: `+ 0` in a layout constant and an index, `==` on a stored `f64` timestamp, naming on a C callback parameter, and an unused `route_context` parameter of tina's API wrappers |
| edit to a `#+build` file | tina `_linux_deinit_quiesced` in a `#+build linux` file: applied, also gated on `linux_amd64`, clean. tina `_backend_deinit`: all 5 platform variants renamed (8 edits), clean on all five configurations. karl2d `web_state_size` in a `#+build js` file: also gated on `js_wasm32`, clean |

`docs/corpus/triage/cli.py` reported 46 of 46 cases clean and `edit.py` 16 of 16. None of the 2026-10-05 bugs that were fixed on 2026-10-06 reappeared in these checks, and their harness tests passed. The "Cosmetic edit output" items still reproduce, and so does the gate flake. Timed by hand with `/usr/bin/time`, `ols query lint` answered in 1.35 s on `ppc/mnemonic_builders.odin` and in 0.18 s on `winerror.odin`, so the large-enum fix of S22 holds and its follow-up is closed.

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

Beyond the script, `modernize --apply --no-check` ran on scratch copies of all eight trees, `core` included, followed by `odin check` of every package that passed before. A second `modernize` listed nothing in any tree, so every default fix applied. A text search of the results for the forms that the `migration` rules replace found only strings, comments and files that already carry the `#+feature` tag. In core, `nested-if`, `array-broadcast` and three `use-stdlib` rules broke four packages that compiled before. The script missed these because it ran core as a dry run. Since 2026-10-06 it applies the fixes on a scratch copy of core.

The manual checks of "Rerunning the sweep" ran on karl2d, tina and ols, with `odin check` on every target that the edit touched. tina was also checked with `-define:TINA_SIM=true`, because its simulation code sits in `when` blocks that the default build skips. These checks applied about 195 code actions at about 100 positions without a crash or hang. They also ran about 30 refactor commands and judged 61 lint hits by reading the code. 55 hits were correct and 6 were debatable noise: naming on C callback parameters, float equality in comparators, and a layout constant summed with `+ 0`. `docs/corpus/triage/cli.py` reported 46 of 46 cases clean and `edit.py` 16 of 16. Each new bug, the core breaks above included, was reproduced on a reduced file. All but "Cosmetic edit output" were fixed on 2026-10-06, each with a harness test.

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

These findings have no passing harness test, and each item names a repro. Most live in the CLI, the compile gate or the sweep script, depend on timing, or were not reduced.

### Formatter

- **A one-line `if` with `;` statements in both blocks opens only the `else` block.** When only the `else` part of `if x {a(); b()} else {c(); d()}` overflows, the `else` block opens and `if x {a(); b()} else {` stays on one line (`core/rexcode/isa/arm32/tools/verify_against_llvm.odin:581` in `core`).

### Hangs and crashes not reduced

- **A code action on a 1.8 MB generated file segfaulted: not reproduced on 95b77b09.** The first sweep saw the server killed by SIGSEGV after about 8 s when the package also held odin-godot's `libgd/classdb/bind.odin` (F26 in `docs/corpus/findings-B.md`). The clone does have `libgd/classdb/bind.gen.odin` (145.7 KB, tracked in git); the earlier note that it was missing was wrong. The recheck rebuilt the setup in a scratch directory `big12`: an `ols.json` with collection `godot` at `.`, copies of `godot/` and `gdext/`, and `libgd/classdb/` with `bind.odin`, `bind.gen.odin` and a 1.79 MB `big.gen.odin`. It tried three forms of `big.gen.odin`: the whole `bind.gen.odin` 12 times, one header followed by 12 copies of its body, and one header followed by 12 bodies whose top-level names carry a per-copy suffix. `REQ_TIMEOUT=120 python3 docs/corpus/triage/lsp_one.py big12 big12/libgd/classdb/big.gen.odin codeAction 20 5` answered in 0.9 s in all 9 runs, 3 per form. A code action at 20:5 and at 224:9 answered in 0.9 to 1.5 s on 95b77b09 and with stage S8. The sweep's scratch copy was not kept, so its exact form is unknown.

### Performance

- **Opening a 2 MB file takes 1.3 to 1.5 s.** The lints resolve every node of `core/rexcode/isa/ppc/mnemonic_builders.odin` (13,308 declarations), about 1.1 to 1.2 s of it. Stage S8 measured open plus hover at 1.31 to 1.52 s. The "Large-file performance" section of `FOLLOWUPS.md` holds the current numbers. Before S15 the open took 15 to 25 s, because `lint_deprecated` and `lint_test_attribute` scanned every top-level declaration for each identifier. After the open, documentSymbol answers in about 1.4 s, a code action in 1.5 to 1.6 s and inlay hints in 1.3 to 1.4 s (before S15: 17 to 26 s, 25 to 34 s and 51 s). A synthetic 2 MB file (16,000 procedures, 64,000 hints) answers inlay hints in 5.7 s, against 144 s before.

### Lint heuristics and noise

- **`unused-parameter` misses a callback type that another file fixes.** The lint skips a procedure that its own file uses as a value (an argument, an assignment, a composite literal element), and a literal passed to a call, stored in a composite literal or assigned. A handler registered from a second file of the package still reports. Checking that needs a scan of the package's open or indexed files for each hit. A sweep of ols and karl2d went from 159 hits to 71; the rest are mostly per-platform implementations that a struct of procedures in another file selects.
- **Known limit: `naming` fires on C names in a file without a `foreign import`.** The lint skips `foreign` blocks, `@(link_name)`, `@(export)`, tagged struct fields, parameters of a procedure type with a non-Odin calling convention, and type, field, enum member and constant names in a file with a `foreign import`. LSP protocol structs in ols (`workspaceFolders`, `rootUri`, 116 field hits) have no tag or attribute, and karl2d's `platform_bindings` load their C functions with `dlopen` instead of `foreign`, so those hits remain. Skipping them would need a new attribute or comment marker, which other OLS clients and the Odin compiler do not know, so it would break drop-in compatibility.

### Edits

- **Cosmetic edit output** (2026-10-05). `reorder-params` joins a multi-line parameter list into one line (tina: `ols query reorder-params src/allocator_io_fd_table.odin:168:1 --order 3,2,1,0`). `move` puts the imports it adds in a new group above the existing imports, with `src:` paths among `core:` ones (ols: `ols query move src/common/uri.odin:35:1 --to src/common/position.odin`). "Inline procedure call" can leave redundant parentheses (karl2d: `karl2d.odin:5723:20` gives `s.mouse_button_went_down[(.Left)]`). The `unused-declaration` message names the directory instead of the package clause (karl2d copied to a directory `lintcopy`: `render_backend_gl.odin:704` says "never used in package lintcopy" for `package karl2d`).
- **"Invert if" on an `if` without `else` leaves an empty then-branch** (`if !c {} else {…}`). This is upstream OLS's tested behavior (`action_invert_if_simple_edit`), kept for compatibility.

## Findings in the corpus itself

The lints found real bugs in the projects. They are listed here so that a rerun does not mistake them for false positives.

- `core/flags/internal_validation.odin:121` passes its last two `printf` arguments in the wrong order.
- `vendor/wasm/WebGL/webgl.odin:402` `CompressedTexImage2DSlice` calls itself.
- `core/encoding/base32/base32.odin:195` allocates with `allocator` and frees with the context allocator.
- `core/crypto/_weierstrass/point.odin:545` calls `pt_rescale(&tmp)` with one argument, but `pt_rescale` takes two. The procedure is polymorphic and nothing instantiates the caller, so Odin does not report it.
- `render_backend_d3d11.odin:837` in karl2d repeats the condition of line 831, so that branch never runs. `src/server/requests.odin:590` in ols passes one printf argument too many.
- `print-directive` hits in odin-lang/examples (`nbio/udp-echo`, `sdl3/microui`) and karl2d (`log.error` with `%v`).

## Rerunning the sweep

At `223ee8e2`, `tools/corpus_smoke.sh --lsp` ended with one `FAIL` line, the `pt_rescale` corpus bug, which stays until the corpus fixes it. The script counts a lint line only for the directory that holds its file, because `ols query lint DIR` also covers the packages below `DIR`. A `modernize breaks` line that quotes `core/sync/chan/chan.odin:382` "'where' clause evaluated to false" is an Odin checker flake, seen in about 1 of 12 checks of pristine ols. The line comes from the script's own plain `odin check` after `modernize --apply --no-check`, which the compile gate never sees, and a rerun of `tools/corpus_smoke.sh ols` usually clears it. `has_decl` skips raw strings and any file with a top-level `when`, and the core format and `modernize` steps skip a package whose scratch copy meets the real `core:` collection (`odin/parser` in a manual check on 2026-10-06).

1. Run `./build.sh test` and `tools/odinfmt/tests.sh`, which must both report no failures. `ROLS_TEST_TIMEOUT=SECONDS` makes `./build.sh test` kill a run that hangs.
2. Run `tools/corpus_smoke.sh`, and `tools/corpus_smoke.sh --lsp` for the stdio pass. The script clones the corpus at the pinned commits into `${ROLS_CORPUS_DIR:-$HOME/.cache/rols-corpus}`. It runs the baseline `odin check`, `check`, `lint`, `symbols`, `modernize --apply` with a plain `odin check` afterwards (on a scratch copy for core), and the formatter round trip. For tina it also runs `odin check src -define:TINA_SIM=true` after the baseline, the format step and `modernize`. It exits 1 and prints one `FAIL` line per problem. A run on the pinned commits should end with only the `pt_rescale` corpus line.
3. Repeat the manual checks that the script does not automate, on two or three projects:
   - Rename a package proc, a struct field used through `using`, an enum member used inside call arguments, and a local, each with `--apply`.
   - Run `move`, `reorder-params`, `rename-package` on a leaf package, and `attr add`.
   - Request `actions` at about 15 positions, apply each offered action, and run `odin check`.
   - Sample about 15 lint hits per project and judge them by reading the code.
   - Check an edit to a `#+build` file on the targets it builds for.
4. Move each fixed follow-up out of this file. Add a test for any new bug the rerun finds.

To move the corpus forward, update the commits in `tools/corpus_smoke.sh` and in the table above together. Then run step 2 on the old commits and the new ones, and record any change in the baseline package list.
