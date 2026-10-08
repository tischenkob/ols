# Open follow-up inventory (rols at b69893ef, 2026-10-07)

**Completed on 2026-10-08.** The remaining open items live in `FOLLOWUPS.md`, and the Known limits in the "Known limitations" section of `FORK.md`.

Scope: every entry in `FOLLOWUPS.md` and in the "Follow-ups" section of `docs/corpus-validation.md` whose bold lead does not start with "Known limit", plus the notes in `tmp/new-followups.md`. The section "Rename, imports and lints from the mirage gaps (2026-10-07)" is excluded. The "CLI compile gate" section is included after the r4a merge (b69893ef). Line numbers refer to `FOLLOWUPS.md` at b69893ef.

Totals: 28 open entries (20 FIX, 8 DOCS-ONLY, 0 KNOWN-LIMIT), plus one note that is already fixed. The FIX entries form 6 stages.

## A. FOLLOWUPS.md

### A1. "The doc's follow-ups have no passing harness test" (Corpus validation, L8)
- Summary: a pointer to `docs/corpus/triage/` and `cli.py`. It describes no defect.
- Files: `FOLLOWUPS.md` only.
- Fix design: none needed. Turn the bullet into a plain sentence under the section heading, or drop it, because the doc's own "Follow-ups" intro already says the same thing.
- Failing test: none.
- Class: **DOCS-ONLY**.

### A2. Signal 11 crashes of `odin check` with unknown cause (Compile gate, L12)
- Summary: 6 of 40 gated Skald runs once lost a check to SIGSEGV after about 10 ms. The cause is unproven: either the child crashes in the fork before `execve`, or `odin` crashes at start.
- Files: `src/server/check.odin` (retry exists), possibly a `posix_spawn` launcher in a new `rols_spawn.odin`.
- Fix design: the mitigation (read the signal with `waitid`, log it, rerun once) is in place. A real fix would replace `core:os` `process_start` with `posix_spawn` from `core:sys/posix` so that no Odin code runs between fork and exec. That is speculative until a Skald loop counts the logged crashes.
- Failing test: none. The crash is not reproducible in the harness.
- Class: **DOCS-ONLY**. It is an unreduced crash under the rule. Relabel it "Known limit:" and keep the next step. A `posix_spawn` launcher is a separate, optional experiment.

### A3. Multi-value expansion counts the call of a local typed constant of a procedure type as a conversion (Lints, L27)
- Summary: `local : Cb : f` inside a procedure, then `take(local())`, reports `argument-count` because the local symbol has neither `.Mutable` nor `.Variable`.
- Files: `src/server/locals.odin` (`store_local` callers at about lines 385-400 and 445-460), or `src/server/rols_resolve.odin` (`names_proc_type`, line 139).
- Fix design: in the value-declaration local paths of `locals.odin`, set `.Variable` for a constant declaration that has an explicit type (`value_decl.type != nil && !is_mutable`). The collector already does this for globals, and `names_proc_type` then sees a value. A narrower option keeps `locals.odin` untouched: `names_proc_type` also takes `.Local` symbols whose declaration has a value expression, but the flag fix matches the global path. Check that hover and semantic tokens of typed local constants keep their kind. `analysis.odin:908` reads `.Variable` for `is_constant`, and the `!.Mutable` part keeps the result correct.
- Failing test: `tests/rols_lint_calls_test.odin` new `argument_count_expands_call_of_local_procedure_constant`. `main :: proc() { local : Cb : f; take(local()); one(local()) }` expects only the `one` line.
- Class: **FIX**.

### A4. The empty-body lint flags a `for` loop whose post statement does the work (Lints, L33)
- Summary: `for i := 0; i < len(xs); n, i = n+1, i+1 {}` and `core/os/env_linux.odin:341` report `empty-body`.
- Files: `src/server/rols_lint_no_op.odin` (the `^ast.For_Stmt` case at lines 25-35).
- Fix design: the `scans` exemption covers a post statement only when the init declares nothing. Extend it so that a post statement that assigns to a name the init does not declare also counts as work, because that variable outlives the loop. Walk the post `Assign_Stmt` left-hand sides and compare their names with the names of `n.init` when it is a `Value_Decl`.
- Failing test: `tests/rols_lint_test.odin` (or the no-op lint test file). `n := 0; for i := 0; i < len(xs); n, i = n+1, i+1 {}` must report nothing, and `for i := 0; i < 3; i += 1 {}` must still report.
- Class: **FIX**.

