# Corpus validation

rols was run over seven open-source Odin projects and the Odin standard library on 2026-10-02, at rols `2c89a95a` with Odin `dev-2026-09:a2fb372b7` on macOS arm64. The sweep looked for crashes, hangs, edits that break `odin check`, false lints and wrong query results. A rerun on 2026-10-04 at rols `5d2021f9` (after stages S1 to S16) used the same Odin version and the same pinned commits. This file records the corpus, the rerun results, the follow-ups that have no passing harness test, and how to repeat the sweep.

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

- **25 `core lint false error`: 24 from one rols bug, 1 from a corpus bug.** 24 are the multi-value call argument bug (`io/multi.odin`, `io/util.odin`, `os/file_util.odin`), where `f(g())` with a `g` that returns two values counts as one argument. Test: `argument_count_expands_multi_value_call_argument`. The other one is `crypto/_weierstrass/point.odin:545`, which calls `pt_rescale(&tmp)` with one argument for a two-parameter polymorphic procedure. Odin does not check the body of a procedure that nothing instantiates, so this is a true positive in the corpus (see "Findings in the corpus itself").
- **2 `symbols empty outline` (tina `wall_clock_simulation.odin`, Skald `inspector.odin`) and 2 in core (`debug/trace/trace_instrumentation.odin`, `path/path_error.odin`): script problem.** `has_decl` in `tools/corpus_smoke.sh` counts a column-0 declaration inside a `when` block whose condition is false on this host, or text inside a raw string. `ols query symbols` correctly skips an inactive `when` branch.
- **2 `format not idempotent` in tina and Skald: two rols formatter bugs.** The tina file holds `when COND { a; long_call(...) }` on one line (test `rols_when_block_semicolon_line`). The Skald file holds `E :: struct { f: int } // c` (test `rols_idempotent_struct_trailing_comment`).
- **9 `format not idempotent` and 8 `format breaks` in core.** The idempotence cases are four more instances of the struct trailing comment bug (`c/libc/threads.odin`, `rexcode/ir/spirv/builder.odin`, `rexcode/ir/spirv/tablegen/gen.odin`, `sys/darwin/Foundation/NSWindow.odin`), a comment above the first parameter of a procedure type (`text/match/strlib.odin`, test `rols_proc_type_param_leading_comment`), trailing comments on foreign procedure parameters (`sys/posix/arpa_inet.odin`, test `rols_foreign_proc_param_trailing_comment`), a block comment after a case list (`odin/parser/parser.odin`, test `rols_case_clause_block_comment`), and two cases that were not reduced (see Follow-ups). The 8 `format breaks` lines are a script problem: the script copies `core/` away from `odin root`, so a package that imports its siblings through `core:` or relative paths meets two copies of the same package (`Duplicate declaration of package …`). The `riscv/tablegen/gen.odin` syntax error appears in the same copy. Check with `odinfmt` on the files directly before trusting such a line.

Manual checks on scratch copies of karl2d, tina and ols (`odin check` after each applied edit):

| Check | Result |
|---|---|
| rename a package proc (`calculate_frame_time`, karl2d) | applied, 3 edits, `odin check` clean |
| rename a field used through `using` (`FD_Entry_Payload.writer_isolate`, tina) | applied, 18 edits in 5 files, clean. One of five runs rolled back (see Follow-ups: gate flake) |
| rename an enum member used inside call arguments (`Mouse_Button.Left`, karl2d) | **wrong**: edits missed every `f(.Left)` that is an operand of `&&` or `\|\|`, and the gate rolled back (test `rename_safe_enum_member_in_call_inside_binary_expression`). Direct uses and calls outside a binary expression were renamed |
| rename a local (`now`, karl2d) | applied, clean |
| `move` | refused with a reason, but the reason prints an empty symbol name (test `move_decl_refused_when_using_file_private_symbol`) |
| `reorder-params` (`point_in_rect`, karl2d) | 31 edits in 6 files, clean |
| `rename-package` (`cocoa_extras`, karl2d) | applied, clean. A leaf package whose clause differs from its directory name (ols `spall`, `format`, karl2d `log`) is refused with a correct reason |
| `attr add` (`require_results`, karl2d) | applied, clean |
| `actions` at 15 positions in each of karl2d, tina and ols; every offered action applied on a scratch copy | 45 positions, about 55 applications. Three broke `odin check`: see below |
| sample of 15 lint hits per project (karl2d, tina, ols) | all 45 judged correct by reading the code. Real corpus bugs found: `render_backend_d3d11.odin:837` repeats the condition of line 831, ols `requests.odin:590` passes one printf argument too many |

