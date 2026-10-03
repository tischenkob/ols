# Findings D: karl2d + Odin core/vendor

Binary /tmp/rols-corpus/bin/ols, `OLS_BUILTIN_FOLDER=/tmp/rols-corpus/bin/builtin`, odin dev-2026-09:a2fb372b7, host darwin_arm64.
Scratch repros in /tmp/rols-corpus/scratch-D/r*/.

## karl2d

- Commit: 0b8c663 "Audio backend interfaces: Stop using interface + state in same struct (#299)".
- ols.json written at the root (added to .git/info/exclude so `git clean` keeps it): `{"collections": []}`. Imports are relative (`k2 "../.."`), so no collections are needed.
- Baseline `odin check <dir> -no-entry-point`, host target: 56 package dirs pass. 2 fail for reasons outside the project: `examples/box2d` (vendor box2d lib not built) and `platform_bindings/linux/evdev` (`linux.ioctl` not declared on this Odin). Cross-target checks (`-target:linux_amd64`, `windows_amd64`) stop at vendor stb `#panic` (libs not built), so windows/linux/js-only files could not be compile-checked; `-target:js_wasm32` passes.
- Timing: `query check` 0.12-1.15 s per package (root 1.15 s), `query lint` 0.1-1.0 s, `symbols` <= 0.32 s per file, def/refs/hover 0.12-0.5 s. No timeouts, no crashes, no panics on stderr.
- Edit step note: `modernize --apply` on karl2d was denied by the session permission classifier and was NOT run. Its dry-run diff was reviewed and suspicious rewrites were checked with scratch snippets. Rename `--apply` runs were allowed.

### Findings (karl2d, steps 3-4)

#### K1. wrong-result: files excluded by `#+build` for the host are invisible to `symbols`, `find`, `def`, `hover`, `refs`
- Repro: `cd /tmp/rols-corpus/karl2d; ols query symbols platform_linux.odin` prints nothing, exit 1, no stderr (`--json` prints `[]`). Same for all 17 `#+build linux|windows|js|ignore` files in the root. `ols query def karl2d.odin:7471:14` (`PLATFORM_LINUX`) and `:7467:14` (`PLATFORM_WINDOWS`) exit 1; `def karl2d.odin:7473:14` (`PLATFORM_MAC`) works. `hover platform_windows.odin:68:9` (`win32.SetProcessDpiAwarenessContext`) exits 1. `find linux_init` exits 1.
- Expected: `symbols` is a syntactic outline and should list the file's declarations regardless of build tags. For def/hover/refs, either resolve in the queried file's own platform context or print a note such as "file excluded for target darwin; set a profile with os". Setting `{"profile":"w","profiles":[{"name":"w","os":"windows"}]}` makes the windows queries work, so the data is there.
- Inconsistency: a file excluded only by its name suffix (`d_windows.odin`) does get `symbols`, but its declarations are still missing from `find`.
- Reduced (confirmed), /tmp/rols-corpus/scratch-D/r1:
  ```odin
  // a_linux.odin
  #+build linux
  package r1
  foo :: proc() {}
  ```
  `ols query symbols a_linux.odin` gives exit 1 and empty output. A `#+build ignore` file behaves the same.

#### K2. false-lint: `argument-count` error in file-private procs of build-excluded files (same root cause as K1)
- Repro: `ols query lint render_backend_d3d11.odin` reports `619:9: error: 'create_texture' takes 3 arguments, got 4` (also at 764:9, and webgl 487:25, 510:25, 566:25). These files are `#+private file` and declare their own 4-parameter `create_texture`, which shadows the public 3-parameter `karl2d.create_texture`. `def render_backend_d3d11.odin:619:9` also jumps to karl2d.odin:1888 instead of d3d11:551. The same pattern in render_backend_gl.odin (built on darwin) resolves correctly.
- Expected: no diagnostic. The code compiles for its target.
- Reduced (confirmed; `odin check -target:windows_amd64` passes), /tmp/rols-corpus/scratch-D/r7:
  ```odin
  // b.odin
  package r7
  create :: proc(a: int) {}
  // w.odin
  #+build windows
  #+private file
  package r7
  create :: proc(a: int, b: rawptr) {}
  use :: proc() { create(1, nil) }
  ```
  `ols query lint .` gives `w.odin:8:2: error: 'create' takes 1 argument, got 2 [argument-count]`. An error-severity false positive.

#### K3. false-lint: `allocator-mismatch` on `delete` of a dynamic array
- Repro: `ols query lint font_cache` reports `153:2` and `359:2` "'keys' was allocated with cache.allocator but freed with the context allocator". `delete` on a `[dynamic]T` (and on a map) frees with the allocator stored in the container, so there is no mismatch.
- Reduced (confirmed), r7/a.odin:
  ```odin
  f :: proc(c: ^C) {
  	keys := make([dynamic]int, c.allocator)
  	append(&keys, 1)
  	delete(keys)
  }
  ```
