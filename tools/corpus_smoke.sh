#!/usr/bin/env bash
# Corpus sweep: builds ./ols and ./odinfmt and runs them over pinned open-source Odin projects and Odin's core.
# Usage: tools/corpus_smoke.sh [--lsp] [PROJECT...]
#   PROJECT  limits the run: ols tina Skald karl2d examples odin-godot odin-http core (default: all)
#   --lsp    also drives the stdio LSP over every file
# Clones go to ${ROLS_CORPUS_DIR:-$HOME/.cache/rols-corpus}. Prints `FAIL <project> <step> <detail>` per failure,
# then a summary table. Exits 1 when any step failed, else 0.
set -euo pipefail
cd "$(dirname "$0")/.."
repo="$PWD"

lsp=0
names=()
for arg in "$@"; do
	case "$arg" in
	--lsp) lsp=1 ;;
	-h | --help)
		sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	-*)
		echo "unknown option $arg" >&2
		exit 2
		;;
	*) names+=("$arg") ;;
	esac
done
all_names=(ols tina Skald karl2d examples odin-godot odin-http core)
if [[ ${#names[@]} -eq 0 ]]; then
	names=("${all_names[@]}")
fi

TIMEOUT="$(command -v timeout || command -v gtimeout || true)"
if [[ -z "$TIMEOUT" ]]; then
	echo "needs timeout or gtimeout on PATH" >&2
	exit 2
fi

./build.sh >/dev/null
./odinfmt.sh >/dev/null
OLS="$repo/ols"
ODINFMT="$repo/odinfmt"
export OLS_BUILTIN_FOLDER="$repo/builtin"

odin_root="$(odin root)"
odin_root="${odin_root%/}"
corpus="${ROLS_CORPUS_DIR:-$HOME/.cache/rols-corpus}"
mkdir -p "$corpus"
corpus="$(cd "$corpus" && pwd -P)"
for forbidden in "$(cd "$repo" && pwd -P)" "$(cd "$odin_root" && pwd -P)"; do
	if [[ "$corpus/" == "$forbidden/"* ]]; then
		echo "ROLS_CORPUS_DIR must not be inside $forbidden" >&2
		exit 2
	fi
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

VET_OFF='"enable_checker_vet_style":false,"enable_checker_vet_semicolon":false,"enable_checker_vet_tabs":false,"enable_checker_vet_unused_variables":false,"enable_checker_vet_shadowing":false,"enable_checker_vet_cast":false'

# project NAME: sets url, sha, colls (NAME=PATH pairs, paths relative to the project) and cfg (the ols.json text).
project() {
	colls=""
	cfg='{}'
	case "$1" in
	ols)
		url=https://github.com/DanielGavin/ols sha=146d5e3dcc8bde5a23cf3a4893f30fc631d9d46e colls="src=src"
		cfg='{"collections":[{"name":"src","path":"src"}],'"$VET_OFF"'}'
		;;
	tina) url=https://github.com/pmbanugo/tina sha=a2e8d4dc53394dd6772d08e79a41d6b56ba3a65e ;;
	Skald)
		url=https://github.com/BuLEEto/Skald sha=6bbb664b9f421c25aa9be4540d5c9dedd20d32ca colls="gui=."
		cfg='{"collections":[{"name":"gui","path":"."}]}'
		;;
	karl2d) url=https://github.com/karl-zylinski/karl2d sha=0b8c66358a07261b259f724dae1d163830f2facc ;;
	examples) url=https://github.com/odin-lang/examples sha=dcc6128eca09e01e3585d9cbcb9a21b5cf621c22 ;;
	odin-godot)
		url=https://github.com/dresswithpockets/odin-godot sha=93395901a76f62a9f2adff76c2eb38a185d91513 colls="godot=."
		cfg='{"collections":[{"name":"godot","path":"."}],"checker_args":"-vet -strict-style -define:REAL_PRECISION=single"}'
		;;
	odin-http) url=https://github.com/laytan/odin-http sha=fac113fbd828aad3d71479a534b5de4358b6a07b ;;
	core) url="" sha="" ;;
	*) return 1 ;;
	esac
}

failures=0
pfail=0
name=""
# fail STEP DETAIL...
fail() {
	local step="$1"
	shift
	echo "FAIL $name $step $*"
	failures=$((failures + 1))
	pfail=$((pfail + 1))
}

