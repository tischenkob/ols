#!/usr/bin/env python3
# Edit triage (build ./ols first; cases are written to $ROLS_TRIAGE_DIR, default /tmp/rols-triage): writes a package, runs a dry-run or --no-check edit, prints the resulting text and whether `odin check` still passes.
import os, re, shutil, subprocess, sys
REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "../../.."))
T = os.environ.get("ROLS_TRIAGE_DIR", "/tmp/rols-triage"); OLS = os.path.join(REPO, "ols")
env = dict(os.environ, OLS_BUILTIN_FOLDER=os.path.join(REPO, "builtin"))
C = []
def case(name, files, args, show="a.odin", timeout=15): C.append((name, files, args, show, timeout))
P = "package p\n\n"
case("fill_fixed_array", {"a.odin": P+"f :: proc() -> [8]u8 {\n\tbuf: [8]u8\n\tfor i in 0 ..< len(buf) {\n\t\tbuf[i] = 'a'\n\t}\n\treturn buf\n}\n"}, ["modernize", "--apply", "--no-check"])
case("fill_index_value", {"a.odin": P+"idx :: proc(s: []int) {\n\tfor i in 0 ..< len(s) {\n\t\ts[i] = i\n\t}\n}\n"}, ["modernize", "--apply", "--no-check"])
case("sum_over_range", {"a.odin": P+"total :: proc() -> int {\n\tt := 0\n\tfor i in 1 ..= 10 {\n\t\tt += i\n\t}\n\treturn t\n}\n"}, ["modernize", "--rule", "use-stdlib/sum", "--diff"])
case("redundant_parens_comment", {"a.odin": P+"f :: proc(k: string) -> bool {\n\treturn (\n\t\t// first\n\t\tk != \"a\" &&\n\t\tk != \"b\")\n}\n"}, ["modernize", "--apply", "--no-check"])
case("bool_return_comment", {"a.odin": P+"f :: proc(a, b: int) -> bool {\n\tif a == b {\n\t\treturn false\n\t}\n\n\t// Rule 999: default is to break.\n\treturn true\n}\n"}, ["modernize", "--apply", "--no-check"])
case("nested_if_one_line_indent", {"a.odin": P+"f :: proc(a, b: bool) -> int {\n\tif a {\n\t\tif b { return 1 }\n\t}\n\treturn 0\n}\n"}, ["modernize", "--apply", "--no-check"])
case("unwrap_block_for", {"a.odin": P+"f :: proc(buf: []int) {\n\tfor i in 0 ..< len(buf) {\n\t\tbuf[i] = i\n\t}\n}\n"}, ["actions", "a.odin:4:2", "--apply", "Unwrap block", "--no-check"])
case("unwrap_block_unreachable", {"a.odin": P+"f :: proc(running: bool) -> int {\n\tif running {\n\t\treturn 1\n\t}\n\treturn 2\n}\n"}, ["actions", "a.odin:4:2", "--apply", "Unwrap block", "--no-check"])
case("invert_if_one_line", {"a.odin": P+"label :: proc(running: bool) -> string {\n\tl := \"Start\"\n\tif running { l = \"Pause\" }\n\treturn l\n}\n"}, ["actions", "a.odin:5:2", "--apply", "Invert if", "--no-check"])
case("add_ok_result_callers", {"a.odin": P+"get :: proc(x: int) -> int {\n\treturn x\n}\nuse :: proc() {\n\tv := get(1)\n\t_ = v\n}\n"}, ["actions", "a.odin:3:1", "--apply", "Add ok result", "--no-check"])
case("add_ok_result_or_return", {"a.odin": P+"Err :: enum { None, Bad }\ng :: proc(x: int) -> Err { return .None }\nh :: proc(x: int) -> Err {\n\tg(x) or_return\n\treturn .None\n}\n"}, ["actions", "a.odin:5:1", "--apply", "Add ok result", "--no-check"])
case("generate_test_enum", {"a.odin": P+"E :: enum { A, B }\nf :: proc() -> E { return .A }\n"}, ["actions", "a.odin:4:1", "--apply", "Generate test for f", "--no-check"], show="a_test.odin")
case("explicit_type_slice_field", {"a.odin": P+"S :: struct { arr: [4]int }\nf :: proc(s: ^S) {\n\tr := s.arr[:2]\n\t_ = r\n}\n"}, ["actions", "a.odin:5:2", "--apply", "Add explicit type", "--no-check"])
case("move_to_other_build", {"a.odin": P+"helper :: proc() {}\nuse :: proc() { helper() }\n", "c.odin": "#+build linux\npackage p\n"}, ["actions", "a.odin:3:1"], show="")
case("inline_file_private", {"a.odin": P+"@(private = \"file\")\nnorm :: proc(v: int) -> int { return v }\ndraw :: proc(x: int, y: int) {\n\t_ = norm(x)\n\t_ = y\n}\n", "b.odin": P+"use :: proc() {\n\tdraw(1, 2)\n}\n"}, ["actions", "b.odin:4:2"], show="")
case("actions_default_param_hang", {"a.odin": P+"mk :: proc(a := 2) -> int {\n\treturn a\n}\nf :: proc() {\n\t_ = mk(3)\n}\n"}, ["actions", "a.odin:8:6"], show="", timeout=20)
only = sys.argv[1:]
for name, files, args, show, to in C:
    if only and name not in only: continue
    d = os.path.join(T, name); shutil.rmtree(d, ignore_errors=True); os.makedirs(d)
    for f, s in {**files, "ols.json": "{}"}.items(): open(os.path.join(d, f), "w").write(s)
    try:
        r = subprocess.run([OLS, "query", *args], cwd=d, env=env, capture_output=True, text=True, timeout=to)
        out = (r.stdout + r.stderr).strip() + f"\nexit={r.returncode}"
    except subprocess.TimeoutExpired: out = "TIMEOUT"
    print(f"===== {name}\n{out[:900]}")
    if show and os.path.exists(os.path.join(d, show)) and "--apply" in args:
        print("--- " + show + ":\n" + open(os.path.join(d, show)).read())
        c = subprocess.run(["odin", "check", ".", "-no-entry-point"], cwd=d, capture_output=True, text=True)
        print("odin check:", "OK" if c.returncode == 0 else "FAIL " + (c.stderr + c.stdout).strip().splitlines()[0][:200])