- Expected: fire only for slices and strings (and similar), which do not store their allocator.

#### K4. false-lint (noise): `ignored-result` on `sync.mutex_guard(&m)` as a statement
- 27 of the 105 `ignored-result` hits in karl2d. `mutex_guard` is `@(deferred_out=...)` and its statement form is the normal use. The bool is always true. Reduced (confirmed), r7/a.odin: `sync.mutex_guard(&m)`.
- Expected: skip procs with `deferred_in`/`deferred_out`/`deferred_in_out` attributes.

#### K5. false-lint (noise): `empty-body` on `for step() {}`
- 24 hits, one per example `main` loop (`examples/cursors/cursors.odin:18:13`, ...). A `for` loop whose condition has side effects and an empty body is idiomatic. Reduced (confirmed), r7/a.odin: `for step() {}` with `step :: proc() -> bool`.
- Expected: no warning when the loop condition contains a call.

#### K6. wrong-result: `def` on a field accessed through an alias constant returns the alias target's file with the field's range
- Repro: `ols query def karl2d.odin:100:5 --json` (`pf.set_window_icon`, where `pf :: PLATFORM` and `PLATFORM :: PLATFORM_MAC`) returns uri platform_mac.odin, range line 28 (0-based) chars 1-16. That is the position of the `set_window_icon` field in platform_interface.odin:29, so text mode prints `platform_mac.odin:29:2: get_screen_width = mac_get_screen_width,`, which is unrelated.
- Reduced (confirmed), /tmp/rols-corpus/scratch-D/r2:
  ```odin
  // a.odin
  S :: struct {
  	x: proc(),
  }
  // b.odin (S literal in another file)
  V :: S { x = f }
  f :: proc() {}
  // c.odin
  qq :: V
  use4 :: proc() { qq.x() }
  ```
  `ols query def c.odin:17:5 --json` gives uri b.odin with the a.odin range (3:1). Direct `V.x()` resolves correctly to a.odin.

#### K7. wrong-result: `when` with a non-OS condition resolves to the wrong branch, or to nothing
- Repro: `ols query def karl2d.odin:108:21` and `hover` on `RENDER_BACKEND` exit 1. It is declared in `when RENDER_BACKEND_NAME == "gl" {...} else when ... else { #panic(...) }` (render_backend_chooser.odin). `AUDIO_BACKEND` is the same.
- Reduced (confirmed), /tmp/rols-corpus/scratch-D/r4:
  ```odin
  D_NAME :: "x"
  when D_NAME == "x" { D :: 1 } else { D :: 2 }      // def of D -> "D :: 2" (wrong branch)
  NAME :: #config(R4_NAME, "")
  when NAME == "" { B :: 1 } else { B :: 2 }         // def of B -> "B :: 2" (wrong branch)
  E_NAME :: "gl"
  when E_NAME == "gl" { E :: 1 } else when E_NAME == "d3d" { E :: 2 } else { #panic("bad") }
  // def/hover of E -> exit 1, nothing
  ```
- Expected: evaluate constant string and bool comparisons, as the `ODIN_OS` case already does. At minimum, fall back to any branch's declaration instead of nothing.

#### K8. wrong-result: a `#+build ignore` file takes part in callers, refs and symbol-path lookup
- karl2d.doc.odin (`#+build ignore`) repeats every API signature without a body. `ols query callers karl2d.odin:1622:1` lists `draw_text karl2d.doc.odin:449:1` as a caller of `draw_text`. `refs` includes the doc declaration. `ols query rename /tmp/rols-corpus/karl2d.Shader_Default_Inputs.Unknown None` is refused: "`Shader_Default_Inputs` is declared 2 times ... karl2d.doc.odin:1490:1, karl2d.odin:6037:1".
- Reduced (confirmed), /tmp/rols-corpus/scratch-D/r8: `a.odin` has `draw :: proc(x: int) {}` and `main` calls `draw(1)`. `doc.odin` has `#+build ignore` and `draw :: proc(x: int)`. `callers a.odin:3:1` lists `draw doc.odin:4:1`. `rename r8.draw paint` (run from the parent dir) is refused as "declared 2 times".
- Expected: a bodyless declaration is not a caller. A `#+build ignore` file should not make a symbol path ambiguous.

#### K9. improvement: a symbol path cannot name the package in the cwd
- `ols query rename .Shader_Default_Inputs.Unknown X` and `./Shader_Default_Inputs.Unknown` are refused ("is neither FILE:LINE:COL nor PKG.Name"). Only `../karl2d.X` or an absolute path works.

#### K10. improvement: `find` omits private declarations
- `find mac_init`, `find d3d11_create_texture`, and in r1 `find priv_pkg_proc` (`@(private)`), `priv_attr_file`, and `priv_file_proc` (`#+private file`) all exit 1. A CLI workspace search that cannot find most of karl2d's backend code (all `#+private file`) is of little use. It may be inherited from upstream workspace symbols.

