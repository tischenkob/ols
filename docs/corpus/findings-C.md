# Findings C: Skald and odin-lang/examples

Summary: 33 findings: crash 2 (F29, F32; F32 is also a CLI hang), wrong-edit 9 (F19, F20, F21, F22, F25, F26, F27, F28, F33), false-lint 6 (F3-F8), wrong-result 10 (F1, F2, F12, F13, F15, F16, F17, F18, F23, F24; F17 and F23 also produce wrong rename edits that the gate rolls back), improvement 6 (F9, F10, F11, F14, F30, F31). All reduced repros are confirmed except the LSP side of F32, which reproduces only inside Skald.

Binary /tmp/rols-corpus/bin/ols, `OLS_BUILTIN_FOLDER=/tmp/rols-corpus/bin/builtin`, odin dev-2026-09:a2fb372b7. Scratch: /tmp/rols-corpus/scratch-C (reductions in r1..rN).

## Setup and baseline

- Skald commit 6bbb664 (release: 1.0.0-rc16). ols.json written at root: `{"collections":[{"name":"gui","path":"."}]}` (build.sh uses `-collection:gui=.`). Note: ols.json is untracked, so `git clean -fd` deletes it; recreated after each restore.
- examples commit dcc6128. ols.json written at root: `{}` (no collections; ols.json is gitignored there).
- Baseline `odin check <pkg> -no-entry-point`: Skald 66/66 packages pass (each under 1 s). examples 78/95 pass. Failing (expected, not rols): directx/d3d12_triangle_sdl2, win32/{embedded_manifest,game_of_life,open_window} (Windows-only), nanovg and raylib/ports/{audio,core,models,shapes,textures} (several `main`s per dir), orca/ui (API drift), raylib/box2d, raylib/box3d, wgpu/* (vendor libs not built), wasm/webgl/webgl_triangle.
- `ols query check` and `lint` per package: all 161 runs exit 0, 0.1-1.4 s each (skald package 1.4 s). `symbols` on all 315 files: exit 0, no stderr, all under 2 s.

## Findings

### F1 wrong-result: default `-vet-style` turns a style nit into a Syntax Error that hides every type error
- Repro: `cd /tmp/rols-corpus/scratch-C/r1 && ols query check p --root .`
- Snippet (r1/p/p.odin, confirmed):
  ```odin
  package p

  S :: struct {
  	a, b: int
  }

  f :: proc() { x: int = "s" }
  ```
- Observed: only `p.odin:4:10: error: Syntax Error: Expected a comma, got a newline [checker]`; the real error (string assigned to int) is not reported. Exit 0.
- Expected: `odin check` without rols' flags passes the style and reports the type error. `enable_checker_vet_style` defaults to true, and the compiler reports the missing trailing comma as a Syntax Error, which stops checking. rols maps any "Syntax Error" to Error severity (check.odin `map_diagnostic_severity`).
- Corpus impact: Skald's vendored runa/normalize/normalize.odin:66 (`l, c, result: rune` without trailing comma) makes `ols query check` (and LSP checker diagnostics) of every Skald example and of `skald` show only this one error. Any real type error in those packages is hidden (confirmed by adding a type error to examples/01_hello: not reported).
- Suggest: default vet-style off, or rerun without vet flags when the only errors are vet-style syntax errors.

### F2 wrong-result (minor): `-vet-unused-variables` findings show as `error`, other vet flags as `warning`
- `ols query check skald/third_party/runa/parse` prints `cmap.odin:103:6: error: 'i' declared but not used [checker]`. check.odin's comment says "The vet flags are ours, not the user's build, so their errors show as warnings", but `vet_messages` lists only shadowing and cast messages. Plain `odin check` passes the package.

### F3 false-lint: `allocator-mismatch` on `delete` of a `[dynamic]` array or map
- Repro: `ols query lint /tmp/rols-corpus/scratch-C/r2/p --root /tmp/rols-corpus/scratch-C/r2` (confirmed)
  ```odin
  f :: proc() -> int {
  	a := make([dynamic]int, 0, 8, context.temp_allocator)
  	defer delete(a)
  	m := make(map[int]int, context.temp_allocator)
  	defer delete(m)
  	s := make([]int, 4, context.temp_allocator)
  	defer delete(s)
  	append(&a, 1)
  	m[1] = 1
  	return len(a) + len(m) + len(s)
  }
  ```
- Observed: warnings on `a`, `m` and `s`. Expected: only `s`. A dynamic array and a map store their allocator, and `delete` frees with it.
- Corpus: all 15 Skald hits are this case (bidi/resolve.odin x9, view.odin:340, runa.odin:415, colr.odin x2, cff_charstring.odin:127, indic.odin:119).

### F4 false-lint: `error-not-last` treats any union and any enum with a `None` member as an error
- Repro: `ols query lint /tmp/rols-corpus/scratch-C/r3/p --root /tmp/rols-corpus/scratch-C/r3` (confirmed, q.odin)
  ```odin
  Shape :: union { int, f32 }
  Kind :: enum { None, Box }
  make_shape :: proc() -> (s: Shape, changed: bool) { return 1, true }
  pick :: proc() -> (Kind, int) { return .Box, 1 }
  ```
- Observed: error-not-last on both. Expected: none; `Shape` is a value union and `Kind` a plain enum.
- Corpus: 15 of 16 Skald hits (`-> (view: View, new_value: T, changed: bool)` x13 in view.odin, widget_emoji_picker.odin:101, inspector.odin:235 `Widget_Kind`). Only runa gsub.odin:431 `(ok: bool, consumed, lig_glyph)` is a true hit.

### F5 false-lint: `range-off-by-one` fires when the loop never indexes the measured value
- Repro: `ols query lint /tmp/rols-corpus/scratch-C/r3/p --root /tmp/rols-corpus/scratch-C/r3` (confirmed, p.odin)
  ```odin
  prefixes :: proc(s: string) -> int {
  	n := 0
  	for b in 0 ..= len(s) {
  		n += len(s[:b])
  	}
  	return n
  }
  ```
- Observed: `'..=len(s)' runs one past the end`. Expected: none; `s[:b]` is valid for `b == len(s)`.
- Corpus: all 3 Skald hits are false (text.odin:589 and text_runa.odin:441 index a `len(text)+1` buffer; wrap_test.odin:395 slices `s[:b]`).

### F6 false-lint: `dead-store` ignores reads through a stored pointer
- Repro: `ols query lint /tmp/rols-corpus/scratch-C/r4/p --root /tmp/rols-corpus/scratch-C/r4` (confirmed)
  ```odin
  Holder :: struct { p: ^int }
  read :: proc(h: ^Holder) -> int { return h.p^ }
  f :: proc() -> int {
  	x: int
  	h := Holder{p = &x}
  	x = 5
  	a := read(&h)
  	x = 6
  	return a + read(&h)
  }
  ```
- Observed: `value stored in 'x' is never read` at `x = 5`. Expected: none, `&x` escaped into `h`.
- Corpus: both Skald hits (scroll_stamp_order_test.odin:51, scroll_test.odin:45; `ctx := Ctx{input = &input}`).

### F7 false-lint: `printf-arity` counts a multi-value call as one argument
- Repro: `ols query lint /tmp/rols-corpus/scratch-C/r6/p` with `fmt.printfln("%v %v", two())` where `two :: proc() -> (f32, int)` (confirmed; `odin run -vet` prints `1 2`).
- Observed: `format needs 2 arguments, call has 1`. Corpus: all 7 hits in examples simd/basic-sum/main.odin:189-195.

### F8 false-lint: `ignored-result` on results that are not success flags
- (a) A proc-type result whose type name contains "Error": `set_cb :: proc(cb: ErrorProc) -> ErrorProc` called as a statement gives `result of set_cb is ignored (ErrorProc)` (confirmed, r6). Corpus: glfw.SetErrorCallback x2 in examples.
- (b) `delete_key(&m, k)` on `map[K]bool`: flagged `(bool)` because the deleted value is a bool. delete_key returns the removed key and value, not a status. Corpus: 8 hits in Skald (examples/16_virtual_list/main.odin:45 and others).

### F9 improvement: `unused-parameter` fires on procedures whose signature a callback type fixes
- r5: `only_a :: proc(a: int, b: int) -> int { return a }` passed as `run(only_a)` to `cb: proc(a, b: int) -> int` gets `parameter b is unused`. The parameter cannot be removed. Most of the 86 Skald and 23 examples hits are callbacks (e.g. 00_gallery/main.odin:407, :753).

### F10 improvement (noise): `float-equality` on comparisons with exact literals
- 118 of 145 Skald hits compare with a literal 0 or 1 (`scroll.y != 0`, `if mw == 0`). These are exact by intent. Info level, but they bury the real hits.

### F11 improvement: spurious `[ERROR] analysis.odin:838:append_arg()` log on stderr
- Repro (confirmed, scratch-C/bis): a generic proc with a named argument whose value is a call:
  ```odin
  Ctx :: struct($M: typeid) { m: M }
  g :: proc(a: string) -> int { return len(a) }
  button :: proc(ctx: ^Ctx($M), on_click: M, id := 0) -> int { return id }
  f :: proc(ctx: ^Ctx(int)) -> int { return button(ctx, 1, id = g("x")) }
  ```
- `ols query lint` prints "Expected name parameter after starting named parmeter phase" twice. The code is valid. Hover and inferred types stay correct, so the visible effect is stderr noise (8+ lines per Skald file).

### F12 wrong-result: `find` skips `@(private)` declarations
- Repro (confirmed, scratch-C/r7): `@(private) hidden_helper :: proc() {}` plus `public_helper`; `cd r7 && ols query find helper` lists only public_helper. In Skald, `ols query find widget_resolve_id` exits 1 with no output though skald/widget.odin:1036 declares it. A workspace search should include package-private symbols of workspace packages.

### F13 wrong-result (minor): `symbols` output order is not stable
- `ols query symbols skald/widget.odin --root .` three runs give three different md5s; text and `--json` order changes each run (map iteration). Lines also lack the `file:` prefix the README contract states (`763:1 Function cursor_request`). Confirmed reduction: scratch-C/r8/p/p.odin with six procs `a`..`f` on lines 3-8; five runs of `ols query symbols p/p.odin` give four different orders (e.g. `a b e f c d`, `f e b a d c`).

### F14 improvement: `tests` and `check` with no argument at a root without .odin files
- `ols query tests` (or `tests .`) at the Skald or examples root prints nothing and exits 1, while `tests skald` finds 102 tests. It reads only the cwd package, not the workspace.
- `ols query check` at the Skald root prints `:1:1: error: Syntax Error: Empty directory that contains no .odin files: /private/tmp/rols-corpus/Skald [checker]` (empty file path) and exits 0. `check` exits 0 even when it reports errors (r1).

## Lint samples judged (true positives)
or-continue (51_text_styles:67), or-break (view.odin:1309), or-return (pipeline.odin:204), bool-return (22_form_extras:66), compound-assign (20_image:90), nested-if (app.odin:970), unused-declaration (view.odin:5321, bidi/resolve.odin:857), loop-single-iteration (gpos.odin:463), array-broadcast default param (view.odin:4003), naming of `UPPER := …` variables (view.odin:6623), ignored-result on bool success results (font_add_fallback, clipboard_set, gsub_apply_single_at), print-directive (nbio/udp-echo:13, sdl3/microui:55: real bugs, `eprintln` with `%v`), argument-count (47 hits all in orca/ui, which fails to compile), no-op-arithmetic (`i+0`, true but deliberate), integer-division-float (`f32(i / 2)`, true but deliberate in nanovg and shapes_colors_palette).

### F15 wrong-result: overload resolution picks the wrong procedure when a poly parameter has the caller's type name
- Corpus: `ols query hover examples/09_widgets/main.odin:175:9 --root .` on `skald.checkbox(ctx, s.dark_mode, "Use dark mode", on_dark)` shows `checkbox_payload`'s signature (with `payload: $Payload`), but the call resolves to `checkbox_simple` (4 arguments; the payload variant needs 5). Same for `skald.rating(ctx, s.stars, on_stars)` (00_gallery:552, 09_widgets:232), and `def` on the named argument `max_value =` at 09_widgets:232:41 jumps to `rating_payload`'s parameter (view.odin:2601) instead of `rating_simple`'s (view.odin:2577). Skald's procs use `$Msg` and every example declares its own `Msg` type.
- Reduced repro (confirmed): /tmp/rols-corpus/scratch-C/r11, `ols query hover app/main.odin:15:13 --root .`
  ```odin
  // lib/lib.odin
  package lib
  Ctx :: struct($M: typeid) { m: M }
  pick_simple :: proc(ctx: ^Ctx($Msg), value: int, on_change: proc(v: int) -> Msg) -> Msg { return on_change(1) }
  pick_payload :: proc(ctx: ^Ctx($Msg), value: int, payload: $P, on_change: proc(p: P, v: int) -> Msg) -> Msg { return on_change(payload, 1) }
  pick :: proc { pick_simple, pick_payload }

  // app/main.odin
  package app
  import "../lib"
  Msg :: union { int, bool }
  on_stars :: proc(v: int) -> Msg { return v }
  view :: proc(ctx: ^lib.Ctx(Msg)) -> Msg {
  	return lib.pick(ctx, 3, on_stars)
  }
  ```
- Observed: hover shows `pick_payload`'s signature. Expected: `pick_simple` (what `odin check` selects; 3 arguments). Renaming the poly parameter `$Msg` to `$M` in lib makes hover correct, so the poly name colliding with the caller's `Msg` type is the trigger. The cross-package step matters: the same code in one package (r10) resolved correctly in my tries.

### F16 wrong-result: hover and def fail on an implicit enum selector in a named argument after a variadic parameter
- Corpus: `ols query hover examples/15_advanced/main.odin:170:18 --root .` on `cross_align = .Center` inside `skald.row(…children…, cross_align = .Center)` exits 1 with no output; `def` too. `row :: proc(children: ..View, …, cross_align: Cross_Align = .Start)`.
- Reduced repro (confirmed): /tmp/rols-corpus/scratch-C/r12/p/p.odin
  ```odin
  Align :: enum { Start, Center }
  row :: proc(children: ..int, align: Align = .Start) -> int { return len(children) + int(align) }
  plain :: proc(a: int, align: Align = .Start) -> int { return a + int(align) }
  main :: proc() {
  	_ = row(1, 2, align = .Center)   // hover 17:25 and def: exit 1, nothing
  	_ = plain(1, align = .Center)    // hover 18:24: p.Align: .Center, def: line 5
  }
  ```

### F17 wrong-result / wrong-edit: a relative `--root .` limits workspace searches to the current file
- Repro (confirmed): /tmp/rols-corpus/scratch-C/r13 has `p/a.odin` (`helper :: proc() -> int`, used in `use_a`) and `p/b.odin` (`use_b` calls `helper()`).
  - `cd r13 && ols query refs p/a.odin:3:1` gives 3 results; `--root /abs/r13` gives 3; `--root .` gives 2 (b.odin missing).
  - `ols query callers p/a.odin:3:1 --root .` lists only `use_a`; without `--root`, `use_a` and `use_b`.
  - `ols query rename p/a.odin:3:1 helper2 --root .` previews `rename: 2 edits in 1 file` (b.odin not edited); `--apply` then rolls back with exit 4 (see below).
- Corpus: in Skald, `ols query refs skald/widget.odin:1036:1 --root .` gives 6 results, all in widget.odin; without `--root` it gives 62 across 5 files. `refs` on `hash_id` (widget.odin:1010:1) gives only the declaration and `callers` exits 1.
- Expected: `--root .` behaves like the absolute path. The README documents `--root DIR` with no absolute-path requirement. All earlier position queries were rerun without `--root`.
- F16 also breaks refs and rename. In Skald, `ols query refs skald/view.odin:148:2` (`Cross_Align.Center`) misses 108 `cross_align = .Center` uses in `row`/`col` calls (e.g. examples/06_flex/main.odin:33). In r12, `ols query rename p/p.odin:5:2 Middle` edits only line 18 and leaves `row(1, 2, align = .Center)`; `--apply` rolls back with exit 4 (`Undeclared name 'Center' for type 'Align'`). The compile gate catches it.

### F18 wrong-result (gate): `--apply` rolls back a safe edit when a touched package already exceeds Odin's error limit
- Corpus: `cd examples && ols query modernize --apply` exits 4 in 3 of 3 runs: `modernize: 18 edits in 18 files rolled back`. The "new" errors are `'GetMessageW' is not declared by 'win32'` and similar in win32/game_of_life (Windows-only, already failing on macOS). The only edit there is `if (instance == nil)` to `if instance == nil`. `odin check win32/game_of_life -json-errors` run 5 times gives 36 errors every time, but a different set each time (sorted-message md5 differs on every run). The compiler stops at its error limit, and procedures are checked in parallel, so different errors survive the limit. One run also flagged raylib/ports/textures, whose "Different package name" error names whichever file Odin parses first.
- Reduced repro (confirmed, flaky): /tmp/rols-corpus/scratch-C/r14/p/a.odin has `f :: proc(x: int) -> int { if (x > 0) { return 1 }; return 0 }` plus 60 procs `g_N :: proc() { missing_N() }`. `ols query modernize --apply` in r14 exited 4, 4, 4, 0, 0 over five runs (restore a.odin between runs from the same text).
- Expected: an edit that cannot add errors applies. The gate warns that it "cannot see" new errors behind the limit. It then still treats the errors that the limit happened to report as new. Suggest: in a directory whose before-check hit the error limit or already had errors, do not roll back on unmatched errors of the same kind, or compare only error counts below the limit.

### F19 wrong-edit: `use-stdlib/sum` rewrites a sum over a range into `math.sum(1 ..= n)`, which does not parse
- Corpus: Skald examples/40_threads/main.odin:72 `for i in 1..=10_000_000 { total += i }` gets lint `Use math.sum`. Action `Replace with math.sum` rolls back (exit 4, `Syntax Error: Expected ')', got '..='`). `ols query modernize` over all of Skald is refused (exit 1) by this one file: `a pass of use-stdlib/sum produced code that does not parse and was undone`.
- Reduced repro (confirmed): /tmp/rols-corpus/scratch-C/r15/p/p.odin
  ```odin
  total :: proc() -> int {
  	t := 0
  	for i in 1 ..= 10 {
  		t += i
  	}
  	return t
  }
  ```
  `ols query actions p/p.odin:5:2 --apply "Replace with math.sum" --no-check` writes `return math.sum(1 ..= 10)`. Expected: no lint or fix when the loop ranges over an interval rather than a slice or array.

### F20 wrong-edit: `use-stdlib/fill-indexed` passes a fixed array to `slice.fill`
- Reduced repro (confirmed): /tmp/rols-corpus/scratch-C/r16/p/p.odin
  ```odin
  State :: struct { open: [9]bool }
  init :: proc() -> State {
  	s: State
  	for i in 0 ..< len(s.open) { s.open[i] = true }
  	return s
  }
  ```
  `ols query modernize --diff` rewrites the loop to `slice.fill(s.open, true)`; `--apply` rolls back with exit 4 (`Cannot determine polymorphic type from parameter: '[9]bool' to '$T/[]$E'`, compiler suggests `s.open[:]`). Expected: `slice.fill(s.open[:], true)`.
- Corpus: Skald examples/00_gallery/main.odin:266 (`s.open_section: [9]bool`). There the gate did NOT catch it (see F21).

### F21 wrong-edit (gate): rols' own `-vet-style` makes a compiling package look broken, and `--apply` writes code that does not compile
- Corpus: `cd Skald && ols query modernize skald examples/<all but 40_threads> --apply` printed `modernize: 30 edits in 30 files written, 66 packages checked`, exit 0. Afterwards plain `odin check examples/00_gallery -collection:gui=.` fails with the F20 error. The gate's check of 00_gallery saw only the F1 vet-style Syntax Error from the imported runa/normalize, before and after, so it reported no new errors.
- Reduced repro (confirmed): /tmp/rols-corpus/scratch-C/r17 (original text in r17/orig.odin.txt): the F20 snippet plus `Pair :: struct {\n\ta, b: int\n}` (no trailing comma). `ols query modernize --apply` prints the "gate cannot see them" warning, then `1 edit in 1 file written`, exit 0. `odin check p -no-entry-point` passed before the edit and now fails.
- Expected: the gate checks with the user's flags (or at least without `-vet-style`), so a package that compiles is not treated as already broken. The warning is printed, but rols itself caused the "existing error" that blinds the gate.

### F22 wrong-edit (minor): `bool-return` deletes a comment between the `if` and the final `return`
- Reduced repro (confirmed): /tmp/rols-corpus/scratch-C/r18/p/p.odin; `ols query modernize --diff` replaces
  ```odin
  	if a == b {
  		return false
  	}

  	// Rule 999: default is to break.
  	return true
  ```
  with `return a != b`, which drops the comment. Corpus: runa itemize (`// GB999 — default break.`) and the word-break file (`// WB999: default ÷ — break.`) lose their rule-reference comments under `modernize --apply`.

### F23 wrong-result / wrong-edit: an implicit enum selector inside a compound literal passed as a call argument is not resolved, so refs and rename miss it
- Corpus: `cd examples && ols query rename sdl2/chase_in_space/chase_in_space.odin:27:2 FOE` (`EntityType.ENEMY`) edits 4 of 7 uses. It misses `append(&game.entities, Entity{type = .ENEMY, …})` at lines 180-182, and `--apply` rolls back with exit 4.
- Reduced repro (confirmed): /tmp/rols-corpus/scratch-C/r20/p/p.odin
  ```odin
  Kind :: enum { A, B }
  Item :: struct { kind: Kind }
  take :: proc(it: Item) -> Kind { return it.kind }
  main :: proc() {
  	items: [dynamic]Item
  	x := Item{kind = .B}                // hover on .B works, renamed
  	append(&items, Item{kind = .B})     // hover exits 1, not renamed
  	_ = take(Item{kind = .B})           // hover exits 1, not renamed
  	_ = x
  }
  ```
  `ols query rename p/p.odin:5:2 C --apply` exits 4 (`Undeclared name 'B' for type 'Kind'` at 19:30 and 20:24). Renaming the field `kind` covers all three, so only the enum value inside the literal is lost. This is related to F16 but is a separate case: no variadic or named argument is needed; `take` is a plain one-parameter proc.

### F24 wrong-result: `move --to` refuses a cwd-relative path with directories and an absolute path through a symlink
- Repro (confirmed): /tmp/rols-corpus/scratch-C/r13 (package `p` with a.odin and b.odin), run from `/tmp/rols-corpus/scratch-C/r13`:
  - `ols query move p/b.odin:3:1 --to p/c.odin` gives `error: the target must be in the directory of the declaration`, exit 1.
  - `ols query move p/b.odin:3:1 --to /tmp/rols-corpus/scratch-C/r13/p/c.odin` gives the same refusal. /tmp is a symlink to /private/tmp; the `/private/tmp/...` form works.
  - `ols query move p/b.odin:3:1 --to c.odin` works (a bare name is resolved against the declaration's directory).
- Expected: `--to` is resolved like the other path arguments (cwd-relative) and compared after resolving symlinks. The corpus run (`examples`, `sdl2/chase_in_space/chase_in_space.odin:144:1 --to sdl2/chase_in_space/util.odin`) hit the same refusal; `--to util.odin` then applied cleanly.

### F25 wrong-edit: "Add ok result" leaves callers broken and returns `true` on the failure path
- Corpus: `cd examples && ols query actions sdl2/chase_in_space/chase_in_space.odin:61:1 --apply "Add ok result"` rolls back (exit 4): `chase_in_space.odin:132:4: Assignment count mismatch`.
- Reduced repro (confirmed): /tmp/rols-corpus/scratch-C/r21 (original text in orig.txt). `ols query actions p/p.odin:3:1 --apply "Add ok result" --no-check` turns
  ```odin
  find :: proc(xs: []int, v: int) -> ^int {
  	for _, i in xs { if xs[i] == v { return &xs[i] } }
  	return nil
  }
  ...
  	p := find(xs, 2)
  ```
  into `-> (^int, bool)` with `return &xs[i], true` and `return nil, true`. The caller `p := find(xs, 2)` is unchanged, so the package no longer compiles. Expected: callers are updated (`p, _ := find(xs, 2)`) or the action is refused when the procedure has callers. Also, `return nil, true` marks the not-found path as success.

### F26 wrong-edit: "Unwrap block" on a range loop whose body uses the loop variable
- Corpus: `cd examples && ols query actions sdl2/chase_in_space/chase_in_space.odin:62:2 --apply "Unwrap block"` rolls back (exit 4, `Undeclared name: i`).
- Reduced repro (confirmed): r21, `ols query actions p/p.odin:14:2 --apply "Unwrap block" --no-check` on
  ```odin
  	for x in xs {
  		n += x
  	}
  ```
  writes `n += x`, which does not compile. Even when the body does not use the variable, unwrapping a loop runs the body once instead of len(xs) times. Expected: the action is not offered on a `for` statement whose body uses the loop variables. It is also worth reconsidering for any loop, since the README describes it as "unwrap a block, if or loop body" without saying what happens to the iteration.

### F27 wrong-edit: "Invert if" and "Unwrap block" on a one-line `if` body indent with a space
- Reduced repro (confirmed): /tmp/rols-corpus/scratch-C/r22/p/p.odin (original in orig.txt)
  ```odin
  label :: proc(running: bool) -> string {
  	l := "Start"
  	if running { l = "Pause" }
  	return l
  }
  ```
  - `ols query actions p/p.odin:5:2 --apply "Invert if"` rolls back with exit 4 (`Syntax Error: With '-vet-tabs', tabs must be used for indentation`). With `--no-check` it writes `if !running {\n} else {\n l = "Pause"\n}`: the body line is indented by one space and has no tab, and the then-branch is empty.
  - "Unwrap block" writes `\t l = "Pause"` (tab plus space).
- Expected: the body is re-indented with tabs at the block's depth, and Invert if on a one-line body gives `if !running {} else {…}` or is not offered. Corpus: Skald examples/13_stopwatch/main.odin:79:2 (both roll back).

### F28 wrong-edit (gate blinded by F1): "Unwrap block" leaves unreachable code that plain `odin check` rejects
- Corpus: `cd Skald && ols query actions examples/13_stopwatch/main.odin:37:3 --apply "Unwrap block"` (and :56:3) prints `written, 1 package checked`, exit 0. The `if out.running { …; return out, {} }` body is spliced into the case, and plain `odin check examples/13_stopwatch -collection:gui=.` then fails: `Error: Statements after this 'return' are never executed`. The gate saw only the F1 vet-style error from runa. The action is meant to change behavior, but it should not be offered, or should be refused, when the unwrapped body ends in `return` and statements follow.
- Reduced repro (confirmed): /tmp/rols-corpus/scratch-C/r23/p/p.odin `f :: proc(running: bool) -> int { if running { return 1 }; return 2 }` (multi-line). "Unwrap block" is offered at 4:2, and `--apply` rolls back (exit 4, `Statements after this 'return' are never executed`). In a clean package the gate catches it; in Skald, F1 hides it and the broken code is written.

### F29 crash: `textDocument/inlayHint` segfaults (SIGSEGV); its type labels are NUL bytes or other garbage
- Corpus: the LSP driver's first inlayHint on examples/arena_allocator/arena_allocator.odin kills the server with signal 11, 3 of 3 runs (`python3 /tmp/rols-corpus/scratch-C/inlay_one.py /tmp/rols-corpus/examples /tmp/rols-corpus/examples/arena_allocator/arena_allocator.odin` prints `CRASH rc=-11`). The file is valid (baseline `odin check` passes).
- Reduced repros (confirmed, /tmp/rols-corpus/scratch-C/r24; run `python3 ../inlay_one.py . p/p.odin` after copying the file to p/p.odin):
  - crash_min.odin, 3 lines of incomplete code (what an editor sends while typing), SIGSEGV on every run:
    ```odin
    package arena_allocator
    load_files :: proc() -> ([]string, vmem.Arena) {
    	res := make([]string, 3, arena_alloc)
    ```
  - repro_min.odin (valid code), no crash but the labels are garbage: for `a, b := two()` and `c := one()` (two :: proc() -> (int, bool), one :: proc() -> int), all three hints have label `": "` followed by 28+ NUL bytes. crash_valid.odin (`res := make([]string, 3, context.allocator)`) has a label of `": "` plus blank/garbage bytes instead of `: []string`. Only `x := 5` / `y := x + 1` give correct `: int`.
- Expected: `: int`, `: bool`, `: []string`. The pattern (correct for literal types, garbage for types resolved through a call) points at a label string that lives in memory freed before the response is serialized (CLAUDE.md: temp memory is freed after each request). Reading that freed memory can segfault.

### F30 improvement (formatter): a one-line compound literal with a trailing comment is expanded, and the output is not idempotent
- Corpus: after `odinfmt -w` on every file of both projects (scratch-C/fmt), every baseline-passing package still passes `odin check` (no new failures). A second pass changes 6 files: Skald zone_test.odin, scroll_test.odin, drag_drop_test.odin, runa/cache.odin, examples/55_node_graph/main.odin, and examples raylib/tetroid.
- Reduced repro (confirmed): /tmp/rols-corpus/scratch-C/r25/a.txt; `odinfmt -stdin < a.txt` turns
  `input = Input{pos = {9, 9}} // far away` into
  ```
  	input = Input {
  		pos = {9, 9},
  	} 	// far away
  ```
  with a space and a tab before the comment. A second pass rewrites that line to `} // far away`. Expected: the short literal stays on one line (it fits in 120 columns), and one pass reaches a fixed point.

### F31 improvement (formatter): splitting a long line of `;`-separated statements is not idempotent
- Reduced repro (confirmed): /tmp/rols-corpus/scratch-C/r25/b.odin, `case 0: incoming_piece[1][1] = .Moving; incoming_piece[2][1] = .Moving; incoming_piece[1][2] = .Moving; incoming_piece[2][2] = .Moving //Cube`. Pass 1 (r25/b_pass1.txt) moves the last statement to its own line and keeps three on the first line (2 tabs + 98 chars). Pass 2 moves the third statement off as well. Pass 3 is stable. From examples raylib/tetroid/raylib_tetroid.odin:342-349.

### F32 crash / slow: code actions on a call that omits a defaulted parameter hang the CLI and crash the LSP server
- CLI (confirmed, minimal): /tmp/rols-corpus/scratch-C/r27/p/a.odin (copy in r27/hang_min.odin.txt)
  ```odin
  draw :: proc(x: int, aa := false) {
  	_ = x
  }

  use :: proc() {
  	draw(1)
  }
  ```
  `cd r27 && timeout 10 ols query actions p/a.odin:8:2` is killed by the timeout (exit 124) every time. Without `aa := false` (r28), the same query returns `Inline procedure call` at once.
- LSP: `textDocument/codeAction` at a call such as `draw_circle(r, {0, 0}, 0, white)` in Skald's skald/draw_vector_test.odin:99-104 kills the server with SIGSEGV (`python3 /tmp/rols-corpus/scratch-C/ca_one.py /tmp/rols-corpus/Skald /tmp/rols-corpus/Skald/skald/draw_vector_test.odin 99 2` prints `rc= -11`). A 5-line probe file in package skald reproduces it: `probe_a :: proc(r: ^Renderer) { draw_circle(r, {0, 0}, 0, {}) }`. A standalone copy of draw_circle (scratch-C/r29) makes the CLI hang (exit 124) but returns `[]` over LSP, so I could reduce the LSP crash only inside Skald. Same callee, same position, so the same root cause is likely; the LSP effect probably differs because of memory state.
- Corpus: `ols query actions skald/draw_vector_test.odin:99:2` through `:105:2` all time out (exit 124). The Skald LSP sweep crashed there.

### F33 wrong-edit: "Inline procedure call" inlines a body that uses a file-private helper into another file
- Reduced repro (confirmed): /tmp/rols-corpus/scratch-C/r27 originals in inl_a.txt / inl_b.txt. a.odin has `@(private = "file") norm :: proc(v: int) -> int` and `draw :: proc(x: int) { _ = norm(x) }`; b.odin has `use :: proc() { draw(1) }`. `ols query actions p/b.odin:4:2` offers "Inline procedure call", and `--apply` rolls back with exit 4 (`b.odin:6:7: Undeclared name: norm`). Expected: not offered, as `move` refuses declarations that use file-private symbols.
- F29 corpus counts (LSP sweep, scratch-C/lsp_drive.py): examples, 140 files: inlayHint crashed (SIGSEGV) on 6 files and hung on 17 more (no reply in 20 s, main thread spinning in `_proclit$anon-2`, from `sample`). Skald, 132 of 175 files reached: inlayHint SIGSEGV on 9 (skald/app.odin, audio.odin, text.odin, runa/bidi/resolve.odin, runa/cache.odin, runa/parse/avar.odin, cff2.odin, cmap.odin, image_dmabuf_linux.odin). The run then stopped on an external SIGTERM.

## LSP stdio sweep (step 5)
Driver: /tmp/rols-corpus/scratch-C/lsp_drive.py (restarts the server after a crash or hang; `SKIP=inlay` drops inlayHint). For every file it sends didOpen, documentSymbol, semanticTokens/full, inlayHint over the whole file, codeAction and hover at 3 positions, formatting, and didClose.
- With inlayHint skipped: examples 140/140 files and Skald 175/175 files. 0 error responses and 0 requests slower than 2 s (counts: examples 139 documentSymbol, 139 semanticTokens, 417 codeAction, 417 hover, 139 formatting; Skald 173/173/518/518/172). The one SIGSEGV is F32 (codeAction at skald/draw_vector_test.odin:104:2). Single-file reruns for SIGTERMed files were clean.
- inlayHint: see F29.
- Environment noise: other sweeps on this machine sent SIGTERM (-15) to `ols` processes several times. I counted only SIGSEGV (-11) and hangs as findings. One `odin check examples/25_collapsible` (no rols involved) ran for over 70 CPU-minutes during a parallel load and then passed in 0.3 s on rerun; I treat it as an Odin or host issue, not rols.

## Formatter (step 6)
`odinfmt -w` on all 315 files of scratch copies (scratch-C/fmt): no odinfmt failure. Every package that passed `odin check` before still passes (Skald 66/66, examples 78/78). Second-pass non-idempotence: F30, F31.

## Passed cleanly
- `symbols` on all 315 files: exit 0, no stderr, all under 2 s, and the symbol set matches the declarations (order aside, F13).
- `check` and `lint` per package: 161 runs, all exit 0, 0.1-1.4 s.
- Position queries (absolute or no `--root`): def, hover, refs and callers on `hash_id` (refs exactly match a grep of all 85 non-comment uses across 22 files), `widget_store_init`, `widget_resolve_id`, struct fields (`Game_Settings.window_title`, `Widget_Store.auto_id`, a `using`-promoted `Window_Target.swapchain` via `r.swapchain`: def correct, refs 8/8), package-qualified `strings.concatenate` and `json.unmarshal`, generic procs `upload_buffer` and `byte_arr_str`, locals, and callees of `main`. `find` and `tests` with a DIR are correct.
- Edits applied and verified with plain `odin check` and `odin test skald` (102 tests pass): rename of `hash_id` (75 edits in 22 files), `Widget_Store.auto_id` (10 edits in 2 files), `Widget_Kind.Toggle`, a local `out` (the collision with `b` was correctly refused with locations), `Entity.pos` in examples (34 edits); `reorder-params` on `find_entity` (callers updated); the refusal for `draw_rect` (has defaults) is documented; `move get_time --to util.odin` (import added); `rename-package runa/bidi bidix` (package clauses, import path, 4 qualifiers, directory rename; warnings list comments); `attr add skald.hash_id require_results`; `attr rename private ppp` correctly rolled back by the gate (unknown attribute).
- modernize on examples: 57 fixes in 18 files, meaning-preserving on review; all 78 passing packages still pass and a second run reports "nothing to change" (exit 3). modernize on Skald, excluding 40_threads: 30 files; review found no meaning change except F20 (does not compile) and F22 (comment lost).
- Code actions that applied and compiled: Invert if (multi-line bodies), Convert to do, Inline variable (5 sites), Add explicit type, Add loop label, Move to new file, Add doc comment, Generate test, Extract procedure (2 sites, correct multi-result signature), Extract variable on sub-expressions.

## Timing
Whole-project `modernize` list: examples 2.3 s, Skald 3.2 s. `modernize --apply` with the gate: examples 4.9 s (18 packages), Skald 6.8 s (66 packages). Rename of `hash_id` with the gate: 4.5 s (58 packages). Query latency is 0.1-2.0 s (the slowest was `def` on a generic call in the 13k-line view.odin, 1.96 s).
