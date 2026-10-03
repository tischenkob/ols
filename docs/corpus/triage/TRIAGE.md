# Corpus triage (rols origin/rols 2c89a95a, odin dev-2026-09)

Every case below was reproduced against the build named in the title. The exact source of each case is in
`docs/corpus/triage/<case>/` (files plus `ols.json`); the runners are `cli.py`, `edit.py` (same dir).
Inlay cases are in `triage/inlay_<case>/a.odin`, driven over stdio with `python3 docs/corpus/triage/lsp_one.py DIR FILE inlayHint` (build `./ols` first).
Source reports with corpus locations: `docs/corpus/findings-{A,B,C,D}.md`.

## G1: false lints (expected: no diagnostic of that code)
| Case | Lint | Why it is false |
|---|---|---|
| dead_store_global | dead-store | `g` is a package global read by a called proc |
| dead_store_bare_return | dead-store | named result `ok` is returned by a later bare `return` |
| dead_store_escaped_ptr | dead-store | `&x` escaped into a struct read by a call |
| unsigned_u64_literal | unsigned-negative-compare | `9_999_999_999_999_999_999` fits u64; parsed as wrapped i64 |
| naming_bool_const | naming | `is_enabled :: true` is a constant, not a type |
| naming_underscore_type | naming | `_Private_Type` flagged; leading `_` accepted for procs/consts but not types |
| float_eq_types | float-equality | `when T == Float` compares types |
| alloc_mismatch_dynamic | allocator-mismatch | `delete` of `[dynamic]`/map frees with the stored allocator (slice must still fire) |
| error_not_last_union | error-not-last | `union { int, f32 }` is a value union |
| range_off_by_one_slice | range-off-by-one | `s[:b]` with `b == len(s)` is valid |
| printf_multi_value | printf-arity | `fmt.printfln("%v %v", two())` with a 2-result call |
| printf_star_index | printf-arity | `"%- *[1]s"` explicit index reuses arg 1 |
| ignored_result_error_proc_type | ignored-result | result type is a proc type named `ErrorProc` |
| ignored_result_delete_key | ignored-result | `delete_key` returns the removed key/value, not a status |
| ignored_result_mutex_guard | ignored-result | `@(deferred_out)` guard proc, statement form is the idiom |
| empty_body_cond_call | empty-body | `for step() {}`: the condition has the side effect |
| bool_compare_distinct | bool-compare (lint and fix) | `g() == true` with `g` returning `distinct b32` in a proc returning `bool`; dropping `== true` breaks the return type |
| unknown_field_when | unknown-field (error) | `Cfg` has the field in the same `when FLAG` branch as the use |
| argcount_other_platform | argument-count (error) | call in `b_linux.odin` resolved to the darwin declaration |
| argcount_private_file | argument-count (error) | `#+private file` + `#+build windows` local `create` shadows the package one |

## G2: query results and inlay hints
| Case | Query | Observed | Expected |
|---|---|---|---|
| bsd_file_skipped | def from main.odin into `a_bsd.odin` | nothing (`skip_file` in build.odin rejects `_bsd` on darwin) | `a_bsd.odin` decl (odin builds `*_bsd.odin` on darwin) |
| symbols_build_excluded | documentSymbol of an open `#+build linux` file on darwin | empty | outline of the file |
| symbols_when_false_cond | documentSymbol, `when FLAG == false { a :: proc() {} }` with `FLAG :: false` | `a` missing | `a` listed |
| symbols_config_kind | documentSymbol `FLAG :: #config(FLAG, false)` | Variable | Constant |
| when_string_cond_def | def of `E` under `when E_NAME == "gl" {E :: 1} else {E :: 2}` | the else branch (`E :: 2`) | `E :: 1` |
| def_alias_const_field | def of `qq.x` where `qq :: V`, `V :: S{x = f}` in b.odin, `S` in a.odin | b.odin with a.odin's range | the field `x` in a.odin |
| impl_group_member | impl on `a`, member of `g :: proc{a, b}` | `a` itself | `g` |
| hover_using_offset | hover `d.magic`, `magic` promoted via `using base: Base` at offset 0 | `offset: 16` | `offset: 0` |
| callers_build_ignore | callers of `draw` | includes the bodyless decl in a `#+build ignore` doc.odin | only `main` |
| hover_poly_in_poly | hover `x := conv(p, A)` inside `outer :: proc($A: typeid, ...)` | `$x: typeid` | `x: A` |
| hover_overload_poly_tag | hover `r1 := ab(T1, nil)`, members take `$tag: Tag` | nothing | `r1: int` |
| hover_overload_first_member | hover `lib.send(&v)`, `send :: proc{send_raw(x: int), send_typed(x: ^$T)}` | `send_raw`'s signature | `send_typed` |
| refs_enum_after_call_arg | refs of `E.Y` | misses `f(g("x"), .Y)` | both calls |
| refs_enum_named_after_variadic | refs of `Align.Center` | misses `row(1, 2, align = .Center)` (`row` has `..int` first) | the use |
| refs_enum_in_comp_lit_arg | refs of `Kind.B` | misses `take(Item{kind = .B})` | the use |
| refs_pkg_global_field | refs of `a.cfg` | misses `a.cfg.x = 1` in the importer | the use (rename then exits 4) |
| refs_using_param_field | refs of field `W.id` | misses bare `id` under `proc(using w: ^W)` | the use (rename then exits 4) |
| inlay_unresolved_call | inlayHint `x := undefined_proc(1)` | hang, then SIGSEGV | no hint, prompt answer |
| inlay_paren_cast | inlayHint `x := (^int)(p)` | hang | `: ^int` |
| inlay_make_param | inlayHint `x := make([]int, m)`, `m` a parameter | hang | `: []int` |
| inlay_make_literal | inlayHint `a := make([]u8, 4)` | label of NUL bytes | `: []u8` |
| inlay_call_result | inlayHint `c := one()` | label of NUL bytes | `: int` |
Also verify and test if it reproduces: hover on imported struct-typed global `a.cfg` shows `<importer-dir>.cfg: struct {...}` instead of `a.cfg: a.Config` (findings-A F16).