#### K11. improvement: `symbols` text output lacks the file path
- `ols query symbols font_cache/font_cache.odin` prints `75:1 Function init_cache`. The README contract is `file:line:col: text`, which `find` follows.

#### K12. improvement: `tests` with no argument only looks at the cwd package
- In karl2d root, `ols query tests` (and `tests .`, `tests tests`) exits 1 with no output. `tests tests/coordinate_system` lists them. The README does not say whether DIR is recursive. With no argument a workspace-wide listing would be expected.

#### K13. wrong-edit: modernize `use-stdlib/fill-ref` emits `slice.fill` on a fixed or enumerated array
- `ols query modernize --diff` in karl2d rewrites `for &d in shd.default_input_offsets { d = -1 }` (type `[Shader_Default_Inputs]int`) to `slice.fill(shd.default_input_offsets, -1)`.
- Reduced (confirmed), /tmp/rols-corpus/scratch-D/r6: struct fields `offs: [E]int` and `arr: [4]int`, with loops `for &d in s.offs { d = -1 }` and `for &d in s.arr { d = 0 }`. modernize gives `slice.fill(s.offs, -1)` and `slice.fill(s.arr, 0)`. `odin check` of that output (r6b) fails: "Cannot determine polymorphic type from parameter: '[4]int' to '$T/[]$E'". Adding `[:]` fixes fixed arrays, but "enumerated arrays cannot be sliced".
- Expected: add `[:]` for fixed arrays and skip enumerated arrays. On karl2d this one fix makes the whole-project `--apply` roll back, or fail to compile under `--no-check`.

#### K14. improvement: `redundant-parens` on a multi-line condition leaves the brace on its own line
- karl2d.odin:5670, 7653; space_cat.odin:670 give `if a &&\n\t\tb &&\n\t\tc\n {`. evdev.odin:21 and wlcsd:825 give `return a |\n ...\n\n}` with an empty line before `}`. A scratch check (r5) shows it still compiles, so this is cosmetic.

#### Unverified edits (please run during triage)
- `cd /tmp/rols-corpus/karl2d && ols query modernize --apply` (denied here). Expected: rollback, exit 4, because of K13.
- The modernize `or_return` fixes in platform_windows_glue_gl.odin:141/154 (`win32.wglChoosePixelFormatARB(...) or_return` in a proc returning `bool`, where the operand is `win32.BOOL`) cannot be compile-checked on darwin. A scratch analogue with `BOOL :: distinct b32` compiled.

#### K15. wrong-edit: "Move to FILE" code action (and `move --to`) offers files with other build constraints
- Repro: `ols query actions karl2d.odin:7488:1` offers "Move to audio_backend_alsa.odin" (`#+build linux`), "...waveout.odin" (windows), "...web_audio.odin" (js) and "...core_audio.odin" (`#+build darwin` + `#+private package`). Applying the alsa move rolls back (exit 4, "Undeclared name: get_shader_input_default_type"). Applying the core_audio move is written and passes the host gate. The public proc then exists only on darwin and becomes package-private, which silently breaks the windows/linux/js builds.
- Reduced (confirmed), /tmp/rols-corpus/scratch-D/r9: `a.odin` has a public `helper` and its caller. `b.odin` is `#+build darwin` / `#+private package`. `c.odin` is `#+build linux`. `actions a.odin:3:1` offers "Move to b.odin" and "Move to c.odin". After `--apply "Move to b.odin"` the darwin check passes, but `odin check . -target:linux_amd64` fails with "Undeclared name: helper".
- Expected: offer only target files whose build constraints and `#+private` tag match the source file's, or refuse.

#### K16. wrong-edit: "Add ok result" does not update callers
- Repro: `ols query actions karl2d.odin:7488:1 --apply "Add ok result"` gives exit 4, rolled back: "karl2d.odin:5216:3: Assignment count mismatch '1' = '2'".
- Reduced (confirmed), /tmp/rols-corpus/scratch-D/r10:
  ```odin
  E :: enum { A, B }
  f :: proc() -> E { return .A }
  g :: proc() { x := f(); _ = x }
  ```
  `actions a.odin:5:1 --apply "Add ok result"` gives exit 4, "Assignment count mismatch".
- Expected: rewrite single-value call sites (`x, _ := f()`), or do not offer the action when such callers exist.

#### K17. wrong-edit: "Generate test" stub does not compile for an enum (or other non-literal) result
- Repro: `ols query actions karl2d.odin:7488:1 --apply "Generate test for get_shader_input_default_type"` gives exit 4: "karl2d_test.odin:8:34: Missing type in compound literal". The generated stub is `result := get_shader_input_default_type("", {})` followed by `testing.expect_value(t, result, {})`.
- Reduced (confirmed): r10 with `--apply "Generate test for f"` produces the same error.
- Expected: use the result's type (`E{}` or a zero value `E(0)`), or `testing.expect_value(t, result, result)`.

