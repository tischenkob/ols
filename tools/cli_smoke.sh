#!/usr/bin/env bash
# Smoke test for `ols query`: builds ./ols and runs every subcommand against a temp package.
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh >/dev/null
OLS="$PWD/ols"
export OLS_BUILTIN_FOLDER="$PWD/builtin"

dir="$(mktemp -d)"
trap 'rm -rf "$dir"' EXIT
mkdir "$dir/bad"
echo '{}' > "$dir/ols.json"
cat > "$dir/main.odin" <<'ODIN'
package smoke

import "core:fmt"

main :: proc() {
	value := add(1, 2)
	if value > 2 {
		fmt.println(value)
	}
	total := value * 3 + 1
	fmt.println(total)
	fmt.println(scale(total, 2))
}
ODIN
cat > "$dir/util.odin" <<'ODIN'
package smoke

add :: proc(a, b: int) -> int {
	return a + b
}

twice :: proc(a: int) -> int {
	return add(a, a)
}

add_f :: proc(a, b: f32) -> f32 {
	return a + b
}

combine :: proc{add, add_f}

scale :: proc(v, k: int) -> int {
	return v * k
}
ODIN
cat > "$dir/bad/bad.odin" <<'ODIN'
package bad

x: int = "not an int"
ODIN

expect() {
	local name="$1" pattern="$2" out
	shift 2
	out="$("$@")"
	if ! grep -q -- "$pattern" <<<"$out"; then
		echo "FAIL $name: expected $pattern in:" >&2
		echo "$out" >&2
		exit 1
	fi
	echo "ok $name"
}

expect def "util.odin" "$OLS" query def "$dir/main.odin:6:11"
expect refs "main.odin:6:11: value := add(1, 2)" "$OLS" query refs "$dir/util.odin:3:1"
expect refs-json '"uri"' "$OLS" query refs "$dir/util.odin:3:1" --json
expect hover "add" "$OLS" query hover "$dir/main.odin:6:11"
expect impl 'util.odin:11:1: add_f' "$OLS" query impl "$dir/util.odin:15:1"
expect callers "main.odin" "$OLS" query callers "$dir/util.odin:3:1"
expect callers-group '^combine ' "$OLS" query callers "$dir/util.odin:3:1"
expect callees '^add .*util.odin:3:1' "$OLS" query callees "$dir/util.odin:7:1"
expect callees-group '^add_f ' "$OLS" query callees "$dir/util.odin:15:1"
expect symbols 'Function main' "$OLS" query symbols "$dir/main.odin"
expect api "^add :: proc(a, b: int) -> int" "$OLS" query api "$dir"
expect api-group "^combine :: proc {add, add_f}" "$OLS" query api "$dir"
expect api-name "^add :: proc(a, b: int) -> int" "$OLS" query api "$dir" add
expect api-core "^clone :: proc(s: string" "$OLS" query --root "$dir" api core:strings clone
expect find "util.odin:3:1: Function add" "$OLS" query --root "$dir" find add
if command -v git >/dev/null; then
	git -C "$dir" init -q
	echo 'out/' > "$dir/.gitignore"
	mkdir "$dir/out"
	cat > "$dir/out/gen.odin" <<'ODIN'
package gen

import "core:fmt"

smoke_generated_marker :: proc() {
	fmt.println(1)
}
ODIN
	found="$("$OLS" query --root "$dir" find smoke_generated_marker || true)"
	if grep -q "out/gen.odin" <<<"$found"; then echo "FAIL find-gitignored: $found"; exit 1; fi
	echo "ok find-gitignored"
	refs="$("$OLS" query --root "$dir" refs "$dir/main.odin:8:7")"
	if ! grep -q "main.odin:8:7" <<<"$refs" || grep -q "out/gen.odin" <<<"$refs"; then echo "FAIL refs-gitignored: $refs"; exit 1; fi
	echo "ok refs-gitignored"
	echo '{"workspace_include": ["out/**"]}' > "$dir/ols.json"
	expect find-included "out/gen.odin:5:1: Function smoke_generated_marker" "$OLS" query --root "$dir" find smoke_generated_marker
	expect refs-included "out/gen.odin:6:6" "$OLS" query --root "$dir" refs "$dir/main.odin:8:7"
	echo '{"enable_workspace_gitignore": false}' > "$dir/ols.json"
	expect find-gitignore-off "out/gen.odin:5:1: Function smoke_generated_marker" "$OLS" query --root "$dir" find smoke_generated_marker
	echo '{}' > "$dir/ols.json"
	rm -rf "$dir/out"
else
	echo "skip workspace filter: git is not on PATH"