# olsq OUT STEP ARGS...: runs `ols query ARGS` in the project with a timeout and sets rc.
# A timeout, a signal exit or a panic on stderr is reported and returns 1.
olsq() {
	local out="$1" step="$2"
	shift 2
	rc=0
	(cd "$root" && "$TIMEOUT" 120 "$OLS" query --root "$root" "$@") >"$out" 2>"$out.err" </dev/null || rc=$?
	local what="${*//$root\//}"
	if [[ $rc -eq 124 ]]; then
		fail "$step" "timeout 120s: $what"
	elif [[ $rc -ge 128 ]]; then
		fail "$step" "signal $((rc - 128)): $what"
	elif grep -qiE 'panic|assertion' "$out.err"; then
		fail "$step" "panic: $what: $(grep -m1 -iE 'panic|assertion' "$out.err")"
	else
		return 0
	fi
	return 1
}

# coll_flags BASE: one -collection flag per line, with paths under BASE.
coll_flags() {
	local pair
	for pair in $colls; do
		echo "-collection:${pair%%=*}=$1/${pair#*=}"
	done
}

# odin_check BASE DIR OUT: plain `odin check` of DIR with the project collections under BASE.
odin_check() {
	local flags=() flag
	while IFS= read -r flag; do flags+=("$flag"); done < <(coll_flags "$1")
	(cd "$1" && "$TIMEOUT" 120 odin check "$2" -no-entry-point ${flags[@]+"${flags[@]}"}) >"$3" 2>&1 </dev/null
}

# first_error FILE: the first compiler error line, else the first line, paths shortened.
first_error() {
	{ grep -m1 -E 'Error|error' "$1" || head -1 "$1"; } | sed "s|$root/||g; s|$work/[^/]*/fmt1/||g" | cut -c1-200
}

# rel PATH: PATH relative to the project root, `.` for the root itself.
rel() {
	if [[ "$1" == "$root" ]]; then
		echo .
	else
		echo "${1#"$root"/}"
	fi
}