#### K18. improvement: "Invert if" on an `if` without `else` leaves an empty then-branch
- `actions karl2d.odin:832:2 --apply "Invert if"` gives `if !(allow_repeat && s.key_repeat[key]) {\n} else {\n\treturn true\n}`. It compiles and keeps the meaning, but is not a useful rewrite. The same happens at karl2d.odin:2982.

#### K19. improvement: duplicate action title, and `move --to` path handling
- `actions font_cache/font_cache.odin:503:3` lists "Merge nested if" twice.
- `move X --to font_cache/iter.odin` (cwd-relative, like every other path argument) is refused with "the target must be in the directory of the declaration". `--to iter.odin` works. An absolute `--to /tmp/rols-corpus/karl2d/font_cache/iter.odin` is refused because `/tmp` is a symlink to `/private/tmp`. Only `/private/tmp/...` works. The symlink case is a real bug; the relative-path convention is a usability issue.

#### K20. wrong-result: `reorder-params` refused because of a bodyless declaration in a `#+build ignore` file (same root as K8)
- `ols query reorder-params karl2d.odin:4481:1 --order 0,2,1` (`rect_shrink`) is refused: "karl2d.doc.odin:887:1 uses rect_shrink other than as a call".

### Edits that passed (karl2d)
- Renames, each `--apply` exit 0 then `odin check` clean: package proc `font_cache.init_cache` (2 edits, 2 files), struct field `State.depth_range_min` (9 edits; it did not touch the unrelated `Init_Options.depth_range_min`), enum member `Shader_Default_Inputs.Unknown` by position (5 edits; it did not touch `Pixel_Format.Unknown`), local `default_format` (3 edits).
- `move font_cache/font_cache.odin:404:1 --to iter.odin`: applied, compiles. A dry-run move of `init_cache` correctly adds `import "base:runtime"`.
- `reorder-params font_cache/font_cache.odin:492:1 --order 0,2,1` (`add_rect`): applied, call sites swapped, compiles.
- `rename-package platform_bindings/mac/nsgl nsopengl`: 17 edits plus a directory rename, applied, compiles. `rename-package log klog` was refused for a documented reason: package clause `karl2d_logger` differs from the directory name.
- `attr add ... require_results` on `add_rect` and `attr add ... private="file"` on `get_shader_input_default_type`: applied, compile.
- Code actions applied and checked clean: Return the condition, Split if, Convert to do, Add loop label, Use or_continue, Add explicit type, Replace with slice.contains, Invert if (early continue), Merge nested if, Inline variable, Convert to if/else, Add doc comment, Extract variable (selection), Extract procedure (selection), Split case. "Unwrap block" on an `if` followed by `return` correctly rolled back (unreachable code). "Replace with slice.fill" rolled back (K13).
- modernize dry-run, other rules reviewed and judged meaning-preserving: nested-if (with correct parenthesization of `||`), redundant-else (2 passes), or-continue, or-return, bool-compare, bool-return, use-stdlib/contains.

### Lint samples judged (karl2d, 618 hits: naming 352, ignored-result 105, unused-parameter 52, float-equality 32, empty-body 24, nested-if 13, ...)
True positives:
- print-directive at render_backend_d3d11.odin:820 and render_backend_gl.odin:687/1078: `log.error("... %v", x)` is not a format proc.
- duplicate-condition at render_backend_d3d11.odin:837: the `Linear,Linear,Linear` branch is repeated.
- unused import `base:intrinsics` at karl2d.odin:6.
- unused-variable `READ_SIZE` at karl2d.odin:6993.
- unused-declaration `Shader_Compile_Result` at render_backend_gl.odin:704.
- integer-division-float at platform_mac.odin:472.
- no-op-arithmetic `4 + 4 + 0 + 4` at png_encoder.odin:55. Technically true; the `+ 0` is deliberate documentation.
- bool-return at karl2d.odin:832, redundant-else at 3428/3498, or-continue at 7209, use_stdlib contains at 7434, nested-if at wayland:1243, bool-compare at platform_linux.odin:202.
- ignored-result on `dynlib.unload_library` and `os.close`.
- naming on C-binding procs (`DestroyContext`, `mSampleRate`). True by the rule, but noise for bindings.
False positives: argument-count (K2), allocator-mismatch (K3), ignored-result on `mutex_guard` (K4), empty-body `for step() {}` (K5), use_stdlib fill (K13).
Borderline: the naming rule reports "type names are Ada_Case: set_window_position" for bodyless proc declarations in the `#+build ignore` doc file. A bodyless `proc(...)` is a proc type, so the rule is literally correct. Suggestion: skip lints in `#+build ignore` files.