fi
expect actions "Invert if" "$OLS" query actions "$dir/main.odin:7:2"
expect actions-apply "main.odin" "$OLS" query actions "$dir/main.odin:10:11-10:20" --apply "Extract variable"
grep -q "value \* 3" "$dir/main.odin" && grep -q "total := .* + 1" "$dir/main.odin"
odin check "$dir" -no-entry-point
echo "ok actions-apply check"
expect generate-test "util_test.odin" "$OLS" query actions "$dir/util.odin:3:1" --apply "Generate test for add"
grep -q "^test_add :: proc(t: ^testing.T)" "$dir/util_test.odin" && grep -q 'import "core:testing"' "$dir/util_test.odin"
odin check "$dir" -no-entry-point
echo "ok generate-test check"
expect rename-apply "util.odin" "$OLS" query rename "$dir/util.odin:3:1" plus --apply
grep -q "plus(1, 2)" "$dir/main.odin" && grep -q "^plus ::" "$dir/util.odin"
odin check "$dir" -no-entry-point
echo "ok rename-apply check"
expect reorder-params-apply "util.odin" "$OLS" query reorder-params "$dir/util.odin:17:1" --order 1,0 --apply
grep -q "scale :: proc(k: int, v: int)" "$dir/util.odin" && grep -q "scale(2, total)" "$dir/main.odin"
odin check "$dir" -no-entry-point
echo "ok reorder-params-apply check"
got=0
"$OLS" query reorder-params "$dir/util.odin:3:1" --order 1,0 >/dev/null 2>&1 || got=$?
if [[ $got -ne 1 ]]; then echo "FAIL reorder-params group member: exit $got"; exit 1; fi
echo "ok reorder-params refused"
expect move-new "scale.odin" "$OLS" query move "$dir/util.odin:17:1" --to scale.odin --apply
grep -q "^scale :: proc" "$dir/scale.odin" && ! grep -q "^scale :: proc" "$dir/util.odin"
odin check "$dir" -no-entry-point
echo "ok move-new check"
expect move-existing "main.odin" "$OLS" query move "$dir/util.odin:7:1" --to main.odin --apply
grep -q "^twice :: proc" "$dir/main.odin" && ! grep -q "^twice :: proc" "$dir/util.odin"
odin check "$dir" -no-entry-point
echo "ok move-existing check"
expect_exit() {
	local want="$1" name="$2" got=0
	shift 2
	"$@" >/dev/null 2>&1 || got=$?
	if [[ $got -ne $want ]]; then
		echo "FAIL $name: exit $got, expected $want" >&2
		exit 1
	fi
	echo "ok $name"
}
mkdir "$dir/safe"
cat > "$dir/safe/a.odin" <<'ODIN'
package safe

main :: proc() {
	first := one()
	second := 2
	_ = first + second
}