### A5. The harness reference search misses collection imports in other files (Safe-rename check, L38)
- Summary: `find_symbol_references` parses other files' imports with the global `common.config`, and the harness keeps a test's `collections` only in the test config.
- Files: `src/testing/testing.odin` (`setup` at line 43, `teardown` at line 170), then `tests/rols_rename_check_test.odin` (switch the workaround test back to `shared:pkg`).
- Fix design: in `setup`, copy `src.collections` into `common.config.collections`, and remove those keys in `teardown`. `common.config` is a process global, so parallel tests that set collections must take a mutex, such as the existing `seed_mutex`. Otherwise each test could use a unique collection name.
- Failing test: `rename_safe_refuses_field_through_alias_with_variants_in_other_package`, rewritten to import `shared:pkg`, finds no references today.
- Class: **FIX**.

### A6. The field-rename check resolves an inactive `using` embedder type to the active one (Safe-rename check, L39)
- Summary: `check_embedders` adds `resolve_type_expression` of the declaring name to `scan.types`, so an inactive struct yields the active variant. That may refuse a safe rename. The repro is unverified.
- Files: `src/server/rols_rename_check.odin` (`check_embedders` at line 588).
- Fix design: build the symbol from the declaration node that the scan already holds (its file and range) instead of resolving the name. Alternatively, compare the resolved symbol's range with the declaration's range, and use `branch_fallback` when they differ. Write the repro first.
- Failing test: `tests/rols_rename_check_test.odin`. `when ODIN_OS == .Windows { S :: struct { using b: B } } else { S :: struct { c: int } }`, then rename `B.x` on a darwin host. Expect the rename to be allowed, or the inactive embedder to be considered, according to what the repro shows.
- Class: **FIX** (reproduce first).

### A7. An import added at the bottom of a one-line file lands past its end (Edits S10, L52)
- Summary: with `enable_add_import_to_bottom`, `import_edit` uses the 1-based end line from `find_most_bottom_line_number` (upstream `completion.odin`) as a 0-based line.
- Files: `src/server/rols_edit.odin` (`import_edit` at line 660).
- Fix design: keep upstream `completion.odin` unchanged. In `import_edit`, when `line` is at or past the document's line count (`strings.count(src, "\n")`), insert at offset `len(src)` with a leading `\n` through `range_of`, as the package-clause path already does.
- Failing test: `tests/rols_action_inline_proc_test.odin`. Run the repro from the entry. The harness rejects the range today.
- Class: **FIX**.

### A8. An import lands inside a block comment that starts on the package line (Edits S10, L53)
- Summary: `package test /* note\nmore */` makes `import_edit` insert on the line after the clause, which is inside the comment.
- Files: `src/server/rols_edit.odin` (`import_edit`).
- Fix design: after `pkg_decl.end`, look for a comment group in `ctx.ast_context.file.comments` that starts on the package line. Use the line after its end as the insert line and as `rest`. The no-newline-after branch applies when the comment runs to the end of the file.
- Failing test: same file as A7, with the repro from the entry. The import ends up inside the comment today.
- Class: **FIX**.

### A9. `find` and `tests` read a selector only from the evaluated file (CLI queries, L58)
- Summary: a constant of a sibling file that reads `pkg.NAME`, or an imported package's constant that reads its own import's selector, stays unknown.
- Files: `src/server/rols_when_inactive.odin` (`add_selector_consts` at line 103, `build_when_package`).
- Fix design: when `build_when_package` folds a sibling's constants, call `add_selector_consts` with that sibling's own `ast.File` imports (each file has its own aliases). For an imported package, run `add_selector_consts` once more, one level deep, inside the `!cached` branch over the imported package's files.
- Failing test: `tests/rols_cli_*` or `tests/rols_when_inactive_test.odin`. `consts.odin` has `import "lib"` and `ON :: lib.FLAG`, `a.odin` has `when ON { @(test) t :: … }`, and `ols query tests` must list `t` (or not) according to `lib.FLAG`. Today the value is unknown.
- Class: **FIX**.