### Formatter (karl2d)
- `odinfmt -path:. -w` on a copy (scratch-D/fmt-karl2d): 102 files in 0.11 s, 98 files changed. Every baseline-passing package still passes `odin check` (plus `-target:js_wasm32` for the root). A second run changes nothing, so the formatter is idempotent. No finding.

### LSP (karl2d)

#### L1. slow/hang (most severe): `textDocument/inlayHint` never returns for `x := make([]T, param)`
- Found by the stdio driver (/tmp/rols-corpus/scratch-D/lsp_drive.py). With default config, inlayHint timed out (60 s) on karl2d.odin, png_encoder.odin, font_cache/font_cache.odin, render_backend_*.odin, platform_*.odin and others. The request range does not matter: lines 0-1 hang too. The server keeps spinning CPU after the client gives up, and since handlers run serially on the main thread, every later request blocks. In an editor that requests inlay hints, the server is effectively dead for these files.
- Reduced by delta debugging, then minimized by hand (confirmed; no answer after 120 s), /tmp/rols-corpus/scratch-D/r14/a.odin:
  ```odin
  package r14

  f :: proc(m: int) {
  	x := make([]int, m)
  	_ = x
  }
  ```
  Repro: `cd /tmp/rols-corpus/scratch-D && python3 one2.py $PWD/r14 $PWD/r14/a.odin textDocument/inlayHint 1` (one2.py opens the file and sends one inlayHint request).
- These variants answer at once: length is a literal (`make([]int, 3)`), a local (`n := 3` or `n: int`), an expression (`m + 0`, `2 * m`), `make([dynamic]int, m)`, `make(map[int]int)`, `len(make([]int, m))`, or an explicitly typed `x: []int = make([]int, m)`. So the trigger is the inferred-variable-type hint for `make([]T, <procedure parameter>)`.
- `"enable_inlay_hints_variable_types": false` makes it answer. The other inlay flags do not.

## Odin core/vendor (read-only)

Queries were run with `--root $(odin root)` so that refs and callers see all of core. A root in an empty scratch dir gives no callers and refs for core symbols, which is expected.

#### C1. wrong-result: `impl` on a member of a proc group returns the member itself, not the group
- Repro: `ols query impl $(odin root)/core/strings/builder.odin:73:1 --root $(odin root)` (`builder_make_len_cap`, a member of `builder_make :: proc{...}`) prints only `builder_make_len_cap`. The README says impl lists "members of a proc group, or the groups a proc belongs to". `impl` on the group (builder.odin:102:1) correctly lists the 3 members.
- Reduced (confirmed), /tmp/rols-corpus/scratch-D/r15/a.odin:
  ```odin
  a :: proc(x: int) {}
  b :: proc(x: f32) {}
  g :: proc{a, b}
  ```
  `ols query impl a.odin:3:1` prints `a :: proc(x: int) {}`. Expected `g`. For a proc in no group (`math.lerp`) it also echoes the proc itself instead of returning nothing.

Correct results (checked against source): refs of `strings.write_byte` (425 results in 56 files, 1.8 s; text search finds 431, and all 6 extra are in comments or doc examples), callers of `write_byte` (176), refs, def and hover of the enum member `json.Marshal_Data_Error.Unsupported_Type` (17 refs), hover on `fmt.wprintf` with docs, hover on the group `linalg.normalize0`, `impl` on group `builder_make`, def through an alias (`reflect.type_info_base`), callees of `json.marshal`.

#### C2. wrong-result: hover shows the wrong offset for a field promoted through `using`
- Reduced (confirmed), /tmp/rols-corpus/scratch-D/r16/a.odin:
  ```odin
  Base :: struct { magic: int }
  Derived :: struct { using base: Base, extra: int }
  use :: proc(d: ^Derived) -> int { d.magic = 1; ... }
  ```
  `ols query hover a.odin:13:4` (`d.magic`) shows `Derived.magic: int`, `offset: 16, size: 8`. The compiler gives `offset_of(Derived, magic) == 0` (and `size_of(Derived) == 16`). Hover on `d.base.magic` correctly shows offset 0, and `d.extra` correctly shows 8.
- Expected: offset of the `using` field plus the member's offset (0 here).
- def, refs and rename of the promoted field are correct (4 edits, including `d.base.magic`).

#### C3. wrong-result: `symbols` and `find` drop declarations inside a `when` with a non-OS condition (related to K7)
- Core sweep: `ols query symbols FILE --root $(odin root)` on all 1568 core/vendor .odin files. There were no crashes or panics. 230 files exit 1 with no output: 148 are `#+build`-excluded on darwin (K1), 37 have no declarations (doc.odin and similar), and the rest have all their declarations inside a `when`: core/crypto/_edwards25519/edwards25519_table.odin (`when crypto.COMPACT_IMPLS == false {`), _weierstrass/secp256r1_table.odin and secp384r1_table.odin, debug/trace/trace_instrumentation.odin (`when INSTRUMENTATION_MODE {`).
- Reduced (confirmed), /tmp/rols-corpus/scratch-D/r18/a.odin:
  ```odin
  FLAG :: false
  when FLAG == false { a :: proc() {} }
  when ODIN_OS == .Darwin { b :: proc() {} }
  ```
  `symbols a.odin` lists only `3:1 Variable FLAG` and `10:2 Function b`. `a` is missing even though its branch is the active one. `find a` and `def a.odin:6:2` (on the declaration itself) return nothing.