The three action bugs, each with a failing test:

- **"Convert to C-style for" gives the counter type `int` for a bound of another integer type.** `for i in 0 ..< n` with `n: u32` becomes `for i := 0; i < n; i += 1` (tina `shard.odin:318` and `:2497`). Test `expand_range_keeps_non_int_bound_type`.
- **"Add explicit type" qualifies a builtin type with the callee's package.** `x := strings.contains(s, "a")` becomes `x: strings.bool = …` (ols `analysis.odin:2784`). Test `action_add_explicit_type_builtin_result_of_package_call`.
- **"Use named results" picks the name of a local that the body declares.** `-> Symbol` with `symbol := Symbol{…}` becomes `-> (symbol: Symbol)` and the body shadows it (ols `analysis.odin:4748`). Test `named_results_avoids_local_name`.

The CLI gate rolls back the first two, so `ols query actions --apply` is safe. A code action applied from an editor writes the broken edit.

Two actions in ols (`Invert if` at `analysis.odin:3390`, `populate remaining switch cases` at `:4951`) once failed with an error in `core/sync/chan/chan.odin:382`; three reruns of the first one did not reproduce it. It is an Odin checker flake.

Fixed since the first sweep, checked on the rerun: the upstream ols test suite no longer hangs on the tree that `modernize --apply` rewrites (1054 tests, all passed in 1 s under a 900 s alarm). The first sweep's other follow-ups still reproduce, except as noted below.

## Follow-ups

These findings have no passing harness test, because they live in the CLI, the compile gate or the sweep script, depend on timing, or were not reduced. Each item names a repro. The failing tests that the rerun added are listed under "Rerun on 2026-10-04" and in `FOLLOWUPS.md`.

### Formatter

- **`fits` measures a later statement under the enclosing group's break mode.** A group nested in the rest of the document inherits `Break`, so the first `break_with("", true)` inside it (an index expression, for example) ends the measure early. That made a `;`-joined line fit when it did not. The fix keeps the last one-line statement of a `;` chain in one piece (`enforce_fit`), and a `Fit` group now measures with its breaks as spaces. A middle statement is still measured the old way. Other callers of `fits` do too, and treating nested rest groups as flat changes `tests/calls.odin`, so it needs its own review.
- **A `;`-joined statement after the first line of a block is never wrapped, and a split one is not stable.** The group that holds the `; ` break is skipped when the parent mode is flat and no newline was just emitted. Repro: in a `case` body, `x := 1` followed by `a := 1; long_call(…)` wider than the width stays on one line, and a first-statement `a := 1; long_call(…); b := 2` prints the call wrapped on `a := 1; long_call(`, and the second pass splits it at the `;` with the call on one over-width line. The third pass wraps the arguments again, and the output keeps alternating. The base formatter behaves the same, and `rols_semicolon_line_middle_over_width.odin` holds the stable layout.
- **A disabled struct field still starts its region at the line start.** `visit_struct_field_list` emits `info.text` without the comment-offset rule that `visit_disabled` has, so a multi-line field that ends on a trailing `// odinfmt:disable` line prints its end twice.
- **Other `visit_begin_brace` callers key the Indent comment option on the line only.** The comp lit and matrix comp lit cases are fixed. The rerun confirmed the rest: `s := struct{a: int}{} // c`, and `E :: enum { A, B } // e` or the union form, print `} <tab>// c` on the first pass and `} // c` on the second. Test `rols_idempotent_struct_trailing_comment` covers the struct form. 4 core files and a Skald example show it.
- **Two core files stay non-idempotent without a reduction.** `rexcode/isa/arm32/immediates.odin:350` moves trailing comments between lines of a multi-line `|` expression, and `testing/runner.odin:447` moves comments inside a multi-line `+` string concatenation. Both print the comments in different places on the first and the second pass.

### Hangs and crashes not reduced

- **A code action on a 1.8 MB generated file segfaults** when the package also contains odin-godot's `libgd/classdb/bind.odin`. The setup is in the sweep's scratch copy of `libgd/classdb`, with `bind.gen.odin` repeated 12 times. Possibly fixed by the default-parameter fix. The rerun could not recheck it: the clone has no `bind.gen.odin` (its generator does not compile with this Odin), and the scratch copy was not kept. The LSP pass sent a code action at three positions in every file of the clone, including the 3 odin-godot packages, with no crash.

### Performance