### A10. An `else when` chain adds a target that only skips branches (CLI compile gate)
- Summary: on darwin, `when ODIN_OS == .Darwin {…} else when ODIN_OS == .Linux {…}` makes the gate also check windows_amd64, which builds neither branch.
- Files: `src/server/rols_check_targets.odin` (`file_when_named_targets` at line 741, `condition_differs` at line 463).
- Fix design: for a chain, evaluate which branch each named target takes and which branch the base target takes, with `condition_on`. Keep a target only when its branch differs from the base's branch and is not an empty final `else` (or an absent else).
- Failing test: `tests/rols_apply_test.odin`. Run the repro with a gate-targets assertion. Today `windows_amd64` is listed.
- Class: **FIX**.

### A11. A test that panics can hang in some agent sandboxes (Test harness, L77)
- Summary: the fault handler of the `core:testing` runner is not reached in some sandboxes. `ROLS_TEST_TIMEOUT` bounds the hang.
- Files: none.
- Fix design: none inside rols. The cause is the environment's signal handling.
- Class: **DOCS-ONLY**. Relabel it "Known limit:" with the sandbox fault handler as the reason.

### A12. `for x in m[k]` over a map index loops forever (Odin dev-2026-09) (Test harness, L78)
- Summary: this is an Odin compiler bug. The rols code has no remaining site, and `lint_loops` reports the pattern.
- Class: **DOCS-ONLY**. Relabel it "Known limit:" as an Odin compiler bug, and keep the draft issue.

### A13. A poly-type argument drops every generic member of a group call (Overload resolution, L98)
- Summary: inside `h :: proc(v: $T)`, `g(v, .A)` resolves no member. Hover shows the whole group, and completion in `g(v, .)` is empty.
- Files: `src/server/generics.odin` (`resolve_generic_function_symbol` at line 560), `src/server/symbol.odin` (`symbol_to_expr` at line 1024), and `src/server/analysis.odin` (`resolve_proc_lit` at line 3159). All three are upstream files and need `// rols:` regions.
- Fix design: first confirm the cause. If `symbol_to_expr` returns nil for `SymbolPolyTypeValue`, make it return the poly type's expression. Otherwise, in `resolve_generic_function_symbol`, bind a poly parameter whose argument is itself a poly type to that unsubstituted type instead of failing. Membership then falls to the non-poly parameters (`.A` against `E1` versus `string`).
- Failing test: `tests/rols_overload_test.odin` (or the hover tests). Hover on `g` in `h :: proc(v: $T) { g(v, .A) }` expects `f1`.
- Class: **FIX**.

### A14. The lints of a file the host does not build read a resolve that evaluates its `when` for the host (Build tags, L103)
- Summary: in `foo_windows.odin`, `when ODIN_OS == .Windows { f :: k } else { f :: g }; f()` reports `result of f is ignored` on darwin.
- Files, narrow option: `src/server/rols_lint.odin` (`lint_symbols` at line 105). Files, full option: `src/server/file_resolve.odin` and `src/server/analysis.odin` (`get_locals`).
- Fix design: recommend the full option. Set `when_eval_target` to `file_target(document.fullpath)` for every whole-file resolve of a document that the host does not build. Hover and semantic tokens then also follow the target that builds the file, which is more correct for that file. If review rejects the change to hover, use the lint-only option already named in the entry: in target mode, `lint_symbols` drops nodes that resolve to a local declared directly in a `when` branch body.
- Failing test: `tests/rols_when_lints_test.odin`. Run the repro from the entry. Expect no `ignored-result`. Today it reports a false positive.
- Class: **FIX**.