- Also, `symbols` reports `FLAG :: false` as "Variable", while `find FLAG` reports "Constant".

#### C4. false-lint: `argument-count` across platform-split private helpers in core (same root as K1/K2)
- 145 `argument-count` errors in core/vendor. Example: `core/net/socket_linux.odin:152:14: error: '_create_socket_error' takes 0 arguments, got 1`. socket_linux.odin calls the linux version from errors_linux.odin (`proc(errno: linux.Errno)`), but the lint resolves the darwin build's errors_posix.odin version (`proc()`). Other examples include core/nbio/impl_linux.odin:832.

#### C5. false-lint: `printf-arity` ignores the explicit argument index `[n]` after `*`
- `core/testing/runner.odin:440:44: format needs 3 arguments, call has 2` (`fmt.aprintf("%- *[1]s", unpadded, width)`), and 965:32.
- Reduced (confirmed), /tmp/rols-corpus/scratch-D/r17 (since overwritten): `s := fmt.aprintf("%- *[1]s|", "ab", 6)` prints `ab    |` with no `%!(MISSING)`, but lint says "format needs 3 arguments, call has 2".

#### C6. false-lint: `lock-by-value` on an enum declared in core:sync
- `core/sync/primitives_atomic.odin:23:53` and `24:3`: "'curr_state' is copied; locks must be passed by pointer". `curr_state: Atomic_Mutex_State` is `enum Futex { Unlocked, Locked, Waiting }`, a plain value, not a lock.
- NOT reduced: the same enum declared in a scratch package (with a local or `sync.Futex` backing type) does not fire. It seems any type declared in package `sync` is taken for a lock. Repro: `ols query lint $(odin root)/core/sync/primitives_atomic.odin --root $(odin root)`.

#### C7. slow: `symbols FILE` cost grows with the package, not the file
- `symbols core/rexcode/isa/ppc/mnemonics.odin` (55 KB, 1 symbol) takes 2.69 s. `ppc/mnemonic_builders.odin` (2 MB, 13308 symbols) takes 8.6 s. x86/mnemonic_builders.odin takes 7.2 s, and arm64 takes 2.8 s. A per-file outline seems to index the whole package first. `lint core/rexcode/isa/ppc` (recursive) takes 11.5 s. All other lint dirs finish under 4 s, and all other symbols files under 1.7 s.

Core lint samples judged (42,880 hits: naming 39,645, ignored-result 955, unused-parameter 549, no-op-arithmetic 352, ...):
- True positives (these look like real bugs in Odin core/vendor):
  - printf-type at core/flags/internal_validation.odin:121: `"%T.%s has `%s` set to %i"` is passed `model_type, field.name, value, SUBTAG_MANIFOLD`, so the last two args are swapped.
  - infinite-recursion at vendor/wasm/WebGL/webgl.odin:402/405: `CompressedTexImage2DSlice` calls itself instead of `CompressedTexImage2D`. It is polymorphic, so the body is never type-checked.
- True or acceptable: redundant-else at ease_inverse.odin:201, dead-store at bytes.odin:1411, unused-declaration `DIGITS_LOWER` at strings/builder.odin:589, bool-return at unicode/letter.odin:398, double-negation at math.odin:1427 (`!(x == x)` to `x != x` is NaN-safe), ignored-result `io.write_rune` at strings.odin:3064, nested-if at ppc/decoder.odin:106, unsigned-negative-compare at zlib.odin:591, deprecated `ColorIsEqual` at raylib.odin:1481.
  - allocator-mismatch at core/encoding/base32/base32.odin:195: the slice is made with `allocator` but `delete(out)` uses the context allocator, so this is a real core bug.
- False positives: C4, C5, C6, and allocator-mismatch at core/debug/trace/trace_linux.odin:82, which is `defer delete(command)` on a `[dynamic]string` (K3).
- Driver runs over all 102 karl2d files (/tmp/rols-corpus/scratch-D/k_lsp1.jsonl, k_lsp2.jsonl). Each file got didOpen, documentSymbol, semanticTokens/full, inlayHint over the whole file, codeAction at 3 positions, formatting, hover at 3 positions, and didClose.
  - Pass 1 (defaults plus `enable_semantic_tokens`, 10 s timeout): inlayHint timed out on 19 files (L1). One codeAction also timed out (L2).
  - Pass 2 (`enable_inlay_hints_variable_types: false`, param/default/implicit-return/constant hints on, 30 s timeout): 101/102 files clean. No crashes, no error responses, and no request over 2 s. The slowest were documentSymbol 0.20 s, codeAction 0.22 s, formatting 0.015 s and semanticTokens 0.006 s (all karl2d.odin, 220 KB). The one failure is L2.