## G3: wrong edits
| Case | Edit | Observed | Expected |
|---|---|---|---|
| fill_fixed_array | modernize use-stdlib fill (default rule) on `buf: [8]u8` loop | `slice.fill(buf, 'a')`, does not compile | `slice.fill(buf[:], 'a')`; skip enumerated arrays (cannot be sliced) |
| fill_index_value | fill-indexed on `s[i] = i` | `slice.fill(s, i)` | no fix when the value mentions the index |
| sum_over_range | use-stdlib/sum on `for i in 1 ..= 10 { t += i }` | `math.sum(1 ..= 10)`, does not parse | no lint/fix on an interval range |
| redundant_parens_comment | redundant-parens on `return (\n// first\n a && b)` | comment deleted | comment kept, or no fix |
| bool_return_comment | bool-return across a comment before final `return true` | comment deleted | comment kept, or no fix |
| nested_if_one_line_indent | nested-if merge with inner `if b { return 1 }` | body indented tab+tab+space | tabs only |
| unwrap_block_for | action "Unwrap block" on a `for` | loop header deleted, `i` undeclared | not offered on loops |
| unwrap_block_unreachable | "Unwrap block" on `if running { return 1 }` followed by `return 2` | unreachable code | not offered when body ends in a terminator and statements follow |
| invert_if_one_line | "Invert if" on `if running { l = "Pause" }` | body line indented by one space | tab indentation |
| add_ok_result_callers | "Add ok result" on `get` with a caller `v := get(1)` | caller left broken | update callers (`v, _ := get(1)`) or not offered |
| add_ok_result_or_return | "Add ok result" on proc with unnamed results using `or_return` | does not compile | not offered (or name the results) |
| generate_test_enum | "Generate test for f", `f` returns an enum | `expect_value(t, result, {})` does not compile | a typed zero value, e.g. `E{}` / `E(0)` |
| explicit_type_slice_field | "Add explicit type" on `r := s.arr[:2]` | `r: arr = ...` | `r: []int = ...` |
| move_to_other_build | actions on `helper` in a.odin | offers "Move to c.odin" where c.odin is `#+build linux` | only files with the same build constraints / private tag |
| inline_file_private | "Inline procedure call" in b.odin of `draw`, whose body calls a `@(private="file")` proc in a.odin | offered (result does not compile) | not offered |
| dp2 (actions_default_param_hang) | actions at `f(1)` with `f :: proc(got: int, d := 0)` (triage/dp2) | never returns (CLI and LSP) | prompt answer |
| rename_pkg_bare_name | rename-package `lib` -> `lib2` with `_ :: lib` in importer | bare `lib` not rewritten | `_ :: lib2` |
| fmt (a.odin) | odinfmt `input = Input{pos = {9, 9}} // far away` | pass 1 expands it with `} \t// far away`; pass 2 changes it again | fixed point after one pass |
| fmt (b.odin) | odinfmt long `;`-separated statement line | pass 2 splits again | fixed point after one pass |

## Follow-ups (no harness test; repro given)
See the doc for the full list. CLI-only or unreduced: relative `--root` drops cross-file results; `move --to` resolves relative to the decl dir and refuses symlinked absolute paths; `checker_args: "-no-entry-point"` drops all compiler errors; default `-vet-style` syntax error hides type errors and blinds the compile gate; gate rollback on nondeterministic pre-existing errors (error limit, mixed package names); shebang logs an ERROR; `symbols` text lacks `file:` and order is unstable; `tests`/`check` with no argument; `test DIR NAME` exit 0 with no match; spirv range-hint hang (unreduced); large-file codeAction SIGSEGV (unreduced); quadratic formatter on large composite literals; slow documentSymbol/codeAction on 2 MB files; `symbols FILE` indexes whole package; lock-by-value on core:sync enum (unreduced); error-not-last on enum with `None`; heuristics/noise (unused-parameter on callbacks, float-equality vs literal 0, naming on bindings/protocol structs, find omits private decls, duplicate action titles, Invert if leaves empty then-branch, redundant-parens brace on own line).
