# Findings A (ols 146d5e3, odin-http fac113f)

Saved by the main session from agent A's text report. Reduced repros: /tmp/rols-corpus/scratch-A/r1..r18.
Setup: ols.json for ols = collections src=src plus all enable_checker_vet_* false; odin-http ols.json = {}.
Note: something sent SIGTERM to processes named `ols` during LSP runs; agent A used a renamed copy scratch-A/olsA_bin.

## Crash / hang
- F1 inlayHint hang (sometimes SIGSEGV) via enable_inlay_hints_variable_types. r15: `p := (f32)(user)` or `p := (^int)(user)`. Also `du := g(1)` with g undeclared (SIGSEGV 3/5 runs). Also param shadowed by local proc literal: `f :: proc(handle: HP) -> HP { handle := proc(x: int) {}; return handle }`. 13/39 odin-http, ~33/155 ols files time out.
- F2 codeAction hang on a call to a proc with a default-valued param. r17: `mk :: proc(a := 2) -> int { return a }` / `f :: proc() { _ = mk(3) }`; `ols query actions a.odin:8:7` times out at 90 s. ols lens.odin:24-29.
- F3 semanticTokens/full hang once on ols writer.odin (30 s), then 0.03 s. Unconfirmed.

## Wrong edits
- F4 spurious rollback (exit 4) from nondeterministic pre-existing errors: mixed-package dir (tools/odinfmt: expected 'odinfmt' vs 'odinfmt_tests' flips with parse order, 18/6 of 24 runs) and error limit (old_nbio 147 errors vs limit 25, printed subset varies). Repro: `cd ols; ols query modernize --apply`.
- F5 redundant-parens deletes comments inside the parens (modernize and action). r8: `return (\n\t// first\n\tk != "a" &&\n\tk != "b")`; `if (k > 1 /* why */) {`.
- F6 bool-compare drops `== true` on a distinct bool type. r16: `B :: distinct b32`, `g :: proc() -> B`, `f :: proc() -> bool { return g() == true }` in b_windows.odin -> `return g()`, applied (gate cannot see windows file), fails `odin check -target:windows_amd64`. Lint itself is a false lint.
- F7 rename/refs miss `pkg.global.field`. r5: a/a.odin `Config :: struct { x: int }`, `cfg: Config`; main `a.cfg.x = 1`, `p := &a.cfg`. refs omits `a.cfg.x`; rename --apply exit 4.
- F8 rename/refs miss implicit enum member when an earlier arg of the same call is a call expr. r9s: `f(g("x"), .Y)` missed, `f("x", .Y)` found.
- F9 relative `--root` disables cross-file results (refs, find, rename). r10.
- F10 rename-package misses a bare package name used as a value: `import "lib"`, `_ :: lib`. r11.
- F11 actions producing non-compiling code: "Add explicit type" on `s.arr[:2]` writes `r: arr = ...` (r14); "Generate test" writes `expect_value(t, result, {})` for an enum result (r12); "Add ok result" with `or_return` in body on unnamed results (r12); "Unwrap block" on `for` (r14); "Move to c.odin" offered for a `#+build ignore` target (r13).
- F12 re-indent of one-line block uses a single space: `if x^ == y { return }` -> Invert if / Convert to switch produce ` return`. r12.

## Wrong results
- F13 platform files: false unknown-field / argument-count errors and def to the wrong platform file. r1 (f_darwin/f_linux/g_linux).
- F14 symbols/hover empty in a `#+build linux` file on darwin. r2.
- F15 `tests` lists `#+build ignore` tests but drops `_windows.odin`; `test` then says "No test found" with exit 0. r4.
- F16 hover on imported struct-typed global: `r5b.cfg: struct { x: int, }` instead of `a.cfg: a.Config`.
- F17 hover package label uses directory name, not `package` clause.
- F18 shebang first line logs `[ERROR] unsupported comment delimiter`. r3.

## Improvements
- F19 default vet style/semicolon/tabs make upstream OLS "Syntax Error"; gate warns it cannot see packages.
- F20 `test DIR NAME` exits 0 when no test matches.
- F21 `tests` with no argument does not walk the workspace.
- F22 `find` omits private declarations and other-platform files.
- F23 reorder-params refusal lists six possible reasons; README does not list them.
- F24 questionable lints: defer-before-check on `defer delete(x)`; float-equality in sort comparator; naming on LSP protocol camelCase structs; bool-ternary suggesting `.Mutable in flags != false`.
- F25 `odin test tests` on ols hung past 20 min (modernized tree).

## Passed
check/lint on all packages; symbols on 194 files; ~20 def/refs/hover/callers/impl incl. proc groups, generics, enum members, using fields; renames incl. 147- and 181-edit ols renames; refusals; move; reorder-params; attr; 37-file ols modernize compiles; odinfmt over 194 files keeps every package compiling; LSP formatting/hover/documentSymbol fast.