#### L2. slow/hang: code actions never return inside a test proc in tests/coordinate_system/render_texture_flip_test.odin
- Repro: `cd /tmp/rols-corpus/karl2d && timeout 30 ols query actions tests/coordinate_system/render_texture_flip_test.odin:75:3` exits 124 (and the same over LSP). It still hangs at 75:12 and 76:3. Lines 64:2, 67:2, 68:4 and 71:6 answer.
- Reduced by delta debugging, then by hand (confirmed; CLI and LSP codeAction both hang), /tmp/rols-corpus/scratch-D/r19/a.odin:
  ```odin
  package r19

  f :: proc(got: int, d := 0) {
  	_ = got
  }

  g :: proc() {
  	f(1)
  }
  ```
  `ols query actions a.odin:8:2` never returns (killed after 8 s; the karl2d case was killed after 30 s). Every procedure that has a parameter with a default value (`d := 0`, `loc := #caller_location`) hangs code actions on its call sites, even when all arguments are passed (`f(1, 2)`). The same callee without the default parameter offers "Inline procedure call" at once. So the "Inline procedure call" action probably loops on parameters with default values. Like L1, this blocks the server's single handler thread.

### Formatter (core copies)
- Copied core:strings, fmt, encoding/json, math/linalg (plus glsl/hlsl), bytes, strconv (plus decimal), text/regex (plus 6 subpackages) and container/small_array to scratch-D/fmt-core: 17 package dirs, 59 files. All passed `odin check -no-entry-point` before. `odinfmt -path:. -w` took 0.11 s, and all 17 still pass afterwards. No finding.

### LSP (core/vendor)
- Pass B: 220 files, the 20 largest (up to 2 MB / 13k lines) plus 200 random, with `enable_inlay_hints_variable_types: false`, semantic tokens and param hints on, 30 s timeout (/tmp/rols-corpus/scratch-D/c_lspB.jsonl). 216 files clean. No crashes and no error responses. 4 timeouts and 8 slow requests, below.
- Pass A: 40 of the random files with the default config plus semantic tokens, 10 s timeout (c_lspA.jsonl). inlayHint hangs on 3 of 40 (vendor/fontstash/fontstash.odin, core/mem/virtual/virtual.odin, core/encoding/base32/base32.odin), which is L1 again. Everything else is fast (max documentSymbol 0.8 s).

#### L3. slow/hang: code actions on calls of core procs with default parameters (L2 in core)
- codeAction timed out (30 s) at core/image/jpeg/jpeg_os.odin:15:11 and core/image/tga/tga_os.odin:16:11, both `return load_from_bytes(data, options)`. `load_from_bytes` has `options := Options{}, allocator := context.allocator`. This is the same trigger as the r19 repro.

#### L4. slow: odinfmt (and LSP formatting) is quadratic in the number of elements of one composite literal
- LSP formatting of core/rexcode/isa/ppc/tablegen/generated/decode_tables.odin (950 KB) takes 11.1 s, and `odinfmt -path:` on a copy takes 13.4 s. The 2 MB ppc/mnemonic_builders.odin takes 2.5 s. Per declaration: `DECODE_BUCKET_LIST := [34967]u16{...}` takes 4.7 s and `DECODE_INDEX_SUB := [16384]lib.Decode_Index{...}` takes 8.8 s.
- Reduced (confirmed), generated by a script into /tmp/rols-corpus/scratch-D/oneN.odin and numsN.odin: `X := [N]u16{ 0, 1, 2, ... }` with N elements. With one element per line, N=16000 takes 0.93 s and N=32000 takes 3.79 s. With 64 per line, 8000 takes 0.24 s, 16000 takes 0.95 s and 32000 takes 3.87 s. Doubling N quadruples the time. Struct-element literals with 4000 entries take 0.07 s, so element count and not file size drives it.

#### L5. slow: documentSymbol and codeAction on very large files
- core/rexcode/isa/ppc/mnemonic_builders.odin (2 MB, 13,336 lines): documentSymbol 20.0 s, and each codeAction 8.0-8.5 s, even at positions with no action. x86/mnemonic_builders.odin (10,342 lines): documentSymbol 13.8 s, and a codeAction at 2614:2 timed out over LSP (30 s). `ols query actions ...x86/mnemonic_builders.odin:2614:2 --root $(odin root)` completes in 12.9 s, so this is slow rather than hung. arm64/mnemonic_builders.odin: documentSymbol 4.6 s. The CLI `symbols` on the same files takes 8.6 s, 7.2 s and 2.8 s (C7). semanticTokens (0.075 s), inlayHint (0.076 s) and hover (0.008 s) on these files are fast, so the cost is specific to the symbol and code-action paths.

