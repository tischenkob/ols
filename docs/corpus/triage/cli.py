#!/usr/bin/env python3
# Triage runner (build ./ols first; cases are written to $ROLS_TRIAGE_DIR, default /tmp/rols-triage): each case writes files into triage/<name>, runs one ols query and reports whether the bug reproduces.
import os, re, shutil, subprocess, sys
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
T = os.environ.get("ROLS_TRIAGE_DIR", "/tmp/rols-triage"); OLS = os.path.join(REPO, "ols")
env = dict(os.environ, OLS_BUILTIN_FOLDER=os.path.join(REPO, "builtin"))
C = []
def case(name, files, args, bug, cwd="", timeout=15, note=""):
    C.append((name, files, args, bug, cwd, timeout, note))

P = "package p\n\n"
# ---- false lints
case("dead_store_global", {"a.odin": P+"g: int\nread_g :: proc() -> int { return g }\nf :: proc() -> int {\n\tprev := g\n\tg = 1\n\tx := read_g()\n\tg = prev\n\treturn x\n}\n"}, ["lint", "."], r"dead-store")
case("dead_store_bare_return", {"a.odin": P+"parse :: proc(x: int) -> (ok: bool) {\n\tok = false\n\tif x > 0 {\n\t\treturn\n\t}\n\tok = true\n\treturn\n}\n"}, ["lint", "."], r"dead-store")
case("dead_store_escaped_ptr", {"a.odin": P+"Holder :: struct { p: ^int }\nread :: proc(h: ^Holder) -> int { return h.p^ }\nf :: proc() -> int {\n\tx: int\n\th := Holder{p = &x}\n\tx = 5\n\ta := read(&h)\n\tx = 6\n\treturn a + read(&h)\n}\n"}, ["lint", "."], r"dead-store")
case("unsigned_u64_literal", {"a.odin": P+"f :: proc(x: u64) -> bool { return x == 9_999_999_999_999_999_999 }\n"}, ["lint", "."], r"unsigned-negative")
case("naming_bool_const", {"a.odin": P+"is_enabled :: true\n"}, ["lint", "."], r"naming")
case("naming_underscore_type", {"a.odin": P+"_Private_Type :: struct {}\n"}, ["lint", "."], r"naming")
case("float_eq_types", {"a.odin": P+"Float :: f32\nconv :: proc($T: typeid) -> int {\n\twhen T == Float {\n\t\treturn 1\n\t} else {\n\t\treturn 0\n\t}\n}\n"}, ["lint", "."], r"float-equality")
case("alloc_mismatch_dynamic", {"a.odin": P+"f :: proc() -> int {\n\ta := make([dynamic]int, 0, 8, context.temp_allocator)\n\tdefer delete(a)\n\tm := make(map[int]int, context.temp_allocator)\n\tdefer delete(m)\n\tappend(&a, 1)\n\tm[1] = 1\n\treturn len(a) + len(m)\n}\n"}, ["lint", "."], r"allocator-mismatch|allocated with")
case("error_not_last_union", {"a.odin": P+"Shape :: union { int, f32 }\nmake_shape :: proc() -> (s: Shape, changed: bool) { return 1, true }\n"}, ["lint", "."], r"error-not-last")
case("error_not_last_enum_none", {"a.odin": P+"Kind :: enum { None, Box }\npick :: proc() -> (Kind, int) { return .Box, 1 }\n"}, ["lint", "."], r"error-not-last")
case("range_off_by_one_slice", {"a.odin": P+"prefixes :: proc(s: string) -> int {\n\tn := 0\n\tfor b in 0 ..= len(s) {\n\t\tn += len(s[:b])\n\t}\n\treturn n\n}\n"}, ["lint", "."], r"one past")
case("printf_multi_value", {"a.odin": P+"import \"core:fmt\"\ntwo :: proc() -> (f32, int) { return 1, 2 }\nf :: proc() { fmt.printfln(\"%v %v\", two()) }\n"}, ["lint", "."], r"printf-arity|needs 2")
case("printf_star_index", {"a.odin": P+"import \"core:fmt\"\nf :: proc() -> string { return fmt.aprintf(\"%- *[1]s|\", \"ab\", 6) }\n"}, ["lint", "."], r"needs 3")
case("ignored_result_error_proc_type", {"a.odin": P+"ErrorProc :: proc()\nset_cb :: proc(cb: ErrorProc) -> ErrorProc { return cb }\nf :: proc() { set_cb(nil) }\n"}, ["lint", "."], r"ignored")
case("ignored_result_delete_key", {"a.odin": P+"f :: proc(m: ^map[int]bool) { delete_key(m, 1) }\n"}, ["lint", "."], r"ignored")
case("ignored_result_mutex_guard", {"a.odin": P+"import \"core:sync\"\nm: sync.Mutex\nf :: proc() { sync.mutex_guard(&m) }\n"}, ["lint", "."], r"ignored")
case("empty_body_cond_call", {"a.odin": P+"step :: proc() -> bool { return false }\nf :: proc() {\n\tfor step() {}\n}\n"}, ["lint", "."], r"empty-body")
case("bool_compare_distinct", {"a.odin": P+"B :: distinct b32\ng :: proc() -> B { return true }\nf :: proc() -> bool { return g() == true }\n"}, ["lint", "."], r"bool-compare")
case("unknown_field_when", {"a.odin": P+"FLAG :: #config(FLAG, false)\nwhen FLAG {\n\tCfg :: struct { rate: int }\n} else {\n\tCfg :: struct {}\n}\nwhen FLAG {\n\tuse :: proc() -> Cfg { return Cfg{rate = 1} }\n}\n"}, ["lint", "."], r"unknown-field")
case("argcount_other_platform", {"a.odin": "#+build darwin\npackage p\n\nsetname :: proc(name: cstring) {}\n", "b_linux.odin": "#+build linux\npackage p\n\nsetname :: proc(id: u64, name: cstring) {}\nf :: proc() { setname(0, \"x\") }\n"}, ["lint", "."], r"argument-count")
case("argcount_private_file", {"b.odin": P+"create :: proc(a: int) {}\n", "w.odin": "#+build windows\n#+private file\npackage p\n\ncreate :: proc(a: int, b: rawptr) {}\nuse :: proc() { create(1, nil) }\n"}, ["lint", "."], r"argument-count")
# ---- query results
case("bsd_file_skipped", {"a_bsd.odin": P+"from_bsd :: proc() {}\n", "main.odin": P+"use :: proc() { from_bsd() }\n"}, ["def", "main.odin:3:18"], r"^$|exit=1")
case("symbols_build_excluded", {"a.odin": "#+build linux\npackage p\n\nfoo :: proc() {}\n"}, ["symbols", "a.odin"], r"^$|exit=1")
case("symbols_when_false_cond", {"a.odin": P+"FLAG :: false\nwhen FLAG == false {\n\ta :: proc() {}\n}\n"}, ["symbols", "a.odin"], r"^(?![\s\S]*Function a)")
case("symbols_config_kind", {"a.odin": P+"FLAG :: #config(FLAG, false)\n"}, ["symbols", "a.odin"], r"Variable")
case("when_string_cond_def", {"a.odin": P+"E_NAME :: \"gl\"\nwhen E_NAME == \"gl\" {\n\tE :: 1\n} else {\n\tE :: 2\n}\nuse :: proc() -> int { return E }\n"}, ["def", "a.odin:9:31"], r":7:|exit=1")
case("def_alias_const_field", {"a.odin": P+"S :: struct {\n\tx: proc(),\n}\n", "b.odin": P+"V :: S{x = f}\nf :: proc() {}\n", "c.odin": P+"qq :: V\nuse4 :: proc() { qq.x() }\n"}, ["def", "c.odin:4:21"], r"b\.odin")
case("impl_group_member", {"a.odin": P+"a :: proc(x: int) {}\nb :: proc(x: f32) {}\ng :: proc{a, b}\n"}, ["impl", "a.odin:3:1"], r"^(?![\s\S]*proc\{)")
case("hover_using_offset", {"a.odin": P+"Base :: struct { magic: int }\nDerived :: struct { using base: Base, extra: int }\nuse :: proc(d: ^Derived) { d.magic = 1 }\n"}, ["hover", "a.odin:5:31"], r"offset: 16")
case("callers_build_ignore", {"a.odin": P+"draw :: proc(x: int) {}\nmain :: proc() { draw(1) }\n", "doc.odin": "#+build ignore\npackage p\n\ndraw :: proc(x: int)\n"}, ["callers", "a.odin:3:1"], r"doc\.odin")
case("hover_poly_in_poly", {"a.odin": P+"conv :: proc(p: rawptr, $T: typeid) -> T { return (^T)(p)^ }\nouter :: proc($A: typeid, p: rawptr) -> A {\n\tx := conv(p, A)\n\treturn x\n}\n"}, ["hover", "a.odin:5:2"], r"typeid|exit=1")
case("hover_overload_poly_tag", {"a.odin": P+"Tag :: distinct u16\nT1 :: Tag(0x40)\na :: proc($tag: Tag, p: []u8) -> int { return 0 }\nb :: proc($tag: Tag, p: ^int) -> int { return 0 }\nab :: proc{a, b}\ng :: proc() {\n\tr1 := ab(T1, nil)\n\t_ = r1\n}\n"}, ["hover", "a.odin:9:2"], r"exit=1|^$")
case("hover_overload_first_member", {"lib/lib.odin": "package lib\n\nsend_raw :: proc(x: int) {}\nsend_typed :: proc(x: ^$T) {}\nsend :: proc{send_raw, send_typed}\n", "main.odin": "package p\n\nimport \"lib\"\nf :: proc() {\n\tv := 1\n\tlib.send(&v)\n}\n"}, ["hover", "main.odin:6:6"], r"x: int\)")
case("refs_enum_after_call_arg", {"a.odin": P+"E :: enum { X, Y }\nf :: proc(s: string, e: E) {}\ng :: proc(s: string) -> string { return s }\nmain :: proc() {\n\tf(g(\"x\"), .Y)\n\tf(\"x\", .Y)\n}\n"}, ["refs", "a.odin:3:16"], r"^(?![\s\S]*:8:)")
case("refs_enum_named_after_variadic", {"a.odin": P+"Align :: enum { Start, Center }\nrow :: proc(children: ..int, align: Align = .Start) -> int { return len(children) }\nmain :: proc() {\n\t_ = row(1, 2, align = .Center)\n}\n"}, ["refs", "a.odin:3:24"], r"^(?![\s\S]*:6:)")
case("refs_enum_in_comp_lit_arg", {"a.odin": P+"Kind :: enum { A, B }\nItem :: struct { kind: Kind }\ntake :: proc(it: Item) -> Kind { return it.kind }\nmain :: proc() {\n\t_ = take(Item{kind = .B})\n}\n"}, ["refs", "a.odin:3:19"], r"^(?![\s\S]*:7:)")
case("refs_pkg_global_field", {"a/a.odin": "package a\n\nConfig :: struct { x: int }\ncfg: Config\n", "main.odin": "package p\n\nimport \"a\"\nf :: proc() {\n\ta.cfg.x = 1\n}\n"}, ["refs", "a/a.odin:4:1"], r"^(?![\s\S]*main\.odin:5)")
case("refs_using_param_field", {"a.odin": "#+feature using-stmt\npackage p\n\nW :: struct { id: u32 }\nf :: proc(using w: ^W) -> u32 { return id }\n"}, ["refs", "a.odin:4:15"], r"^(?![\s\S]*:5:)")
case("rename_pkg_bare_name", {"lib/lib.odin": "package lib\n\nx :: 1\n", "main.odin": "package p\n\nimport \"lib\"\n_ :: lib\n"}, ["rename-package", "lib", "lib2"], r"^(?![\s\S]*\+_ :: lib2)")
case("refs_relative_root", {"a.odin": P+"helper :: proc() {}\nuse_a :: proc() { helper() }\n", "b.odin": P+"use_b :: proc() { helper() }\n"}, ["refs", "a.odin:3:1", "--root", "."], r"^(?![\s\S]*b\.odin)")
case("move_to_relative_path", {"pkg/a.odin": "package pkg\n\nf :: proc() {}\ng :: proc() {}\n"}, ["move", "pkg/a.odin:3:1", "--to", "pkg/b.odin"], r"must be in the directory")
case("ignored_result_abs_path", {"a.odin": P+"import \"core:os\"\nf :: proc() { os.remove(\"x\") }\n"}, ["lint", "."], r"\(Error\)")
case("shebang_logs_error", {"a.odin": "#!/usr/bin/env odin\npackage p\n\nf :: proc() {}\n"}, ["symbols", "a.odin"], r"unsupported comment")
case("symbols_stable_order", {"a.odin": P+"a :: proc() {}\nb :: proc() {}\nc :: proc() {}\nd :: proc() {}\ne :: proc() {}\nf :: proc() {}\n"}, ["symbols", "a.odin"], r"ORDER")
case("check_no_entry_point_dup", {"ols.json": '{"checker_args": "-no-entry-point"}', "a.odin": P+"f :: proc() { x: int = \"s\"; _ = x }\n"}, ["check", "."], r"^(?![\s\S]*Cannot)")
case("vet_style_hides_errors", {"a.odin": P+"S :: struct {\n\ta, b: int\n}\nf :: proc() { x: int = \"s\"; _ = x }\n"}, ["check", "."], r"^(?![\s\S]*Cannot)")

only = sys.argv[1:]
for name, files, args, bug, cwd, to, note in C:
    if only and name not in only: continue
    d = os.path.join(T, name); shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    if "ols.json" not in files: files = {**files, "ols.json": "{}"}
    for f, s in files.items():
        os.makedirs(os.path.dirname(os.path.join(d, f)), exist_ok=True); open(os.path.join(d, f), "w").write(s)
    runs = 3 if bug == "ORDER" else 1
    outs = []
    for _ in range(runs):
        try:
            r = subprocess.run([OLS, "query", *args], cwd=os.path.join(d, cwd), env=env, capture_output=True, text=True, timeout=to)
            out = (r.stdout + r.stderr).replace(d + "/", "").replace("/private" + d + "/", "").strip() + ("" if r.returncode == 0 else f"\nexit={r.returncode}")
        except subprocess.TimeoutExpired:
            out = "TIMEOUT"
        outs.append(out)
    out = outs[0]
    hit = (len(set(outs)) > 1) if bug == "ORDER" else bool(re.search(bug, out, re.M)) or out == "TIMEOUT"
    print(f"{'REPRO' if hit else 'clean'}  {name}\n    " + out.replace("\n", "\n    ")[:500])