### A15. A file that several targets build is linted for the first one only (Build tags, L104)
- Summary: `#+build linux, freebsd` is linted only for linux_amd64, so a freebsd-only `@(require_results)` variant is missed.
- Files: `src/server/rols_excluded.odin` (`file_target` at line 296) and `src/server/rols_lint.odin` (`walk_lints` at line 364, `lint_symbols`).
- Fix design: return every candidate target that builds the file (`file_targets`). Run the resolving lints per target only when the package has a variant that differs between those targets (`declaration_variants` non-empty for a called name). Otherwise lint once. Merge the diagnostics and deduplicate them by range and code. This bounds the extra lookups to packages with real variants.
- Failing test: `tests/rols_when_lints_test.odin`. Run the repro from the entry and expect `ignored-result` on `g()`.
- Class: **FIX**. The cost note in the entry is a performance concern, not a documented trade-off.

### A16. A fallback branch that reads a constant of another file keeps the first fallback (Build tags, L107)
- Summary: `IS_B` declared in `consts.odin` is read as false, so `T` under `when IS_B` resolves to the first indexed fallback. b69893ef shares the constant reader but still reads `file_consts` of one file.
- Files: `src/server/rols_when.odin` (`branch_fallback` at line 47), `src/server/rols_check_targets.odin` (`file_consts` at line 646, `condition_on`), and `src/server/collector.odin` (`collect_globals` per target collection).
- Fix design: add a `package_consts(dir)` that merges `file_consts` of every file of the package that the target builds, and cache it per directory and request. `branch_fallback` passes it to `condition_on`. The collector's per-target `when` evaluation gets the same map, so declarations under `when IS_B` are not flagged as fallbacks on target B.
- Failing test: `tests/rols_when_fallback_test.odin`. Run the repro from the entry. Hover on `b` expects `T.b: int`.
- Class: **FIX**.

