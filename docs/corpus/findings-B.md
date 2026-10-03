# Findings B (tina, odin-godot)

Status: complete. All reduced repros live in /tmp/rols-corpus/scratch-B/rN; drivers are scratch-B/lsp_driver.py, lsp_one.py, actions.py, q.sh.

## Environment and limits
- ols: /tmp/rols-corpus/bin/ols, OLS_BUILTIN_FOLDER=/tmp/rols-corpus/bin/builtin, odin dev-2026-09:a2fb372b7, macOS (darwin arm64).
- The Claude Code permission system denied `ols query modernize --apply` on the tina clone ("Irreversible Local Destruction"). I did not retry --apply in any form. All edit checks below are dry-run diffs; where a diff looked wrong I reduced it to a scratch snippet, wrote the post-edit text by hand and ran `odin check` on that.

## tina
- Commit a2e8d4dc53394dd6772d08e79a41d6b56ba3a65e. No ols.json existed; I wrote `{"collections":[{"name":"tina","path":"."}]}` (imports are relative, the collection is unused).
- Baseline `odin check <dir> -no-entry-point`: src, src/extensions/http/datastar, src/extensions/http/server, .../server/compliance_check, tests, tools/asan_death_tests, scripts all pass (each under 1 s). All six examples/*.odin pass with `-file`.
- `ols query check`/`lint` per package: all exit 0, 0.1-1.1 s. `check` also reports 36 `-vet-tabs` errors in src/spsc_ring.odin (spaces); that is the documented default `enable_checker_vet_tabs`, not a bug.

### Findings so far (tina)

F1 false-lint (error level): unknown-field uses the else-branch of a `when` type declaration.
- Repro: `ols query check src` -> `src/simulated_test_determinism.odin:182:6: error: 'FaultConfig' has no field 'isolate_crash_rate' [unknown-field]`. FaultConfig has the field in the `when TINA_SIMULATION_MODE` branch; the use is itself inside `when TINA_SIMULATION_MODE`. odin check passes with and without -define:TINA_SIM=true.
- Reduced (confirmed, scratch-B/r1):
```odin
package r1
FLAG :: #config(FLAG, false)
when FLAG { Cfg :: struct { rate: int } } else { Cfg :: struct {} }
when FLAG { use :: proc() -> Cfg { return Cfg{rate = 1} } }
```
  -> `error: 'Cfg' has no field 'rate' [unknown-field]`. Expected: no error (the use sits in the same `when FLAG` branch; at minimum an error-severity lint should not fire on a type with several `when` declarations).

F2 false-lint (error level) + wrong-result: argument-count and def resolve a build-tag-excluded file's call to the other platform's declaration.
- Repro: `ols query check src` -> `src/sys_thread_linux.odin:88:2: error: 'pthread_setname_np' takes 1 argument, got 2 [argument-count]`; the linux file declares its own 2-arg version, the 1-arg one is in sys_thread_posix.odin (#+build darwin...).
- Reduced (confirmed, scratch-B/r2): a.odin `#+build darwin` with `setname :: proc(name: cstring) {}`; b_linux.odin `#+build linux` with `setname :: proc(id: u64, name: cstring) {}` and `f :: proc() { setname(0, "x") }`. `ols query check .` -> argument-count error; `ols query def b_linux.odin:7:3` -> a.odin:4. Expected: the same-file (same-target) declaration.

F3 false-lint: dead-store on a package global.
- Repro: `ols query lint src` -> `src/turn_frame_helper_for_test.odin:104:2: warning: value stored in 'g_current_shard_pointer' is never read [dead-store]`. The global is read by the callback called before it is reassigned.
- Reduced (confirmed, scratch-B/r3):
```odin
package r3
g: int
read_g :: proc() -> int { return g }
f :: proc() -> int { prev := g; g = 1; x := read_g(); g = prev; return x }
```
  (one statement per line in the real file) -> dead-store on `g = 1`. Expected: no dead-store for globals (or anything not a local).

F4 false-lint: unsigned-negative-compare on a u64 literal above i64 max.
- Repro: `src/extensions/http/server/parser.odin:930:31: warning: an unsigned u64 is never negative, so this is always false`.
- Reduced (confirmed, scratch-B/r4): `f :: proc(x: u64) -> bool { return x == 9_999_999_999_999_999_999 }` -> same warning. The literal fits u64; the lint apparently parses it as a wrapped negative i64.

F5 false-lint: naming classifies `X :: true` as a type, and rejects a leading underscore on types only.
- Repro: `src/io_backend_bsd.odin:81:3: information: type names are Ada_Case: _HAS_SO_NOSIGPIPE [naming]` (a bool constant), and `_Platform_State` (4 hits).
- Reduced (confirmed, scratch-B/r5): `is_enabled :: true` -> "type names are Ada_Case: is_enabled"; `_Private_Type :: struct {}` -> flagged, while `_private_proc :: proc() {}` and `_PRIVATE_CONST :: 1` are accepted. Cause: rols_lint_naming.odin decl_kind returns .Type for an Ident resolving to the builtin `true`/`false`; Ada check does not strip a leading `_` like the others do.

F6 improvement: ignored-result prints the absolute package path of a type from a package the file does not import.
- Reduced (confirmed, scratch-B/r6): `import kq "core:sys/kqueue"` then `kq.kevent(k, changes[:], nil, nil)` -> `(/opt/homebrew/Cellar/odin/2026-09/libexec/core/sys/posix.Errno)`. Expected `posix.Errno`. Also `os.remove("x")` prints `(Error)` without the `os.` qualifier.

F7 wrong-result: `_bsd.odin` files are skipped on darwin, so their declarations and tests are invisible.
- Repro: `ols query def src/io_backend.odin:204:2` (`_backend_wake`) -> exit 1, no result; `ols query tests src/io_backend_bsd.odin` -> exit 1 (3 tests exist). odin compiles `*_bsd.odin` on darwin.
- Reduced (confirmed, scratch-B/r13): a_bsd.odin `from_bsd :: proc() {}`, main.odin `use :: proc() { from_bsd() }`; odin check passes; def/hover on the call -> exit 1.
- Cause: src/server/build.odin skip_file: `name_between == "bsd"` returns `!is_bsd_variant(...)`, and is_bsd_variant only accepts FreeBSD/OpenBSD/NetBSD, so darwin skips the file although odin builds it.

F8 wrong-result: `symbols`, `find` and hover-on-declaration return nothing for build-tag-excluded files and false `when` branches.
- Repro: `ols query symbols` exits 1 with empty output on 39 tina files (all *_linux/_windows, all simulated_test*.odin wrapped in `when TINA_SIMULATION_MODE`, wall_clock_*.odin).
- Reduced (confirmed, scratch-B/r7): `#+build linux` file with `linux_only :: proc() {}` -> `symbols` exit 1, `hover a_linux.odin:4:2` exit 1, `find linux_only` exit 1. A `when FLAG {in_when :: proc(){}}` (FLAG false) is missing from `symbols` of its file. Same file: `FLAG :: #config(FLAG,false)` is listed as `Variable` (it is a constant). Expected: an outline of the open file regardless of target.

F9 wrong-result: hover/type resolution fails for a call to an overload group whose members take a `$tag: Distinct` poly constant, when passed a typed constant.
- Repro: `ols query hover examples/example_task_dispatcher.odin:78:11` (tina.ctx_send) -> exit 1; `hover ...:245:5` (`res := tina.ctx_send(...)`) -> exit 1; `def ...:248:16` (`.stale_handle`) -> exit 1. Also breaks enum-member rename (see F11).
- Reduced (confirmed, scratch-B/r11):
```odin
package r11
Tag :: distinct u16
T1 :: Tag(0x40)
a :: proc($tag: Tag, p: []u8) -> int { return 0 }
b :: proc($tag: Tag, p: ^int) -> int { return 0 }
ab :: proc { a, b }
g :: proc() { r1 := ab(T1, nil) }
```
  hover on r1 -> exit 1. With `tag: Tag` (not poly) it resolves to int. Calling `a(T1, nil)` directly works.

F10 wrong-result: hover on an overload-group call picks the first member, and names the wrong package.
- Reduced (confirmed, scratch-B/r9): lib has `send :: proc{send_raw (x: int), send_typed (x: ^$T)}`; `lib.send(&v)` hover shows `lib.send :: proc(x: int)` (should be send_typed). A local `send2 :: proc{lib.send_raw}` in package r9 hovers as `lib.send2`.

F11 wrong-edit: renaming a struct field misses uses promoted by `using`.
- Repro (tina, dry run): `ols query rename examples.WorkerIsolate.id worker_id` -> 4 edits; the bare `id` uses at example_task_dispatcher.odin:106, 120, 128 (under `using self := tina.self_as(...)`) are not renamed, so the program would not compile.
- Reduced (confirmed, scratch-B/r8): `#+feature using-stmt`, `W :: struct { id: u32 }`, `f :: proc(using w: ^W) -> u32 { return id }`; `rename a.odin:5:2 ident --apply` -> exit 4, "Undeclared name: id" (this was the one --apply I ran, in my own scratch snippet, before the denial). `refs` on the field also omits the `using` uses; `def` on `id` under `using self := as_w(W, p)` (poly proc returning ^T) jumps to `^T` in as_w's signature.

F12 wrong-edit: modernize `use-stdlib/fill-*` rewrites loops over fixed arrays to `slice.fill(arr, v)`, which does not compile.
- Repro: `ols query modernize --diff` on tina proposes `slice.fill(extension, 'a')` ([4097]u8, body.odin:841), `slice.fill(slots, ROUTE_INDEX_NONE)` (router.odin:263) and `slice.fill(set, 0)` (linux.Sig_Set, sys_signals_linux.odin:24, a linux-only file the compile gate cannot see).
- Reduced (confirmed, scratch-B/r14): `buf: [8]u8; for i in 0 ..< len(buf) { buf[i] = 'a' }` and `slots: [4]int; for &s in slots do s = -1` -> `slice.fill(buf, 'a')`, `slice.fill(slots, -1)`. odin: "Cannot determine polymorphic type from parameter: '[8]u8' to '$T/[]$E'. Suggestion: Try slicing the value with 'buf[:]'". Expected `buf[:]`.

F13 improvement: modernize nested-if merge leaves a tab+space indent when the inner if is a one-line `{ stmt }`.
- Reduced (confirmed, scratch-B/r14): `if a {\n\tif b { return 1 }\n}` -> `if a && b {\n\t\t return 1` (tab, tab, space). Seen in tina scripts/check_test_hygiene.odin:1112.

F14 wrong-edit (default modernize rule): `use-stdlib/fill-indexed` fires when the stored value uses the loop index.
- Reduced (confirmed, scratch-B/r17/b.odin): `idx :: proc(s: []int) { for i in 0 ..< len(s) { s[i] = i } }` -> lint "Use slice.fill" and `modernize --diff` rewrites to `slice.fill(s, i)`. `i` is then undeclared (compile error), or, if an outer `i` is in scope, the code compiles and silently fills a constant. Expected: no fix when the value mentions the index variable.

F15 wrong-edit: code action "Unwrap block" is offered on a `for` statement and deletes the loop header.
- Repro: `actions src/extensions/http/server/body.odin:841:2` and `parser.odin:1218:2` offer "Unwrap block"; result fails odin check ("Undeclared name: i" / "index").
- Reduced (confirmed, scratch-B/r17/a.odin): `for i in 0 ..< len(buf) { buf[i] = i }` at the `for` -> "Unwrap block" yields `buf[i] = i`.

F16 wrong-edit: code action "Add ok result" changes the signature without updating any caller.
- Repro: `actions src/api.odin:218:1` (self_as) offers it; 14 callers `self := tina.self_as(...)` stay single-value.
- Reduced (confirmed, scratch-B/r17/a.odin): `get :: proc(x: int) -> int {...}`, `v := get(1)` in the same file -> after the action, "Assignment count mismatch '1' = '2'". Expected: update callers (`v, _ := get(1)`) or refuse when callers exist.

F17 improvement: duplicate code action titles. `actions src/api.odin:302:2` returns "Use compound assignment" twice (kinds refactor.rewrite and quickfix, same edit), so `--apply TITLE` is ambiguous. "Add doc comment" inserts `// get ` with a trailing space.

F18 wrong-result: `move --to` resolves a relative path against the declaration's directory, not the cwd, and refuses an absolute path through a symlink.
- Reduced (confirmed, scratch-B/r16, pkg/a.odin with `f :: proc() {}`): from r16, `move pkg/a.odin:3:1 --to pkg/b.odin` -> "error: the target must be in the directory of the declaration"; `--to b.odin` from r16 creates pkg/b.odin. `--to /tmp/.../pkg/b.odin` is refused, `--to /private/tmp/.../pkg/b.odin` works (macOS /tmp is a symlink). Every other path argument is cwd-relative per README.

Note to F9: because of F9, `rename src.Send_Result.stale_handle dead_handle` (12 edits) misses `.stale_handle` at examples/example_task_dispatcher.odin:248 and example_http_sse.odin:102 (the compared value comes from `tina.ctx_send(...)`).

### Edits that passed (tina, dry run)
- rename src.self_as -> self_cast: 15 edits in 4 files, all 14 call sites, string literal untouched.
- rename local hash_value -> h: 11 edits correct; -> key refused with the conflicting `key` param position.
- reorder-params query_value_decoded --order 1,0: decl and 2 callers in 2 packages updated.
- rename-package src/extensions/http/datastar dstar: package clause, 2 importers (aliased and @(require)), directory rename; warning about the comment mentioning `datastar`.
- attr add src.mix_bits_to_32 require_results (new line after the doc comment); attr add cold onto an existing group; attr rename across server package (13 edits).
- move mix_bits_to_32 with a bare file name: correct 2-file diff. reorder-params on ipv6 refused (default values), documented.
- Code actions verified by applying the JSON edit to a scratch copy of tina and running odin check: Use compound assignment, Use or_break, Remove #partial, Merge nested if (x2), Invert if, Convert to do, Convert to C-style for, Add loop label, Use range loop, Move to new file / Move to <file>, Add doc comment, Flip comparison, Discard result: all compile.
- modernize --diff (26 files): nested-if merges keep && / || precedence with parentheses; or_return/or_break/redundant-else/redundant-partial/contains-substring rewrites are correct; the only bad rewrites are F12/F13.

### Lint hits judged (tina), true positives
compound-assign api.odin:302; dead-store simulation_clock.odin:58 (initial value overwritten before read); no-op-arithmetic path_canonicalizer.odin:66 (`+ 0`, intentional alignment but true); or-break shard.odin:1306; or-return io_backend_bsd.odin:1271, io_backend_linux.odin:426; redundant-else shard.odin:1753; redundant-partial connection.odin:523 (all 3 Match_Outcome cases listed); range-loop parser.odin:1218; use_stdlib contains dispatch.odin:491; unused-variable api_context.odin:806 and sys_memory_windows.odin:41 (odin -vet agrees); unused-declaration io_backend.odin:149 (no callers); error-not-last router.odin:135; naming api.odin:78 enum member `ok`. Unused-parameter (180 hits): sampled 7, all literally unused, but most are handlers passed as values to a proc-typed field (e.g. supervisor_handler -> handler_fn) or per-platform `_backend_*` implementations whose signature is fixed (improvement: skip procs used as values). False: F1, F2, F3, F4, F5, use_stdlib fill on fixed arrays (F12).
- Missed by lint but reported by `odin check -vet-unused-variables`: timer.odin:720 `message_count` (inside a when-block test).

### Queries verified correct (tina)
hover on locals from poly calls (`self := tina.self_as(WorkerIsolate, ...)` -> ^WorkerIsolate, payload_as, payload_view_as, payload_copy_as, make_spawn_args second result u8); def of self_as across packages; def of struct field `msg.job_id`; def through `using body` raw_union field (`message.user`); hover of nested anonymous-struct field `payload`; refs of self_as (14 = grep); callers of payload_as (6 procs); find self_as / spawn_spec / ctxsend fuzzy; tests src/extensions/http/server (267 = grep). find lists `Isolate_Handle :: distinct u64` as "Constant" (kind wrong, minor). impl on a union / proc type returns nothing (exit 1).

### LSP over stdio (tina), first pass
F19 crash (SIGSEGV after a long hang): textDocument/inlayHint on a variable initialized from a call that does not resolve.
- Minimal repro (confirmed, scratch-B/r24; `python3 scratch-B/lsp_one.py r24 r24/a.odin inlayHint`):
```odin
package r24
f :: proc() {
	x := undefined_proc(1)
}
```
  The request never answers; the server spins at full CPU and dies with signal 11 after 78 s (looks like unbounded recursion). Every request queued behind it times out. `x := undefined_proc` (no call) answers at once.
- Impact on tina: inlayHint times out on 32 of 121 files (list in scratch-B/inlay_tina.txt). Two triggers seen: calls into `_bsd.odin` files, which F7 hides on darwin (watchdog.odin `event := os_poll_watchdog_events(100)`), and `buffer := make([]u8, 256, alloc())` with an allocator call (scratch-B/r23, also hangs although `alloc` resolves; CLI hover on `buffer` returns nothing). Typing an unknown call name in any editor with inlay hints on (Zed, Helix) would hang and then crash the server.
- In the full-project driver run (scratch-B/lsp_driver.py), the first hang was example_http_datastar.odin; all later requests timed out and the server exited while handling example_http_server.odin.

F20 crash-class (memory): inlay type hint for `a := make([]u8, 4)` has a label of NUL bytes.
- Reduced (confirmed, scratch-B/r22): `f :: proc() -> int { a := make([]u8, 4); return len(a) }` -> inlayHint label `": \u0000\u0000...` (42 chars). With `make([]u8, 4, context.allocator)` the label is NULs followed by ".a". `b := 1` gives ": int" correctly. Looks like the label points into freed temp memory.
- Second minimal trigger (confirmed, scratch-B/r24), a common idiom that compiles:
```odin
package r24
f :: proc(p: rawptr) {
	x := (^int)(p)
	_ = x
}
```
  inlayHint times out (same hang). In odin-godot it hangs gdext/context.odin (`set := (^mem.Allocator_Mode_Set)(old_memory)`, found by delta-debugging) and libgd/classdb/bind.gen.odin.

### LSP over stdio (tina), second pass (inlay hints skipped)
- With inlayHint skipped (SKIP_INLAY=1, scratch-B/lsp_tina.txt): all 121 files answered documentSymbol, semanticTokens/full (enabled via initializationOptions; token ranges validated), codeAction x3, formatting, hover x3. No errors, no crash, slowest request 0.11 s (documentSymbol, connection.odin).
- Per-file inlayHint (scratch-B/inlay_tina.txt): 32 of 121 files time out (F19); the rest answer in under 1 s.

## odin-godot
- Commit 93395901a76f62a9f2adff76c2eb38a185d91513.
- The checked-in ols.json uses Windows paths (`C:\Odin\base|core|shared|vendor`) and `checker_args: "-vet -strict-style -no-entry-point -define:REAL_PRECISION=single"`. I ran it as-is first (F21, F22), then replaced it for the sweep with scratch-B/godot_ols.json (only the `godot` collection `.`, same checker_args) and restored the original at the end.
- The generated bindings (`godot/godot.gen.odin`, core/editor/variant) are absent from the checkout. Generating them needs the godot-cpp and temple submodules; I fetched both, but temple_cli and bindgen no longer compile with odin dev-2026-09 (os API changes), so generation was impossible. I deinitialized the submodules again. To cover "large generated files" I built a 1.8 MB, 54,686-line file by repeating libgd/classdb/bind.gen.odin 12 times with renamed procs (scratch-B/godot-copy, generator inline in this session).
- Baseline `odin check <dir> -no-entry-point -collection:godot=.`: pass: gdext, godin/test, bindgen/names. Fail before any edit (missing generated bindings or Odin API drift): godot (1 error), libgd (11), libgd/classdb (7), godin (43), bindgen (empty ../temple), bindgen/graph, bindgen/views, examples/game/src, examples/godin-syntax/src, examples/hello-gdextension/src (15), examples/tests/src (7). Edit checks used the passing packages only.
- `ols query check`/`lint` per package: exit 0, 0.1-0.2 s each. `symbols` on all 41 files: exit 0 under 0.2 s, except the two build-excluded files (F8).

F21 wrong-result (high impact): `checker_args` containing `-no-entry-point` silently drops every compiler diagnostic.
- Repro: odin-godot as checked in: `ols query check gdext` prints `[ERROR] ... Failed to unmarshal check results: Invalid_Data, Previous flag set: 'no-entry-point'`, then only lint hints, exit 0.
- Reduced (confirmed, scratch-B/r20): ols.json `{"checker_args": "-no-entry-point"}`, a.odin `f :: proc() { x: int = "s" }` -> no checker errors, exit 0. With `{}` both errors appear. check.odin:408 always adds `-no-entry-point` (or `-file`), so odin rejects the duplicate flag. Expected: drop a duplicate from checker_args, or report the failure as an error with a non-zero exit. The same flag combination is common in published ols.json files (this project's is one).

F22 improvement: a collection path that does not exist replaces the built-in `core`/`base` collections.
- Repro: the checked-in odin-godot ols.json on macOS: every `core:`/`base:` import is reported as `error: package 'core:c' not found [missing-import]`, and the log line reads `Failed to find absolute address of collection: /private/tmp/.../C:/Odin/base%!(EXTRA Not_Exist)` (format-string bug: the error is passed to log.errorf without a verb, requests.odin:746). Expected: ignore a missing `core`/`base`/`vendor` path and keep `odin root` (the comment above that code says this is always correct), and fix the format string. Upstream code (blame: DanielGavin/Brad Lewis), so also an upstream issue.

F23 false-lint: float-equality fires on a compile-time type comparison.
- Repro: godot/Variant.odin:890:17 `} else when T == Float {` -> "comparing floats with == is exact".
- Reduced (confirmed, scratch-B/r18): `Float :: f32`, `conv :: proc($T: typeid) -> int { when T == Float { return 1 } else { return 0 } }` -> float-equality at 14:7. T and Float are types.

F24 false-lint: dead-store ignores a bare `return` that returns a named result.
- Repro: godin/build_options.odin:17 and build_state.odin:72 `success = false` flagged; the proc later does bare `return` on error paths.
- Reduced (confirmed, scratch-B/r19):
```odin
package r19
parse :: proc(x: int) -> (ok: bool) {
	ok = false
	if x > 0 {
		return
	}
	ok = true
	return
}
```
  -> `warning: value stored in 'ok' is never read [dead-store]` at 4:2. Without the later `ok = true` there is no warning.

F25 wrong-result: hover on a variable assigned from a poly call whose `$T` argument is the enclosing proc's own poly parameter.
- Repro: `ols query hover libgd/classdb/bind.gen.odin:224:9` (`arg0 := godot.variant_to(cast(^godot.Variant)args[0], Arg0)`) -> exit 1.
- Reduced (confirmed, scratch-B/r21): `conv :: proc(p: rawptr, $T: typeid) -> T {...}`, `outer :: proc($A: typeid, p: rawptr) -> A { x := conv(p, A); return x }`; hover on `x` -> `r21.$x: typeid`. Expected `x: A`.
- Related: hover on a parameter of type `^godot.String_Name` (String_Name :: distinct Opaque(1)) prints `^godot.String_Name(1)`.

F26 crash (not reduced): codeAction on a 1.8 MB generated file in a package that also has bind.odin.
- Repro: scratch-B/big12 (ols.json with collection godot ".", godot/ and gdext/ from odin-godot, libgd/classdb/{bind.odin, bind.gen.odin, big.gen.odin}); `REQ_TIMEOUT=120 python3 scratch-B/lsp_one.py big12 big12/libgd/classdb/big.gen.odin codeAction 20 5` -> server killed by SIGSEGV after about 8 s (2 of 2 runs; 3 more SIGSEGV in godot-copy). Without bind.odin, or with a 4x or 8x file, the same request answers in 0.2-2.5 s. Some other attempts ended with SIGTERM within 0.1 s, which I attribute to another sweep agent killing ols processes, not to this bug.
- documentSymbol, semanticTokens/full, formatting and hover on the 1.8 MB file take 2.1-2.3 s each from a cold open (just over the 2 s threshold, class slow); CLI symbols/lint/check/hover/refs take 1.5-1.7 s.

### LSP over stdio (odin-godot)
- 41 files, inlay skipped: no errors, nothing slower than 0.08 s. Per-file inlayHint: gdext/context.odin and libgd/classdb/bind.gen.odin time out (F19, pointer-cast trigger).

### Edits (odin-godot, dry run)
- rename bindgen/names.godot_to_odin: 4 edits = grep count. rename gdext.CallError.expected: 4 edits (decl + 3 uses, matches grep). rename gdext.Variant_Type.Nil: 1 edit (no other uses; string literals untouched). rename gdext.PropertyInfo.hint_string: 2 edits (decl + bind.odin field init). Local `sb` -> builder: 9 edits = all occurrences. Rename of `assert` refused (builtin), documented.
- rename-package bindgen/names casing: 147 edits = 138 `names.` qualifiers + 7 imports + 2 package clauses, plus the directory rename, warning about a comment.
- move is_upper_or_number --to case_helpers.odin: correct, adds the `core:unicode` import. reorder-params godot_to_odin refused because it is used as a value in a proc group (documented). attr add require_results and attr rename private in gdext: correct.
- modernize --diff: 5 edits in 5 files; read and correct.
- Code actions applied in scratch-B/godot-copy: Add explicit type, Split case, Add doc comment, Generate test: compile. "Add ok result" on is_upper_or_number breaks its callers again (F16). "Unwrap block" offered on a C-style `for` (F15). Other failures are in packages that fail baseline.

### Formatter (both projects)
- odinfmt -w on every file of copies (scratch-B/fmt-tina, scratch-B/fmt-godot): no odinfmt failure, about 1 s each. tina: every package and example still passes, also with -target linux_amd64, windows_amd64, freebsd_amd64 and -define:TINA_SIM=true (0 errors before and after). odin-godot: gdext, godin/test, bindgen/names still pass; the failing packages keep their error counts except godin (43 -> 45), where import reordering changes which errors odin reports before its error limit; no new error kind. No formatter finding.

## Summary of findings by class
- crash: F19 (inlayHint hang then SIGSEGV on unresolved calls and on `(^T)(p)`), F20 (NUL-byte inlay label, memory), F26 (SIGSEGV on large file codeAction, unreduced).
- wrong-edit: F11 (field rename misses `using` uses), F12 (slice.fill on fixed arrays), F14 (slice.fill with index-dependent value), F15 (Unwrap block on for), F16 (Add ok result breaks callers).
- false-lint: F1 (unknown-field when-branch), F2 (argument-count other-platform decl), F3 (dead-store global), F4 (unsigned-negative u64 literal), F5 (naming bool constant / leading underscore), F23 (float-equality on types), F24 (dead-store bare return).
- wrong-result: F7 (`_bsd.odin` skipped on darwin), F8 (no symbols/hover in excluded files), F9 (overload with poly constant fails), F10 (overload hover picks first), F18 (move --to path), F21 (checker_args -no-entry-point drops all errors), F25 (poly-in-poly hover).
- slow: 1.8 MB file requests at 2.1-2.3 s (part of F26 notes).
- improvement: F6 (absolute path in ignored-result), F13 (tab+space indent), F17 (duplicate action titles, trailing space), F22 (missing collection path overrides core), unused-parameter on procs used as values.

## Passed cleanly
- tina: all 6 baseline packages; check/lint timings; symbols on all 82 included files; refs/callers/find/tests on generic and overloaded procs; local, proc and enum renames (apart from F9 misses); rename-package; reorder-params; attr; most code actions; full LSP pass with inlay hints off; formatter.
- odin-godot: renames, rename-package, move, attr, code actions in passing packages, LSP pass with inlay hints off, CLI timings on the generated file, formatter.