- **Opening a 2 MB file takes 1.3 to 2.4 s.** The lints resolve every node of `core/rexcode/isa/ppc/mnemonic_builders.odin` (13,308 declarations), about 2 s of it. Before S15 the open took 15 to 25 s, because `lint_deprecated` and `lint_test_attribute` scanned every top-level declaration for each identifier. After the open, documentSymbol answers in about 1.6 to 2.1 s, a code action in 1.5 s and inlay hints in 1.8 s (before: 17 to 26 s, 25 to 34 s and 51 s). A synthetic 2 MB file (16,000 procedures, 64,000 hints) answers inlay hints in 5.7 s, against 144 s before.
- **A file that names a large enum is slow to open.** `ppc/mnemonics.odin` (55 KB) takes about 3 s because the whole-file resolve rebuilds the enum symbol for each use. `ols query symbols FILE` now opens the file without lints and answers in 0.5 s for that file and 0.3 s for the 2 MB one (before: 3.4 s and 14.2 s), with identical output on 14 files.

### Lint heuristics and noise

- **`unused-parameter` misses a callback type that another file fixes.** The lint skips a procedure that its own file uses as a value (an argument, an assignment, a composite literal element), and a literal passed to a call, stored in a composite literal or assigned. A handler registered from a second file of the package still reports. Checking that needs a scan of the package's open or indexed files for each hit. A sweep of ols and karl2d went from 159 hits to 71; the rest are mostly per-platform implementations that a struct of procedures in another file selects.
- **`naming` still fires on C names that carry no marker.** The lint skips `foreign` blocks, `@(link_name)`, `@(export)` and tagged struct fields. LSP protocol structs in ols (`workspaceFolders`, `rootUri`, 116 field hits) have no tag or attribute, and karl2d's `platform_bindings` load their C functions with `dlopen` instead of `foreign`, so 193 karl2d hits and 175 ols hits remain. A marker for these would need a new attribute or comment convention, so no rule was added.

### Edits

- **The compile gate rolls back on a nondeterministic error set.** `ols query rename tina/src/io_types.odin:287:2 sink_isolate --apply` in a scratch copy of tina rolled back once in five runs: `odin check` of tina's `examples` directory, which already fails, reports 8 to 11 redeclaration errors in varying order and with varying members, and the gate saw a "new" one. The gate warns that the directory already has errors but still compares them. Repro: `for i in 1 2 3 4 5 6; do odin check examples -no-entry-point 2>&1 | grep -c Error; done` in tina.
- **A symbol-path target ignores `#+build ignore`.** `ols query rename .Mouse_Button.Left Primary` in karl2d is refused with `Mouse_Button is declared 2 times`, because `karl2d.doc.odin` (`#+build ignore`) declares it too. The position form (`karl2d.odin:6567:2`) works. The lookup that resolves a `PKG.Name` target should skip files that the build tags exclude, as the lints do.
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

Run the sweep again after the follow-ups above are settled. The 2026-10-04 rerun ended with 48 `FAIL` lines, all classified in "Rerun on 2026-10-04". A clean run needs the failing tests listed there to pass and the two `has_decl` and core-copy problems of `tools/corpus_smoke.sh` to be fixed. `has_decl` should skip inactive `when` branches and raw strings. The core format step should check against the real `core:` collection, or skip packages that import siblings.

1. Run `./build.sh test` and `tools/odinfmt/tests.sh`, which must both report no failures.
2. Run `tools/corpus_smoke.sh`, and `tools/corpus_smoke.sh --lsp` for the stdio pass. The script clones the corpus at the pinned commits into `${ROLS_CORPUS_DIR:-$HOME/.cache/rols-corpus}`. It runs the baseline `odin check`, `check`, `lint`, `symbols`, `modernize --apply` with a plain `odin check` afterwards, and the formatter round trip. It exits 1 and prints one `FAIL` line per problem. A run on the pinned commits should end with no `FAIL` lines once the open items are fixed.
3. Repeat the manual checks that the script does not automate, on two or three projects:
   - Rename a package proc, a struct field used through `using`, an enum member used inside call arguments, and a local, each with `--apply`.
   - Run `move`, `reorder-params`, `rename-package` on a leaf package, and `attr add`.
   - Request `actions` at about 15 positions, apply each offered action, and run `odin check`.
   - Sample about 15 lint hits per project and judge them by reading the code.
4. Move each fixed follow-up out of this file. Add a test for any new bug the rerun finds.

To move the corpus forward, update the commits in `tools/corpus_smoke.sh` and in the table above together. Then run step 2 on the old commits and the new ones, and record any change in the baseline package list.