# has_decl FILE: the file declares something at column 0 outside block comments and raw strings.
# A file with a top-level `when` is exempt: its body often sits at column 0 and the branch may be inactive,
# and text alone cannot tell which declarations the compiler sees. A backtick in a comment, string or rune
# can toggle the raw-string state wrongly; the check then errs toward a missed or extra alarm on that file.
# The caller prints `SKIP` for the exemption.
has_decl() {
	awk '{
		line = $0
		if (line ~ /^when[ \t]/) skip = 1
		if (depth == 0 && !raw && line ~ /^[A-Za-z_][A-Za-z0-9_]*([ \t]*,[ \t]*[A-Za-z_][A-Za-z0-9_]*)*[ \t]*:/) found = 1
		if (!raw) depth += gsub(/\/\*/, "", line) - gsub(/\*\//, "", line)
		if (gsub(/`/, "", line) % 2 == 1) raw = !raw
	} END { exit !(found && !skip) }' "$1"
}

# fetch: a shallow clone of url at sha in $root, reset and cleaned.
# It refuses an existing $root that is not a clone of url, since the reset would destroy local work.
fetch() {
	if [[ -e "$root" && "$(git -C "$root" remote get-url origin 2>/dev/null)" != "$url" ]]; then
		echo "$root exists and is not a clone of $url" >&2
		return 1
	fi
	if [[ ! -d "$root/.git" ]]; then
		mkdir -p "$root"
		git -C "$root" init -q
		git -C "$root" remote add origin "$url"
	fi
	if ! git -C "$root" cat-file -e "$sha^{commit}" 2>/dev/null; then
		git -C "$root" fetch -q --depth 1 origin "$sha" || return 1
	fi
	git -C "$root" checkout -q --force "$sha" && git -C "$root" clean -fdq
}

restore() {
	git -C "$root" checkout -q . && git -C "$root" clean -fdq
	printf '%s\n' "$cfg" >"$root/ols.json"
}

write_lsp_driver() {
	cat >"$work/lsp.py" <<'PY'
"""Opens every file over stdio and sends the requests an editor sends; prints FAIL lines and a summary line."""
import json, os, queue, subprocess, sys, tempfile, threading, time

ols, project, root = sys.argv[1:4]
files = [l.rstrip("\n") for l in sys.stdin if l.strip()]
TIMEOUT = 20
failures = 0


class Timeout(Exception):
    pass


class Crash(Exception):
    pass


def fail(detail):
    global failures
    failures += 1
    print("FAIL %s lsp %s" % (project, detail), flush=True)


class Server:
    def __init__(self):
        self.log = tempfile.TemporaryFile()
        self.proc = subprocess.Popen([ols], cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log)
        self.queue = queue.Queue()
        self.next_id = 0
        threading.Thread(target=self.read, daemon=True).start()

    def start(self):
        uri = "file://" + root
        self.request("initialize", {
            "processId": os.getpid(), "rootUri": uri,
            "workspaceFolders": [{"uri": uri, "name": project}],
            "capabilities": {"workspace": {"applyEdit": True}},
            "initializationOptions": {"enable_semantic_tokens": True},
        })
        self.notify("initialized", {})

    def read(self):
        out = self.proc.stdout
        try:
            while True:
                length = None
                while True:
                    line = out.readline()
                    if not line:
                        self.queue.put(None)
                        return
                    if line == b"\r\n":
                        break
                    key, _, value = line.decode().partition(":")
                    if key.lower() == "content-length":
                        length = int(value)
                self.queue.put(json.loads(out.read(length)))
        except Exception:
            self.queue.put(None)

    def send(self, msg):
        data = json.dumps(msg).encode()
        try:
            self.proc.stdin.write(b"Content-Length: %d\r\n\r\n" % len(data) + data)
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError):
            raise Crash(self.exit_code())

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def request(self, method, params):
        self.next_id += 1
        rid = self.next_id
        self.send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        deadline = time.monotonic() + TIMEOUT
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise Timeout()
            try:
                msg = self.queue.get(timeout=remaining)
            except queue.Empty:
                raise Timeout()
            if msg is None:
                raise Crash(self.exit_code())
            if "method" in msg and "id" in msg:
                self.send({"jsonrpc": "2.0", "id": msg["id"], "result": None})
            elif msg.get("id") == rid:
                return msg

    def exit_code(self):
        try:
            code = self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            return "running"
        self.log.seek(0)
        lines = [l for l in self.log.read().decode(errors="replace").splitlines() if l.strip()]
        tail = lines[-1][:160] if lines else ""
        return "rc=%s %s" % (code, tail)

    def kill(self):
        self.proc.kill()
        self.proc.wait()


def utf16(text):
    return len(text.encode("utf-16-le")) // 2


def requests_for(uri, text):
    lines = text.split("\n")
    doc = {"uri": uri}
    yield "documentSymbol", "textDocument/documentSymbol", {"textDocument": doc}
    yield "semanticTokens", "textDocument/semanticTokens/full", {"textDocument": doc}
    whole = {"start": {"line": 0, "character": 0}, "end": {"line": len(lines), "character": 0}}
    yield "inlayHint", "textDocument/inlayHint", {"textDocument": doc, "range": whole}
    for line in sorted({len(lines) // 4, len(lines) // 2, 3 * len(lines) // 4}):
        content = lines[line]
        pos = {"line": line, "character": utf16(content[: len(content) - len(content.lstrip())])}
        params = {"textDocument": doc, "range": {"start": pos, "end": pos}, "context": {"diagnostics": []}}
        yield "codeAction@%d:%d" % (line + 1, pos["character"] + 1), "textDocument/codeAction", params
    options = {"tabSize": 4, "insertSpaces": False}
    yield "formatting", "textDocument/formatting", {"textDocument": doc, "options": options}


server = None
for path in files:
    rel = os.path.relpath(path, root)
    with open(path, encoding="utf-8", errors="replace") as f:
        text = f.read()
    uri = "file://" + path
    step = "initialize"
    try:
        if server is None:
            server = Server()
            server.start()
        step = "didOpen"
        server.notify("textDocument/didOpen", {
            "textDocument": {"uri": uri, "languageId": "odin", "version": 1, "text": text}})
        for step, method, params in requests_for(uri, text):
            started = time.monotonic()
            reply = server.request(method, params)
            if "error" in reply:
                err = reply["error"]
                fail("%s %s error %s %s" % (rel, step, err.get("code"), err.get("message", "")[:160]))
        server.notify("textDocument/didClose", {"textDocument": {"uri": uri}})
    except Timeout:
        fail("%s %s timeout %ds" % (rel, step, TIMEOUT))
        server.kill()
        server = None
    except Crash as crash:
        fail("%s %s crash %s" % (rel, step, crash.args[0]))
        server.kill()
        server = None

if server is not None:
    try:
        server.request("shutdown", None)
        server.notify("exit", None)
        server.proc.wait(timeout=10)
    except (Timeout, Crash, subprocess.TimeoutExpired):
        fail("shutdown did not complete")
        server.kill()
print("LSPSUMMARY %d %d" % (len(files), failures))
PY
}
if [[ $lsp -eq 1 ]]; then
	write_lsp_driver
fi

summary=()

for name in "${names[@]}"; do
	pfail=0
	if ! project "$name"; then
		fail setup "unknown project, expected one of: ${all_names[*]}"
		continue
	fi
	w="$work/$name"
	mkdir -p "$w"
	readonly_root=0
	if [[ "$name" == core ]]; then
		root="$odin_root/core"
		readonly_root=1
	else
		root="$corpus/$name"
		if ! fetch >"$w/fetch.log" 2>&1; then
			fail fetch "cannot check out $sha from $url: $(tail -1 "$w/fetch.log")"
			summary+=("$name|-|-|-|-|-|-|-")
			continue
		fi
		printf '%s\n' "$cfg" >"$root/ols.json"
	fi
	echo "== $name ($root)" >&2

	find "$root" -name .git -prune -o -type f -name '*.odin' -print | LC_ALL=C sort >"$w/files"
	sed 's|/[^/]*$||' "$w/files" | LC_ALL=C sort -u >"$w/pkgs"
	: >"$w/pass"
	while IFS= read -r pkg; do
		if odin_check "$root" "$pkg" "$w/baseline.out"; then
			echo "$pkg" >>"$w/pass"
		fi
	done <"$w/pkgs"
	npkgs=$(wc -l <"$w/pkgs" | tr -d ' ')
	npass=$(wc -l <"$w/pass" | tr -d ' ')

	# check and lint per package; lint errors in a package that compiles are false errors.
	cl_ok=0
	while IFS= read -r pkg; do
		ok=1
		olsq "$w/check.out" check check "$pkg" || ok=0
		if olsq "$w/lint.out" lint lint "$pkg"; then
			if [[ $rc -ne 0 ]]; then
				fail lint "exit $rc: $(rel "$pkg"): $(head -1 "$w/lint.out.err")"
				ok=0
			elif grep -qxF "$pkg" "$w/pass"; then
				while IFS= read -r line; do
					fail lint "false error: ${line#"$root"/}"
					ok=0
				done < <(grep -E '^/.*:[0-9]+:[0-9]+: error: ' "$w/lint.out" || true)
			fi
		else
			ok=0
		fi
		cl_ok=$((cl_ok + ok))
	done <"$w/pkgs"

	# symbols per file; an empty outline counts only when the file has a top-level declaration.
	sym_ok=0
	nfiles=$(wc -l <"$w/files" | tr -d ' ')
	while IFS= read -r file; do
		olsq "$w/sym.out" symbols symbols "$file" || continue
		if [[ $rc -eq 1 ]] && has_decl "$file"; then
			fail symbols "empty outline: ${file#"$root"/}"
		elif [[ $rc -eq 1 ]] && grep -q '^when[[:space:]]' "$file"; then
			echo "SKIP $name symbols ${file#"$root"/}" >&2
			sym_ok=$((sym_ok + 1))
		elif [[ $rc -gt 1 ]]; then
			fail symbols "exit $rc: ${file#"$root"/}"
		else
			sym_ok=$((sym_ok + 1))
		fi
	done <"$w/files"

	# Formatter: format a copy twice; the first pass must keep every passing package compiling, the second must not change anything.
	fmt1="$w/fmt1"
	fmt2="$w/fmt2"
	cp -R "$root" "$fmt1"
	fmt_bad=0
	for copy in "$fmt1" "$fmt2"; do
		if [[ "$copy" == "$fmt2" ]]; then
			cp -R "$fmt1" "$fmt2"
		fi
		while IFS= read -r file; do
			frc=0
			"$TIMEOUT" 120 "$ODINFMT" -path:"$copy/${file#"$root"/}" -w >/dev/null 2>"$w/fmt.err" </dev/null || frc=$?
			if [[ $frc -eq 124 || $frc -ge 128 ]]; then
				fail format "odinfmt exit $frc: ${file#"$root"/}"
				fmt_bad=$((fmt_bad + 1))
			fi
		done <"$w/files"
		if [[ "$copy" == "$fmt1" ]]; then
			while IFS= read -r pkg; do
				if ! odin_check "$fmt1" "$fmt1/$(rel "$pkg")" "$w/fmtcheck.out"; then
					# The copy of core meets the real core through its imports; that says nothing about the formatter.
					if [[ $readonly_root -eq 1 ]] && grep -q "Duplicate declaration of 'package" "$w/fmtcheck.out"; then
						echo "SKIP $name format $(rel "$pkg")" >&2
						continue
					fi
					fail format "breaks $(rel "$pkg"): $(first_error "$w/fmtcheck.out")"
					fmt_bad=$((fmt_bad + 1))
				fi
			done <"$w/pass"
		fi
	done
	while IFS= read -r line; do
		file="${line#Files "$fmt1"/}"
		fail format "not idempotent: ${file%% and *}"
		fmt_bad=$((fmt_bad + 1))
	done < <(diff -rq -x .git "$fmt1" "$fmt2" || true)
	rm -rf "$fmt1" "$fmt2"
	fmt_result=$([[ $fmt_bad -eq 0 ]] && echo ok || echo "$fmt_bad bad")

	# modernize: apply without the built-in gate, then judge the result with plain odin check.
	if [[ $readonly_root -eq 1 ]]; then
		mod_result="dry run"
		if olsq "$w/mod.out" modernize modernize; then
			if [[ $rc -ne 0 && $rc -ne 3 ]]; then
				fail modernize "exit $rc: $(grep -m1 '^error:' "$w/mod.out.err" || head -1 "$w/mod.out.err")"
				mod_result="exit $rc"
			fi
		else
			mod_result="crash"
		fi
	else
		mod_result="none"
		if olsq "$w/mod.out" modernize modernize --apply --no-check; then
			if [[ $rc -eq 0 ]]; then
				changed=$(git -C "$root" status --porcelain | grep -cv ' ols.json$' || true)
				broken=0
				while IFS= read -r pkg; do
					if ! odin_check "$root" "$pkg" "$w/modcheck.out"; then
						fail modernize "breaks $(rel "$pkg"): $(first_error "$w/modcheck.out")"
						broken=$((broken + 1))
					fi
				done <"$w/pass"
				mod_result="$changed files"
				if [[ $broken -gt 0 ]]; then
					mod_result="$mod_result, $broken broken"
				fi
			elif [[ $rc -ne 3 ]]; then
				fail modernize "exit $rc: $(grep -m1 '^error:' "$w/mod.out.err" || head -1 "$w/mod.out.err")"
				mod_result="exit $rc"
			fi
		else
			mod_result="crash"
		fi
		restore
	fi

	lsp_result="-"
	if [[ $lsp -eq 1 ]]; then
		lsp_line=""
		while IFS= read -r line; do
			case "$line" in
			LSPSUMMARY*) lsp_line="$line" ;;
			FAIL*)
				echo "$line"
				failures=$((failures + 1))
				pfail=$((pfail + 1))
				;;
			esac
		done < <(python3 "$work/lsp.py" "$OLS" "$name" "$root" <"$w/files" 2>&1 || true)
		if [[ -z "$lsp_line" ]]; then
			fail lsp "driver ended without a summary"
			lsp_result="driver failed"
		else
			read -r _ lsp_files lsp_fails <<<"$lsp_line"
			lsp_result=$([[ $lsp_fails -eq 0 ]] && echo "ok $lsp_files" || echo "$lsp_fails/$lsp_files bad")
		fi
	fi

	summary+=("$name|$npkgs|$npass|$cl_ok/$npkgs|$sym_ok/$nfiles|$mod_result|$fmt_result|$lsp_result")
done

echo
row='%-11s %8s %8s %10s %10s %18s %10s %14s\n'
# shellcheck disable=SC2059
printf "$row" project packages baseline check/lint symbols modernize format lsp
for line in ${summary[@]+"${summary[@]}"}; do
	IFS='|' read -r c1 c2 c3 c4 c5 c6 c7 c8 <<<"$line"
	# shellcheck disable=SC2059
	printf "$row" "$c1" "$c2" "$c3" "$c4" "$c5" "$c6" "$c7" "$c8"
done
echo "$failures failures"
[[ $failures -eq 0 ]]