### A17. Two fallbacks of one name in the open file resolve to the first branch (Build tags, L108)
- Summary: the document's own globals hold the first inactive branch, so `branch_fallback` is never reached.
- Files: `src/server/rols_when.odin` and the global lookup in `src/server/analysis.odin` (the local and global path that returns the document's own global).
- Fix design: when the found global of the open document lies in an inactive branch and the use site is in a branch (`when_branch_of`), route the lookup through `branch_fallback` with every same-file declaration of that name as a candidate. Pick the one whose branch is possible on the use site's target.
- Failing test: `tests/rols_when_fallback_test.odin`. Run the repro from the entry. Hover on `b` expects `T.b: int`.
- Class: **FIX**.

### A18. A field rename from a variant whose sibling aliases another type is refused (Build tags, L113)
- Summary: `S :: S_Other` as a sibling variant names no covered type, so renaming `a` is refused when the struct branch is active.
- Files: `src/server/rols_variants.odin` (`field_variants` at line 133). It may also touch `check_rename` in `src/server/rols_rename_check.odin`.
- Fix design: when a variant is an alias, resolve its target type (`S_Other`), add it to the covered set if it carries the member, and rename the member there too, as is done for the active-alias case.
- Failing test: `tests/rols_rename_check_test.odin` (or `rols_variants_test.odin`). Run the repro from the entry. Expect the rename to succeed and to edit `S_Other.a`.
- Class: **FIX**.

## B. docs/corpus-validation.md "Follow-ups"

### B1. A code action on a 1.8 MB generated file segfaulted, not reproduced
- Class: **DOCS-ONLY**. It is an unreduced crash. Relabel it "Known limit:" or move it to the rerun history.

### B2. Opening a 2 MB file takes 1.3 to 1.5 s
- Summary: this duplicates the FOLLOWUPS "Large-file performance" entry, which is already a Known limit.
- Class: **DOCS-ONLY**. Prefix it with "Known limit:", or replace it with a pointer to FOLLOWUPS.

### B3. `unused-parameter` misses a callback type that another package fixes
- Summary: `handler` in package `a`, registered as `register(a.handler)` in package `b`, still reports `x`.
- Files: `src/server/rols_lint.odin` (`used_as_value_elsewhere` at line 939, `sibling_values`) and, to find importers, `graph_importers` / `import_graph` in `src/server/rols_check_targets.odin` or the CLI gate helper.
- Fix design: after the same-package scan finds no use, read the workspace packages that import the procedure's package (one level). For each file that holds `alias.name` as a word, parse it and look for a value use of the selector. Reuse the word index and the 1.5 MB parse cap, and cache the importer list per lint run. Users outside the workspace stay unseen. That part is a real limit, so split it into a "Known limit:" sentence.
- Failing test: `tests/rols_lint_test.odin` with `packages`. Run the repro from the entry. Expect no `unused-parameter`.
- Class: **FIX**. It must sit in the same stage as A14 and A15 because of `rols_lint.odin`.

### B4. "Invert if" on an `if` without `else` leaves an empty then-branch
- Summary: this is upstream OLS's tested behavior (`action_invert_if_simple_edit`).
- Class: **DOCS-ONLY**. Relabel it "Known limit:" for upstream compatibility.

## C. tmp/new-followups.md (verified against b69893ef)

### C1. Flaky `index_updates_preserve_and_invalidate_resolution_caches`
- Summary: the test failed once in 4 runs with "Malformed index updates must retain valid resolution caches".
- Verification: the note's cause is wrong. `document_storage` is `@(thread_local)` (`src/server/documents.odin:63`), so the swap in `src/testing/index_updates.odin:46` is not visible to other test threads. `indexer` is thread-local too (`indexer.odin:15`). The malformed source returns before `invalidate_document_symbol_caches` (`build.odin:322-327`). No cross-thread writer of `cache_document.symbols` was found. The root cause is unknown.
- Files: `src/testing/index_updates.odin` and possibly `src/server/build.odin`.
- Fix design: loop the prebuilt test binary (see the memory note "Looping the test suite") with `single_test` until it reproduces. Log `syntax_error_count` and every `invalidate_document_symbol_cache` call. A suspect worth checking is a global that `parse_file` or the default error handler reads, since `is_ols_builtin_file` leaves `p.err` nil for this path.
- Failing test: the existing test, under a loop.
- Class: **FIX** (investigate first).

### C2. A proc-typed constant in another file (`handler : Cb : f`) counts as a conversion
- Verification: already fixed. `argument_count_expands_call_of_procedure_constant_in_another_file` in `tests/rols_lint_calls_test.odin:663` covers it, and the collector copies `.Variable` (`collector.odin:1136`). Only the local case (A3) remains. Do not add an entry.

### C3. Windows path normalization in `check_carrier_variants` never ran on Windows
- Summary: a drive-letter case mismatch between `scan.texts` paths and `symbol.uri` may drop siblings in `declaration_variants` or `package_documents`. There is no repro.
- Files: `src/server/rols_rename_check.odin` (`check_carrier_variants` at line 508) and `src/server/rols_variants.odin` (`package_documents`).
- Fix design: normalize both sides with `common.get_case_sensitive_path` and forward slashes before comparing directories, as `document_setup` does. Without a Windows run this cannot be proven, so the alternative is a unit test of the comparison helper with mixed-case inputs. That test runs on any OS if the helper compares case-insensitively when it sees a drive letter.
- Class: **FIX** (low priority). Unverified, and it needs a Windows run to confirm.

### C4. Tests write the global diagnostics maps and flip `common.config.enable_diagnostics` while other tests run (r3a, non-blocking)
- Summary: `tests/rols_lint_refresh_test.odin` and `tests/imports_test.odin` replace `server.diagnostics` and set the global `common.config.enable_diagnostics = true` under `test.seed_mutex` only. `add_diagnostics` (`src/server/diagnostics.odin:52`) gates on that global flag. While the flag is true, any parallel test that publishes diagnostics allocates a cloned key and a dynamic array into the shared maps with its own tracking allocator. That memory is never freed by that test.
- Files: `tests/rols_lint_refresh_test.odin`, `tests/imports_test.odin`, and possibly `src/server/diagnostics.odin`.
- Fix design: make `add_diagnostics` take the caller's `config` (or check `config.enable_diagnostics` at the `run_lints` and publish call sites, which already have it) instead of reading `common.config`. Then the two tests can set `enable_diagnostics` in their own config and not touch the global. Write the maps under the diagnostic mutex through a small exported reset helper.
- Failing test: `move_decl_actions_list_targets` (C5) under a loop of the full suite.
- Class: **FIX**.

### C5. A flaky 3-allocation leak in `move_decl_actions_list_targets`
- Summary: one full run reported 3 leaked allocations. The test passed alone 3 times and in later full runs.
- Verification: the likely cause is C4, but this is a hypothesis that I did not reproduce. A parallel `enable_diagnostics = true` window makes `add_diagnostics` clone the URI, create the array and append (about 3 allocations) with this test's allocator into maps that another test owns.
- Files: same as C4.
- Fix design: fix C4, then loop the full suite to confirm.
- Class: **FIX** (in the same stage as C4).

### C6. No harness test for `notification_did_save` (r3a, non-blocking)
- Summary: the relint-on-save path (`requests.odin:1602`) has no test.
- Files: `tests/rols_lint_refresh_test.odin`.
- Fix design: add a test that opens `a.odin` and `b.odin`, saves `b.odin` with `register(f)` through `notification_did_save`, and expects `x` cleared on `a.odin`.
- Class: **FIX** (test only).

### C7. No test for the word-index branch of `used_as_value_elsewhere` (r3a, non-blocking)
- Summary: lookups after `WORD_SCANS` (3) names use `word_files`, and no test runs more than 3 names.
- Files: `tests/rols_lint_test.odin`.
- Fix design: add a test with 5 top-level procedures with unused parameters. The fifth procedure is used as a value only in a sibling file and must not report.
- Class: **FIX** (test only).

## D. Stages for the FIX entries (disjoint source files)

1. **s1-edits-imports**: A7 and A8. Files: `src/server/rols_edit.odin`, plus tests in `tests/rols_action_inline_proc_test.odin`. No dependencies.
2. **s2-resolver**: A3 and A13. Files: `src/server/locals.odin`, `src/server/generics.odin`, `src/server/symbol.odin`, `src/server/analysis.odin` (`resolve_proc_lit` only), plus tests in `rols_lint_calls_test.odin` and the overload/hover tests. Run it before s4, because A17 also touches `analysis.odin`.
3. **s3-lints**: A4, A14, A15 and B3. Files: `src/server/rols_lint_no_op.odin`, `src/server/rols_lint.odin`, `src/server/rols_excluded.odin`, `src/server/file_resolve.odin` (only with the full A14 option), plus tests in `rols_lint_test.odin` and `rols_when_lints_test.odin`. If the full A14 option touches `analysis.odin` `get_locals`, run this stage after s2. B3 reads importers, so it reuses `import_graph` from `rols_check_targets.odin` read-only. Do not edit that file here.
4. **s4-when-targets**: A9, A10, A16 and A17. Files: `src/server/rols_check_targets.odin`, `src/server/rols_when.odin`, `src/server/rols_when_inactive.odin`, `src/server/collector.odin`, `src/server/analysis.odin` (the global-lookup region only), plus tests in `rols_apply_test.odin`, `rols_when_fallback_test.odin` and the when-inactive or CLI tests. Run it after s2 (shared `analysis.odin`) and after s3 if A14 takes the full option.
5. **s5-rename-variants**: A6, A18 and C3. Files: `src/server/rols_rename_check.odin`, `src/server/rols_variants.odin`, plus tests in `rols_rename_check_test.odin`. No dependencies. It is disjoint from s4 because `branch_fallback` is not edited here.
6. **s6-test-infra**: A5, C1, C4, C5, C6 and C7. Files: `src/testing/testing.odin`, `src/testing/index_updates.odin`, `src/server/diagnostics.odin` (the `add_diagnostics` config parameter and its callers in `requests.odin`/`rols_lint.odin`/`documents.odin`), `tests/rols_lint_refresh_test.odin`, `tests/imports_test.odin` and `tests/rols_lint_test.odin` (the C7 test). The `add_diagnostics` signature change touches `rols_lint.odin` call sites, so run s6 after s3 or limit C4 to the tests and `diagnostics.odin`, with a config check moved into the existing callers in a later merge. A5 (re-enable `shared:pkg` in the rename test) touches `tests/rols_rename_check_test.odin`, so merge it after s5.

Suggested order: s1, s5 and s6-part-1 (C1 investigation, C6, C7) in parallel; then s2; then s3; then s4; then the rest of s6 (A5, C4, C5).

DOCS-ONLY relabels (one docs commit, no code): A1, A2, A11, A12, B1, B2, B4. Turn each into a "Known limit:" entry with its reason (Odin compiler bug, sandbox fault handler, unreduced crash, upstream compatibility, or a duplicate).

## E. Existing "Known limit:" entries whose reason looks doubtful

The rule: a Known limit needs a fix outside rols or a documented trade-off. These entries fail that rule because the fix lies inside rols.

1. **"An `unused-parameter` verdict on another file is refreshed only by a change to an open file" (L25).** All three gaps are fixable in rols. `notification_did_change_watched_files` (`requests.odin:2020`) already reads each changed file from disk and reindexes it, but never calls the relint. It can call a variant of `relint_package_siblings` (`rols_lint_refresh.odin:68`) with the disk path and text, since `verdict_may_change` takes a path and text. `notification_did_open` stores the new document after `document_refresh` (`documents.odin:198-215`), so call the sibling relint after the insert. `notification_did_close` can relint siblings against the disk text when the closed buffer was dirty. **Recommendation: FIX** (stage s3, or a small separate stage with `requests.odin`, `documents.odin` and `rols_lint_refresh.odin`). Keep only the out-of-editor case without file watching as a limit, because it needs client watch support.
2. **"The fill rewrite accepts a field read through a pointer to a field of an element" (L16).** This produces a wrong rewrite (`q.x` read once). Refusing any pointer whose initializer is `&items[...]...` is a local change to `reads_array` in `rols_lint_use_stdlib.odin`. **Recommendation: FIX.**
3. **"Inline variable" (L47), the `any` / `#by_ptr` sub-clause.** "An `any` or `#by_ptr` argument also exposes a local's address, and this check does not see it" is a correctness hole. The callee's parameter types resolve in rols. **Recommendation: FIX that sub-clause.** The rest of the entry is a deliberate safe-refusal design.
4. **"`dead-store` is silent for every store to a `using` field" (L30).** The value's kind (a local `using s: S` declaration against a `^S` parameter) is available from `visible_declaration`. **Recommendation: FIX** for the local-value case. Keep the pointer case as a limit.
5. **"Active code that names an inactive-only declaration resolves it" (L105) and "a constant of another package that a `when` condition reads treats an undeclared name as false" (L109).** Both say that the fix "needs a tri-state `when` evaluator", which lives in rols (`when.odin`, `rols_when.odin`). The entry cites no outside dependency. **Recommendation:** keep the trade-off text that FORK.md documents for L105, but reword both entries as a planned tri-state evaluator (a large FIX), not as a limit.
6. **"The rename collision scan evaluates `when` only in sibling files" (L112) and "variants are identified without evaluating `when` conditions" (L111).** Both name `branch_possible_on`, which exists in rols, as the fix. **Recommendation: FIX L112** (same-file declarations through `when_branch_of` plus `branch_possible_on`). L111 is harmless because `odin check` reports the duplicate, so it can stay as a documented choice.
7. **"A field rename reads every workspace file once" (L37) and "implementation requests on a procedure still read every workspace file" (L40).** Both say "a cached word index of the workspace would remove the reads". That index is inside rols, and the unused-parameter lint already has a per-package one. **Recommendation:** keep them as performance notes, but label them as deferred performance work, not as limits.
8. **"The `range-off-by-one` guard does not see a length held in a parameter or a struct field" (L21).** Accepting `if b < count` with `count` a parameter or field compared against the same index is a heuristic widening inside rols. The `s = t` base-of-collection miss is a prefix compare in `names_len_local`. **Recommendation: FIX** the base-of-collection miss (a prefix match on the selector chain). Keep the parameter and pointer parts as heuristics.

The other Known limits cite upstream compatibility (`fits`, organize-imports anchor, profile defines, the poly package from upstream `generics.odin`), Odin limitations (one package per `odin check`, no per-file exclude, freebsd_i386 core bug, odin error columns), measured or deliberate trade-offs (temp arena swap, action caches, organize-on-save `when` branches, safe refusals), or no known repro. They look sound.