#### L6. slow/hang: inlayHint on core/rexcode/ir/spirv/builders_gen.odin never returns, even with variable-type hints off (range-type hints)
- Repro: open `$(odin root)/core/rexcode/ir/spirv/builders_gen.odin` (500 KB, 11,552 lines) with root `$(odin root)` and `{"enable_inlay_hints_variable_types": false}`, then request inlayHint for any range. There is no answer after 300 s. Command: `cd /tmp/rols-corpus/scratch-D && LSP_INIT='{"enable_inlay_hints_variable_types": false}' python3 one2.py $(odin root) $(odin root)/core/rexcode/ir/spirv/builders_gen.odin textDocument/inlayHint 1`. With `"enable_inlay_hints_range_types": false` added, it answers in 1.6 s. Disabling comp_lit_fields or optional_result does not help.
- NOT fully reduced. The package copy is in /tmp/rols-corpus/scratch-D/r21. Splitting the file into its 1,700 top-level declarations: the first 1,570 declarations answer in 1.3 s (42 hints). Adding declaration 1,571 (`inst_OpLoopControlINTEL`, containing `for x in op1 { buf[n] = op_int(x); n += 1 }` with `op1: []i64`) hangs. That declaration alone, or with only the 43 other `for`-containing declarations, answers at once. Declarations [428, 1570) plus 1,571 hang; [429, 1570) plus 1,571 do not. So the trigger depends on how much precedes the range loop, not on one construct. It is not a byte or line offset either: 460 KB of comments or 10,400 blank lines before a range loop are fine.
- A synthetic file with N two-statement procs and one range loop does not hang, but inlayHint time grows superlinearly: N=1000 takes 0.20 s, 2000 takes 0.69 s and 4000 takes 2.41 s.

## Passed cleanly
- No crash or panic in any CLI run: 56 karl2d package checks and lints, 102 karl2d `symbols`, 329 core/vendor lint dirs, 1568 core/vendor `symbols`, and every query, rename, move, reorder-params, rename-package, attr and action run. No LSP request returned an error response, and the server process never exited unexpectedly. The only failures were the hangs L1, L2, L3 and L6.
- `query check` and `query lint` are fast: at most 1.15 s on karl2d, and under 4 s per core dir except core/rexcode/isa/ppc (11.5 s, 6 MB).
- Cross-package def, hover and refs in karl2d (relative imports, the local `log` package shadowing core:log, font_cache, mac bindings, foreign/objc procs `ce.Event_deltaX` and `Audio.QueueNewOutput`) are correct. So are struct field refs (they keep `Init_Options.depth_range_min` and `State.depth_range_min` apart), enum member def and refs (they keep `Shader_Default_Inputs.Unknown` and `Pixel_Format.Unknown` apart), callers of `draw_text` across 30+ example packages (apart from K8), and callees.
- Renames, move, reorder-params, rename-package and attr add: all applied cleanly and compile (see "Edits that passed").
- The `--apply` compile gate caught every broken edit tried (slice.fill, Add ok result, Generate test, Move to linux file, Unwrap block). Rollbacks restored files byte for byte (`git status` clean afterwards).
- The formatter keeps karl2d and 17 core package dirs compiling and is idempotent.
- semanticTokens/full, hover and formatting are fast on every file except the quadratic formatter case L4.

## Could not verify (please run during triage)
- `cd /tmp/rols-corpus/karl2d && ols query modernize --apply`. The permission classifier denied it in this session, and I did not retry. Expected: exit 4, rolled back because of K13.
- Compile correctness of modernize and refactor edits in files excluded on darwin: platform_windows*.odin, platform_linux*.odin, platform_web.odin, render_backend_d3d11.odin and render_backend_webgl.odin. `odin check -target:linux_amd64|windows_amd64` stops at the vendor stb `#panic` because the stb libs are not built for those targets. In particular, check the `or_return` rewrites in platform_windows_glue_gl.odin:141/154 on `win32.BOOL`-returning calls, and the nested-if, or_return and redundant-parens rewrites in the wayland/x11/linux files.
- L6 is not reduced to a small snippet.
- C6 (lock-by-value) is not reduced outside core:sync.

## Counts by class
- crash: 0
- slow/hang: 7 entries. Three distinct hangs: L1 (inlayHint with `make([]T, param)`), L2/L3 (code actions on calls of procs with a default parameter), and L6 (spirv range hints). Three slow cases: L4 (quadratic formatter), L5 (documentSymbol and codeAction on 2 MB files), and C7 (`symbols` indexes the whole package).
- wrong-result: 8 (K1, K6, K7, K8, K20, C1, C2, C3)
- false-lint: 7 (K2, K3, K4, K5, C4, C5, C6). C4 shares its root cause with K1/K2.
- wrong-edit: 4 (K13, K15, K16, K17)
- improvement: 7 (K9, K10, K11, K12, K14, K18, K19)