one :: proc() -> int {
	return 1
}
ODIN
cp "$dir/safe/a.odin" "$dir/a.orig"
expect dry-run-diff "^+uno :: proc() -> int {" "$OLS" query rename "$dir/safe/a.odin:9:1" uno
expect dry-run-header "^--- a.*safe/a.odin" "$OLS" query rename "$dir/safe/a.odin:9:1" uno
expect dry-run-summary "^rename: 2 edits in 1 file$" "$OLS" query rename "$dir/safe/a.odin:9:1" uno
expect dry-run-json '"status": "dry_run"' "$OLS" query rename "$dir/safe/a.odin:9:1" uno --json
cmp -s "$dir/safe/a.odin" "$dir/a.orig" || { echo "FAIL dry run wrote the file"; exit 1; }
expect_exit 0 dry-run-exit "$OLS" query rename "$dir/safe/a.odin:9:1" uno
expect_exit 3 noop-exit "$OLS" query rename "$dir/safe/a.odin:9:1" one
expect_exit 1 refused-exit "$OLS" query reorder-params "$dir/safe/a.odin:4:2" --order 0
expect refused-cause "^error: the position is not on the name of a top-level procedure" sh -c "\"$OLS\" query reorder-params \"$dir/safe/a.odin:4:2\" --order 0 2>&1 || true"
expect refused-json '"status": "refused"' sh -c "\"$OLS\" query reorder-params \"$dir/safe/a.odin:4:2\" --order 0 --json || true"
expect_exit 2 usage-exit "$OLS" query reorder-params "$dir/safe/a.odin:9:1" --order x
expect_exit 2 usage-move-exit "$OLS" query move "$dir/safe/a.odin:9:1"
expect_exit 4 check-failed-exit "$OLS" query rename "$dir/safe/a.odin:4:2" second --apply
cmp -s "$dir/safe/a.odin" "$dir/a.orig" || { echo "FAIL check-failed rollback is not byte for byte"; exit 1; }
echo "ok check-failed rollback"
expect check-failed-error "^error: .*a.odin:5:2: Redeclaration of 'second'" sh -c "\"$OLS\" query rename \"$dir/safe/a.odin:4:2\" second --apply 2>&1 || true"
expect_exit 0 no-check-exit "$OLS" query rename "$dir/safe/a.odin:4:2" second --apply --no-check
cp "$dir/a.orig" "$dir/safe/a.odin"
echo '{"odin_command": "/nonexistent/odin"}' > "$dir/ols.json"
expect_exit 1 check-cannot-run-exit "$OLS" query rename "$dir/safe/a.odin:9:1" uno --apply
cmp -s "$dir/safe/a.odin" "$dir/a.orig" || { echo "FAIL check-cannot-run wrote the file"; exit 1; }
echo '{}' > "$dir/ols.json"
# A _js.odin file is not built on this host, so moving `one` there leaves its call undeclared.
expect_exit 4 created-rollback-exit "$OLS" query move "$dir/safe/a.odin:9:1" --to one_js.odin --apply
[[ ! -e "$dir/safe/one_js.odin" ]] || { echo "FAIL created-rollback left one_js.odin"; exit 1; }
cmp -s "$dir/safe/a.odin" "$dir/a.orig" || { echo "FAIL created-rollback is not byte for byte"; exit 1; }
echo "ok created-rollback deletes the created file"
echo '{"checker_skip_packages": ["safe"]}' > "$dir/ols.json"
expect skip-warning "^warning: no touched package can be checked" sh -c "\"$OLS\" query rename \"$dir/safe/a.odin:9:1\" uno --apply 2>&1"
cp "$dir/a.orig" "$dir/safe/a.odin"
expect skip-warning-json '"reasons": \["no touched package can be checked' "$OLS" query rename "$dir/safe/a.odin:9:1" uno --apply --json
cp "$dir/a.orig" "$dir/safe/a.odin"
echo '{}' > "$dir/ols.json"
expect_exit 0 applied-exit "$OLS" query rename "$dir/safe/a.odin:9:1" uno --apply
grep -q "first := uno()" "$dir/safe/a.odin" && grep -q "^uno :: proc" "$dir/safe/a.odin"
odin check "$dir/safe"
echo "ok applied check"
expect check "not an int\|Cannot assign\|cannot" "$OLS" query check "$dir/bad"
expect check-text 'bad.odin:3:10: error:' "$OLS" query check "$dir/bad"
expect check-json '"diagnostic"' "$OLS" query check "$dir/bad" --json
mkdir "$dir/lint"
cat > "$dir/lint/a.odin" <<'ODIN'
package lint

import "core:os"

@(private)
never_called :: proc() {}

BadName :: proc() -> bool {
	x := 1
	x = x
	arr: [2]int = {1, 1}
	_ = arr
	m: map[string][dynamic]int
	for v in m["k"] {
		_ = v
	}
	return x > 0
}

main :: proc() {
	BadName()
}
ODIN
cat > "$dir/lint/b.odin" <<'ODIN'
package lint

helper :: proc() {}
ODIN
for code in unused-declaration self-assignment ignored-result naming Unused array-broadcast range-map-lookup; do
	expect "lint-$code" "\[$code\]" "$OLS" query lint "$dir/lint"
done
expect lint-file self-assignment "$OLS" query lint "$dir/lint/a.odin"
if "$OLS" query lint "$dir/lint" --fail-on range-map-lookup > /dev/null; then echo "FAIL lint-fail-on: exit 0"; exit 1; fi
"$OLS" query lint "$dir/lint" --fail-on no-such-code > /dev/null || { echo "FAIL lint-fail-on-clean"; exit 1; }
echo "ok lint-fail-on"
expect check-lints "\[self-assignment\]" "$OLS" query check "$dir/lint"
mkdir "$dir/t"
cat > "$dir/t/t_test.odin" <<'ODIN'
package t

import "core:testing"

@(test)
passes :: proc(t: ^testing.T) {
	testing.expect_value(t, 1, 1)
}

@(test)
fails :: proc(t: ^testing.T) {
	testing.expect_value(t, 1, 2)
}
ODIN
expect tests "t_test.odin:6:1: passes" "$OLS" query tests "$dir/t"
expect test-one "1 test.* success" sh -c "\"$OLS\" query test \"$dir/t\" passes 2>&1"
if "$OLS" query test "$dir/t" >/dev/null 2>&1; then echo "FAIL test exit code"; exit 1; fi
echo "ok test failure exit"
if "$OLS" query nonsense >/dev/null 2>&1; then echo "FAIL usage exit"; exit 1; fi
echo "ok usage"
echo "all ok"
