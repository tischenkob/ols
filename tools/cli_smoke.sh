#!/usr/bin/env bash
# Smoke test for `ols query`: builds ./ols and runs every subcommand against a temp package.
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh >/dev/null
OLS="$PWD/ols"
export OLS_BUILTIN_FOLDER="$PWD/builtin"

dir="$(mktemp -d)"
trap 'rm -rf "$dir" "$dir.link" "$dir.bare"' EXIT
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

# Like expect, and the command must exit 1, as `check` does when it reports an error.
expect_exit1() {
	local name="$1" pattern="$2" out got=0
	shift 2
	out="$("$@")" || got=$?
	if [[ $got -ne 1 ]] || ! grep -q -- "$pattern" <<<"$out"; then
		echo "FAIL $name: exit $got, expected 1 and $pattern in:" >&2
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
expect move-new "scale.odin" "$OLS" query move "$dir/util.odin:17:1" --to "$dir/scale.odin" --apply
grep -q "^scale :: proc" "$dir/scale.odin" && ! grep -q "^scale :: proc" "$dir/util.odin"
odin check "$dir" -no-entry-point
echo "ok move-new check"
expect move-existing "main.odin" "$OLS" query move "$dir/util.odin:7:1" --to "$dir/main.odin" --apply
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
# An empty outline is an answer: exit 0, and `[]` with --json.
mkdir "$dir/symempty" && printf 'package symempty\n' > "$dir/symempty/e.odin"
expect_exit 0 symbols-empty "$OLS" query symbols "$dir/symempty/e.odin"
expect_exit 0 symbols-empty-json-exit "$OLS" query symbols "$dir/symempty/e.odin" --json
expect symbols-empty-json '^\[\]$' "$OLS" query symbols "$dir/symempty/e.odin" --json
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
# The root is a symlink to the directory of the file: the header stays relative to the root.
ln -s "$dir" "$dir.link"
expect dry-run-header-symlink "^--- a/safe/a.odin$" "$OLS" query --root "$dir.link" rename "$dir/safe/a.odin:9:1" uno
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
expect_exit 1 collision-exit "$OLS" query rename "$dir/safe/a.odin:4:2" second
expect collision-cause "^error: .second. is already declared in the same scope at .*a.odin:5:2" sh -c "\"$OLS\" query rename \"$dir/safe/a.odin:4:2\" second 2>&1 || true"
expect_exit 1 missing-file-exit "$OLS" query rename "$dir/safe/missing.odin:1:1" x
expect missing-file-cause "^error: cannot read .*missing.odin" sh -c "\"$OLS\" query rename \"$dir/safe/missing.odin:1:1\" x 2>&1 || true"
expect missing-file-json '"status": "refused"' sh -c "\"$OLS\" query rename \"$dir/safe/missing.odin:1:1\" x --json || true"
expect past-end-cause "^error: line 999 is past the end of the file" sh -c "\"$OLS\" query rename \"$dir/safe/a.odin:999:1\" x 2>&1 || true"
expect past-end-query "^line 999 is past the end of the file" sh -c "\"$OLS\" query hover \"$dir/safe/a.odin:999:1\" 2>&1 || true"
# a.odin is written first and z.odin is read-only: the rollback restores a.odin and leaves z.odin alone.
printf 'package safe\n\nz :: proc() -> int {\n\treturn one()\n}\n' > "$dir/safe/z.odin"
chmod 444 "$dir/safe/z.odin"
expect write-failure-summary "^rename: refused, nothing written$" sh -c "\"$OLS\" query rename \"$dir/safe/a.odin:9:1\" uno --apply 2>&1 || true"
cmp -s "$dir/safe/a.odin" "$dir/a.orig" || { echo "FAIL write-failure rollback is not byte for byte"; exit 1; }
rm -f "$dir/safe/z.odin"
# The workspace filter skips hidden.odin, which still calls one(): the rename warns, and odin check rolls it back.
printf 'package safe\n\nhidden :: proc() -> int {\n\treturn one()\n}\n' > "$dir/safe/hidden.odin"
echo '{"workspace_exclude": ["safe/hidden.odin"]}' > "$dir/ols.json"
expect skipped-warning "^warning: 1 workspace file skipped .*safe/hidden.odin" sh -c "\"$OLS\" query rename \"$dir/safe/a.odin:9:1\" uno 2>&1"
expect_exit 4 check-failed-exit "$OLS" query rename "$dir/safe/a.odin:9:1" uno --apply
cmp -s "$dir/safe/a.odin" "$dir/a.orig" || { echo "FAIL check-failed rollback is not byte for byte"; exit 1; }
echo "ok check-failed rollback"
expect check-failed-error "^error: .*hidden.odin:4:9: Undeclared name: one" sh -c "\"$OLS\" query rename \"$dir/safe/a.odin:9:1\" uno --apply 2>&1 || true"
expect_exit 0 no-check-exit "$OLS" query rename "$dir/safe/a.odin:9:1" uno --apply --no-check
cp "$dir/a.orig" "$dir/safe/a.odin"
rm "$dir/safe/hidden.odin"
echo '{"odin_command": "/nonexistent/odin"}' > "$dir/ols.json"
expect_exit 1 check-cannot-run-exit "$OLS" query rename "$dir/safe/a.odin:9:1" uno --apply
cmp -s "$dir/safe/a.odin" "$dir/a.orig" || { echo "FAIL check-cannot-run wrote the file"; exit 1; }
echo '{}' > "$dir/ols.json"
# move refuses a new file whose name drops the platform suffix of its source, so this declaration breaks on its
# file name instead: its #assert holds only in v.odin, and odin check rejects it in the created two.odin.
printf 'package safe\n\n// Builds only in a file named v.odin.\ntwo :: proc() -> int {\n\t#assert(len(#file) - len(#directory) == len("v.odin"))\n\treturn 2\n}\n' > "$dir/safe/v.odin"
cp "$dir/safe/v.odin" "$dir/v.orig"
expect_exit 1 created-suffix-refused "$OLS" query move "$dir/safe/v.odin:4:1" --to "$dir/safe/two_js.odin" --apply
expect_exit 4 created-rollback-exit "$OLS" query move "$dir/safe/v.odin:4:1" --to "$dir/safe/two.odin" --apply
[[ ! -e "$dir/safe/two.odin" ]] || { echo "FAIL created-rollback left two.odin"; exit 1; }
cmp -s "$dir/safe/v.odin" "$dir/v.orig" || { echo "FAIL created-rollback is not byte for byte"; exit 1; }
rm "$dir/safe/v.odin"
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
mkdir "$dir/sp"
cat > "$dir/sp/sp.odin" <<'ODIN'
package sp

Thing :: struct {
	field: int,
}

total :: proc(t: Thing) -> int {
	return t.field
}

main :: proc() {
	sum := 0
	t := Thing{field = 2}
	sum += total(t)
	_ = sum
}
ODIN
expect symbol-path-dry-run "^+.new_field: int," sh -c "cd \"$dir\" && \"$OLS\" query rename sp.Thing.field new_field"
expect symbol-path-apply "sp.odin" sh -c "cd \"$dir\" && \"$OLS\" query rename sp.Thing.field new_field --apply"
grep -q "return t.new_field" "$dir/sp/sp.odin" && grep -q "Thing{new_field = 2}" "$dir/sp/sp.odin"
odin check "$dir/sp"
echo "ok symbol-path-apply check"
expect move-symbol-path "^move: " "$OLS" query move "$dir/sp.total" --to "$dir/sp/other.odin"
echo "{\"collections\": [{\"name\": \"shared\", \"path\": \"$dir\"}]}" > "$dir/ols.json"
expect collection-symbol-path "^+total_of :: proc" "$OLS" query --root "$dir" rename shared:sp.total total_of
echo '{}' > "$dir/ols.json"
expect_exit 1 symbol-path-not-found-exit "$OLS" query rename "$dir/sp.Nope" x
expect symbol-path-not-found-cause "^error: no top-level declaration .Nope." sh -c "\"$OLS\" query rename \"$dir/sp.Nope\" x 2>&1 || true"
expect_exit 1 keyword-exit "$OLS" query rename "$dir/sp.total" proc
expect keyword-cause "^error: .proc. is a keyword" sh -c "\"$OLS\" query rename \"$dir/sp.total\" proc 2>&1 || true"
expect_exit 1 capture-exit "$OLS" query rename "$dir/sp.total" sum
expect capture-cause "^error: at .*sp.odin:14:9 .sum. already refers to" sh -c "\"$OLS\" query rename \"$dir/sp.total\" sum 2>&1 || true"
# rename-package: an importer, a nested sub-package that imports its parent, and an aliased importer.
mkdir -p "$dir/pk/app" "$dir/pk/oldpkg/sub"
printf 'package oldpkg\n\nX :: 1\n' > "$dir/pk/oldpkg/a.odin"
printf 'package sub\n\nimport "../../oldpkg"\n\nY :: oldpkg.X\n' > "$dir/pk/oldpkg/sub/s.odin"
cat > "$dir/pk/app/main.odin" <<'ODIN'
package app

import "core:fmt"
import "../oldpkg"
import "../oldpkg/sub"
import o "../oldpkg"

main :: proc() {
	fmt.println(oldpkg.X, sub.Y, o.X)
}
ODIN
expect rename-package-header "^rename from pk/oldpkg$" "$OLS" query rename-package "$dir/pk/oldpkg" newpkg
expect rename-package-diff '^+import "../newpkg/sub"$' "$OLS" query rename-package "$dir/pk/oldpkg" newpkg
expect rename-package-json '"kind": "rename"' "$OLS" query rename-package "$dir/pk/oldpkg" newpkg --json
[[ -d "$dir/pk/oldpkg" && ! -e "$dir/pk/newpkg" ]] || { echo "FAIL rename-package dry run renamed the directory"; exit 1; }
expect_exit 0 rename-package-apply "$OLS" query rename-package "$dir/pk/oldpkg" newpkg --apply
[[ -d "$dir/pk/newpkg/sub" && ! -e "$dir/pk/oldpkg" ]] || { echo "FAIL rename-package-apply did not move the directory"; exit 1; }
grep -q "^package newpkg" "$dir/pk/newpkg/a.odin" && grep -q 'import o "../newpkg"' "$dir/pk/app/main.odin" && grep -q "Y :: newpkg.X" "$dir/pk/newpkg/sub/s.odin" || { echo "FAIL rename-package-apply text"; exit 1; }
odin check "$dir/pk/app"
echo "ok rename-package-apply check"
expect_exit 3 rename-package-noop "$OLS" query rename-package "$dir/pk/newpkg" newpkg
mkdir "$dir/pk/taken"
expect_exit 1 rename-package-sibling-exit "$OLS" query rename-package "$dir/pk/newpkg" taken
expect rename-package-sibling-cause "^error: .*pk/taken already exists" sh -c "\"$OLS\" query rename-package \"$dir/pk/newpkg\" taken 2>&1 || true"
expect_exit 1 rename-package-keyword-exit "$OLS" query rename-package "$dir/pk/newpkg" proc
# An import through a symlink resolves into the package, but no segment of its path names the directory.
ln -s newpkg "$dir/pk/alias"
mkdir "$dir/pk/linked"
printf 'package linked\n\nimport "../alias"\n\nL :: alias.X\n' > "$dir/pk/linked/l.odin"
expect rename-package-symlink "^error: .*linked/l.odin:3:8: cannot rewrite import path \"../alias\"" sh -c "\"$OLS\" query rename-package \"$dir/pk/newpkg\" thirdpkg 2>&1 || true"
# A relative import from inside the package that leaves it and comes back through the symlink would dangle too.
printf 'package newpkg\n\nimport "../alias/sub"\n' > "$dir/pk/newpkg/back.odin"
expect rename-package-symlink-back "^error: .*newpkg/back.odin:3:8: cannot rewrite import path \"../alias/sub\"" sh -c "\"$OLS\" query rename-package \"$dir/pk/newpkg\" thirdpkg 2>&1 || true"
rm -rf "$dir/pk/linked" "$dir/pk/newpkg/back.odin"
# A file that does not parse and reaches the package only through the symlink is left alone with a warning.
mkdir "$dir/pk/broken"
printf 'package broken\n\nimport "../alias"\n\nb :: proc( {\n' > "$dir/pk/broken/b.odin"
expect rename-package-unparsable "^warning: cannot parse .*broken/b.odin, which mentions or imports .newpkg." sh -c "\"$OLS\" query rename-package \"$dir/pk/newpkg\" thirdpkg 2>&1"
rm -rf "$dir/pk/broken" "$dir/pk/alias"
expect rename-package-root "^error: .* is the workspace root" sh -c "\"$OLS\" query rename-package \"$dir\" other 2>&1 || true"
# The workspace filter skips hidden.odin, which still imports ../newpkg: the rename warns, and odin check rolls it back.
printf 'package app\n\nimport "../newpkg"\n\nhidden :: proc() -> int {\n\treturn newpkg.X\n}\n' > "$dir/pk/app/hidden.odin"
echo '{"workspace_exclude": ["pk/app/hidden.odin"]}' > "$dir/ols.json"
cp -R "$dir/pk" "$dir/pk.orig"
expect rename-package-skipped "^warning: 1 workspace file skipped .*pk/app/hidden.odin" sh -c "\"$OLS\" query rename-package \"$dir/pk/newpkg\" thirdpkg 2>&1"
expect_exit 4 rename-package-check-failed "$OLS" query rename-package "$dir/pk/newpkg" thirdpkg --apply
[[ -d "$dir/pk/newpkg" && ! -e "$dir/pk/thirdpkg" ]] || { echo "FAIL rename-package rollback did not rename the directory back"; exit 1; }
diff -r "$dir/pk" "$dir/pk.orig" || { echo "FAIL rename-package rollback is not byte for byte"; exit 1; }
echo "ok rename-package rollback"
rm -rf "$dir/pk.orig"
echo '{}' > "$dir/ols.json"
# attr: add by symbol path, a rename refusal, remove --all, and an unknown key that odin check rolls back.
mkdir "$dir/at"
cat > "$dir/at/at.odin" <<'ODIN'
package at

@(private)
helper :: proc() -> int {
	return 1
}

@private
counter := 0

@(private, rodata)
table := [2]int{1, 2}

main :: proc() {
	when ODIN_OS != .Freestanding {
		@(static) calls: int
		calls += helper() + counter + table[0]
	}
}
ODIN
cp "$dir/at/at.odin" "$dir/at.orig"
expect attr-add-diff '^+@(private, require_results)$' sh -c "cd \"$dir\" && \"$OLS\" query attr add at.helper require_results"
expect attr-add-json '"status": "dry_run"' sh -c "cd \"$dir\" && \"$OLS\" query attr add at.helper require_results --json"
cmp -s "$dir/at/at.odin" "$dir/at.orig" || { echo "FAIL attr dry run wrote the file"; exit 1; }
expect attr-add-apply "^attr add: 1 edit in 1 file written, 1 package checked$" sh -c "cd \"$dir\" && \"$OLS\" query attr add at.helper require_results --apply"
grep -q "^@(private, require_results)$" "$dir/at/at.odin" || { echo "FAIL attr-add-apply text"; exit 1; }
odin check "$dir/at"
echo "ok attr-add-apply check"
expect_exit 1 attr-rename-refused-exit "$OLS" query attr rename private rodata "$dir/at"
expect attr-rename-refused-cause "^error: .*at.odin:11:3: the declaration already has .rodata." sh -c "\"$OLS\" query attr rename private rodata \"$dir/at\" 2>&1 || true"
expect_exit 1 attr-library-exit "$OLS" query --root "$dir" attr add core:fmt.println cold
expect_exit 2 attr-all-usage "$OLS" query attr rename --all private hidden "$dir/at"
expect_exit 2 all-usage "$OLS" query rename --all "$dir/at.counter" total
# The filter skips at/hidden.odin and skipped.odin; with DIR at, the warning names only the first.
printf 'package at\n\n@(private) hidden := 0\n' > "$dir/at/hidden.odin"
printf 'package smoke\n\n@(private) skipped := 0\n' > "$dir/skipped.odin"
echo '{"workspace_exclude": ["at/hidden.odin", "skipped.odin"]}' > "$dir/ols.json"
expect attr-remove-all-skipped '^warning: 1 workspace file skipped .* contains `private`, and attr remove does not change it: .*at/hidden.odin$' sh -c "\"$OLS\" query attr remove --all private \"$dir/at\" 2>&1"
expect attr-remove-all "^attr remove: 3 edits in 1 file written, 1 package checked$" "$OLS" query attr remove --all private "$dir/at" --apply
! grep -q "private" "$dir/at/at.odin" && grep -q "^counter := 0$" "$dir/at/at.odin" && grep -q "^@(rodata)$" "$dir/at/at.odin" || { echo "FAIL attr-remove-all text"; cat "$dir/at/at.odin"; exit 1; }
odin check "$dir/at"
echo "ok attr-remove-all check"
rm "$dir/at/hidden.odin" "$dir/skipped.odin"
echo '{}' > "$dir/ols.json"
expect_exit 3 attr-remove-noop "$OLS" query attr remove "$dir/at.counter" private
cp "$dir/at/at.odin" "$dir/at.orig"
expect_exit 4 attr-check-failed-exit "$OLS" query attr add "$dir/at.counter" foobar --apply
cmp -s "$dir/at/at.odin" "$dir/at.orig" || { echo "FAIL attr check-failed rollback is not byte for byte"; exit 1; }
echo "ok attr check-failed rollback"
expect attr-check-failed-error "^error: .*at.odin:.*Unknown attribute element name 'foobar'" sh -c "\"$OLS\" query attr add \"$dir/at.counter\" foobar --apply 2>&1 || true"
rm "$dir/at.orig"
expect_exit1 check "not an int\|Cannot assign\|cannot" "$OLS" query check "$dir/bad"
expect_exit1 check-text 'bad.odin:3:10: error:' "$OLS" query check "$dir/bad"
expect_exit1 check-json '"diagnostic"' "$OLS" query check "$dir/bad" --json
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
# Several paths: each is linted, in the order given, a shared file once, and --fail-on covers all of them.
mkdir "$dir/lint2" && printf 'package lint2\n\nlower_const :: 1\n' > "$dir/lint2/c.odin"
out="$("$OLS" query lint "$dir/lint2" "$dir/lint" "$dir/lint/a.odin")"
[[ "$(head -1 <<<"$out")" == *lint2/c.odin* ]] || { echo "FAIL lint-multi-order:"; echo "$out"; exit 1; }
[[ "$(grep -c '\[self-assignment\]' <<<"$out")" -eq 1 ]] || { echo "FAIL lint-multi-dedupe:"; echo "$out"; exit 1; }
echo "ok lint-multi"
expect_exit 1 lint-multi-fail-on "$OLS" query lint "$dir/lint2" "$dir/lint" --fail-on range-map-lookup
expect lint-multi-json 'lint2/c.odin"' "$OLS" query lint "$dir/lint" "$dir/lint2" --json
expect_exit 2 symbols-extra-arg "$OLS" query symbols "$dir/lint/a.odin" "$dir/lint/b.odin"
expect_exit 2 def-extra-arg "$OLS" query def "$dir/main.odin:6:11" "$dir/main.odin:6:11"
expect_exit 2 find-extra-arg "$OLS" query find add extra
# A directory covers the packages below it, like modernize; one without a package is an error.
mkdir -p "$dir/lintdeep/sub" "$dir/lintnone/empty"
printf 'package sub\n\nlower_sub :: 1\n' > "$dir/lintdeep/sub/s.odin"
expect lint-recursive "lintdeep/sub/s.odin:3:1: .*\[naming\]" "$OLS" query lint "$dir/lintdeep"
# The walk skips what check skips: hidden directories such as .claude/worktrees copies.
mkdir -p "$dir/lintdeep/.hidden/copy"
printf 'package copy\n\nlower_copy :: 1\n' > "$dir/lintdeep/.hidden/copy/c.odin"
if "$OLS" query lint "$dir/lintdeep" | grep -q "lower_copy"; then echo "FAIL lint-skips-hidden"; exit 1; fi
echo "ok lint-skips-hidden"
# check DIR DIR reports each lint once.
[[ "$("$OLS" query check "$dir/lint" "$dir/lint" | grep -c '\[self-assignment\]')" -eq 1 ]] || { echo "FAIL check-twice-once"; exit 1; }
echo "ok check-twice-once"
expect_exit 1 lint-no-package "$OLS" query lint "$dir/lintnone"
# lint and check filter the files of a kept directory too; a file named on the command line is linted.
if command -v git >/dev/null; then
	mkdir -p "$dir/lintgi/sub"
	printf 'package sub

lower_kept :: 1
' > "$dir/lintgi/sub/kept.odin"
	printf 'package sub

lower_ignored :: 1
' > "$dir/lintgi/sub/ignored.odin"
	echo 'lintgi/sub/ignored.odin' >> "$dir/.gitignore"
	out="$("$OLS" query lint "$dir/lintgi")"
	[[ "$out" == *lower_kept* && "$out" != *lower_ignored* ]] || { echo "FAIL lint-gitignored-file: $out"; exit 1; }
	echo "ok lint-gitignored-file"
	out="$("$OLS" query check "$dir/lintgi/sub")"
	[[ "$out" == *lower_kept* && "$out" != *lower_ignored* ]] || { echo "FAIL check-gitignored-file: $out"; exit 1; }
	echo "ok check-gitignored-file"
	expect lint-named-gitignored-file "lower_ignored" "$OLS" query lint "$dir/lintgi/sub/ignored.odin"
	sed -i.bak '/lintgi/d' "$dir/.gitignore" && rm -f "$dir/.gitignore.bak"
	rm -rf "$dir/lintgi"
fi
# lint notes a file that does not parse on stderr and keeps its exit code.
mkdir "$dir/lintbroken"
printf 'package lintbroken

lower_ok :: 1
' > "$dir/lintbroken/ok.odin"
printf 'package lintbroken

f :: proc( {
' > "$dir/lintbroken/broken.odin"
expect lint-unparsed-note "broken.odin: skipped, the file does not parse$" sh -c "\"$OLS\" query lint \"$dir/lintbroken\" 2>&1 >/dev/null"
expect_exit 0 lint-unparsed-exit "$OLS" query lint "$dir/lintbroken"
rm -rf "$dir/lintbroken"
# The indexer's log lines, such as a file of an imported package that does not parse, stay off stderr.
mkdir -p "$dir/logq/z" "$dir/logq/use"
printf 'x := 1\n' > "$dir/logq/z/bad.odin"
printf 'package use\n\nimport "../z"\n\nmain :: proc() {\n\t_ = z.x\n}\n' > "$dir/logq/use/u.odin"
if "$OLS" query lint "$dir/logq/use" 2>&1 >/dev/null | grep -q '\[ERROR\]'; then echo "FAIL cli-no-index-log"; exit 1; fi
echo "ok cli-no-index-log"
# The CLI still reports a missing builtin folder: a copy of the binary has no builtin/ beside it.
mkdir "$dir/nobuiltin" && cp "$OLS" "$dir/nobuiltin/ols"
expect missing-builtin "Failed to find the builtin folder" sh -c "OLS_BUILTIN_FOLDER=\"$dir/no-such-dir\" \"$dir/nobuiltin/ols\" query symbols \"$dir/main.odin\" 2>&1 || true"
expect check-multi "\[naming\]" "$OLS" query check "$dir/lint" "$dir/lint2"
expect check-lints "\[self-assignment\]" "$OLS" query check "$dir/lint"
mdir="$dir/mod"
mkdir "$mdir"
echo '{}' > "$mdir/ols.json"
cat > "$mdir/m.odin" <<'ODIN'
package mod

import "core:fmt"

has :: proc(s: []int, x: int) -> bool {
	for e in s {
		if e == x {
			return true
		}
	}
	return false
}

main :: proc() {
	xs := []int{1, 2}
	for i := 0; i < len(xs); i += 1 {
		fmt.println(xs[i], has(xs, 1))
	}
}
ODIN
expect modernize-list "^use-stdlib/contains	idiom	default" "$OLS" query modernize --list
rc=0
"$OLS" query modernize "$mdir" --rule no-such-rule >/dev/null 2>&1 || rc=$?
[[ $rc == 2 ]] || { echo "FAIL modernize unknown rule: exit $rc"; exit 1; }
echo "ok modernize-unknown-rule"
if command -v git >/dev/null; then
	git -C "$mdir" init -q
	echo 'gen/' > "$mdir/.gitignore"
	mkdir "$mdir/gen"
	sed 's/^package mod/package gen/; /^main ::/,$d' "$mdir/m.odin" > "$mdir/gen/gen.odin"
fi
# A hidden directory, such as a snapshot fixture folder, is skipped as lint skips it.
mkdir "$mdir/.snap"
sed 's/^package mod/package snap/; /^main ::/,$d' "$mdir/m.odin" > "$mdir/.snap/snap.odin"
rc=0
"$OLS" query modernize "$mdir" > "$dir/modernize.out" || rc=$?
[[ $rc == 0 ]] || { echo "FAIL modernize dry-run: exit $rc"; exit 1; }
grep -q "m.odin:6:2: \[use-stdlib/contains\] Replace with slice.contains" "$dir/modernize.out" || { echo "FAIL modernize dry-run:"; cat "$dir/modernize.out"; exit 1; }
echo "ok modernize dry-run"
expect modernize-diff "^+++ b/m.odin" "$OLS" query modernize "$mdir" --diff
# The summary counts the fixes the list prints, not the one whole-file edit per file.
fixes=$(grep -c "^/.*: \[" "$dir/modernize.out")
[[ $fixes -gt 1 ]] || { echo "FAIL modernize-diff-count: $fixes fixes"; exit 1; }
expect modernize-diff-count "^modernize: $fixes edits in 1 file$" "$OLS" query modernize "$mdir" --diff
expect modernize-apply "^modernize: .* written" "$OLS" query --root "$mdir" modernize --apply
grep -q "return slice.contains(s, x)" "$mdir/m.odin" && grep -q '^import "core:slice"' "$mdir/m.odin" && grep -q "for i in 0 ..< len(xs)" "$mdir/m.odin" || { echo "FAIL modernize-apply"; exit 1; }
odin check "$mdir" -no-entry-point
echo "ok modernize-apply check"
if [[ -d "$mdir/gen" ]]; then
	grep -q "for e in s" "$mdir/gen/gen.odin" && ! grep -q "gen.odin" "$dir/modernize.out" || { echo "FAIL modernize touched a gitignored file"; exit 1; }
	echo "ok modernize-gitignored"
fi
grep -q "for e in s" "$mdir/.snap/snap.odin" && ! grep -q "snap.odin" "$dir/modernize.out" || { echo "FAIL modernize touched a hidden directory"; exit 1; }
echo "ok modernize-hidden"
rc=0
"$OLS" query --root "$mdir" modernize > /dev/null || rc=$?
[[ $rc == 3 ]] || { echo "FAIL modernize not clean after apply: exit $rc"; exit 1; }
echo "ok modernize-clean"
mkdir "$dir/mig"
cat > "$dir/mig/m.odin" <<'ODIN'
package mig

import "core:runtime"

main :: proc() {
	_ = runtime.Allocator{}
}
ODIN
expect modernize-migration "^modernize: .* written" "$OLS" query --root "$dir/mig" modernize --rule migration --apply
grep -q '^import "base:runtime"' "$dir/mig/m.odin" || { echo "FAIL modernize-migration"; cat "$dir/mig/m.odin"; exit 1; }
odin check "$dir/mig"
echo "ok modernize-migration check"
mkdir "$dir/rec"
cat > "$dir/rec/ols.json" <<'JSON'
{"modernize_recipes": [
	{"name": "is-empty", "match": "len($s) == 0", "replace": "slice.is_empty($s)", "imports": ["core:slice"], "where": [{"var": "s", "kind": "slice"}]},
	{"name": "broken", "match": "f($x)", "replace": "g($y)"}
]}
JSON
cat > "$dir/rec/m.odin" <<'ODIN'
package rec

import "core:fmt"

main :: proc() {
	xs := []int{1}
	d: [dynamic]int
	fmt.println(len(xs) == 0, len(d) == 0)
}
ODIN
expect modernize-recipe-list "^recipe/is-empty	recipe	default" "$OLS" query --root "$dir/rec" modernize --list
"$OLS" query --root "$dir/rec" modernize --rule recipe --apply > "$dir/recipe.out" 2> "$dir/recipe.err" || { echo "FAIL modernize-recipe"; cat "$dir/recipe.out" "$dir/recipe.err"; exit 1; }
grep -q "recipe broken: replace uses \$y, which match does not bind; skipped" "$dir/recipe.err" || { echo "FAIL modernize-recipe error:"; cat "$dir/recipe.err"; exit 1; }
grep -q "fmt.println(slice.is_empty(xs), len(d) == 0)" "$dir/rec/m.odin" && grep -q '^import "core:slice"' "$dir/rec/m.odin" || { echo "FAIL modernize-recipe"; cat "$dir/rec/m.odin"; exit 1; }
odin check "$dir/rec"
echo "ok modernize-recipe check"
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
[[ "$("$OLS" query tests "$dir/t" "$dir/t/t_test.odin" | grep -c ': passes$')" -eq 1 ]] || { echo "FAIL tests-overlap-once"; exit 1; }
echo "ok tests-overlap-once"
expect test-one "1 test.* success" sh -c "\"$OLS\" query test \"$dir/t\" passes 2>&1"
if "$OLS" query test "$dir/t" >/dev/null 2>&1; then echo "FAIL test exit code"; exit 1; fi
echo "ok test failure exit"
if "$OLS" query nonsense >/dev/null 2>&1; then echo "FAIL usage exit"; exit 1; fi
echo "ok usage"
# --help with any command prints the usage on stdout and exits 0, instead of reading --help as a path.
expect modernize-help "^usage: ols query" "$OLS" query modernize --help
expect lint-help "^usage: ols query" "$OLS" query lint -h
expect help-alone "^usage: ols query" "$OLS" query --help
# Compile gate: an unedited importer is checked, existing errors warn, and an existing error that names
# the renamed symbol or package is not new.
mkdir -p "$dir/imp/lib" "$dir/imp/use"
printf 'package lib\n\nL :: proc() -> int {\n\treturn 1\n}\n' > "$dir/imp/lib/lib.odin"
printf 'package use\n\nimport "../lib"\n\nmain :: proc() {\n\t_ = lib.L()\n}\n' > "$dir/imp/use/use.odin"
cp "$dir/imp/lib/lib.odin" "$dir/lib.orig"
expect_exit 4 importer-check-failed "$OLS" query attr add "$dir/imp/lib.L" private --apply
cmp -s "$dir/imp/lib/lib.odin" "$dir/lib.orig" || { echo "FAIL importer rollback is not byte for byte"; exit 1; }
echo "ok importer rollback"
expect importer-error "^error: .*use.odin:6:6: 'L' is not exported by 'lib'" sh -c "\"$OLS\" query attr add \"$dir/imp/lib.L\" private --apply 2>&1 || true"
expect importer-rolled-back "^attr add: 1 edit in 1 file rolled back, odin check reports new errors, 2 packages checked$" sh -c "\"$OLS\" query attr add \"$dir/imp/lib.L\" private --apply 2>&1 || true"
# --json keeps the summary count and the warning in reasons; the apply here is rolled back.
printf 'package use\n\nimport "../lib"\n\nmain :: proc() {\n\t_ = lib.L()\n}\n\nbad: int = "s"\n' > "$dir/imp/use/use.odin"
expect importer-json-summary '"summary": "attr add: 1 edit in 1 file rolled back, odin check reports new errors, 2 packages checked"' sh -c "\"$OLS\" query attr add \"$dir/imp/lib.L\" private --apply --json || true"
expect importer-json-warning '"odin check already reports errors in imp/use;' sh -c "\"$OLS\" query attr add \"$dir/imp/lib.L\" private --apply --json || true"
printf 'package use\n\nimport "../lib"\n\nmain :: proc() {\n\t_ = lib.L()\n}\n' > "$dir/imp/use/use.odin"
expect importer-checked "^attr add: 1 edit in 1 file written, 2 packages checked$" "$OLS" query attr add "$dir/imp/lib.L" cold --apply
rm -rf "$dir/imp" "$dir/lib.orig"
# The gate follows importers of importers: a imports b, b re-exports c.f, and require_results on c.f
# breaks the call in a only.
mkdir -p "$dir/tr/a" "$dir/tr/b" "$dir/tr/c"
printf 'package c\n\nf :: proc() -> int {\n\treturn 1\n}\n' > "$dir/tr/c/c.odin"
printf 'package b\n\nimport "../c"\n\nf :: c.f\n' > "$dir/tr/b/b.odin"
printf 'package a\n\nimport "../b"\n\nmain :: proc() {\n\tb.f()\n}\n' > "$dir/tr/a/a.odin"
cp "$dir/tr/c/c.odin" "$dir/tr.orig"
expect_exit 4 transitive-importer-rolled-back "$OLS" query attr add "$dir/tr/c.f" require_results --apply
cmp -s "$dir/tr/c/c.odin" "$dir/tr.orig" || { echo "FAIL transitive rollback is not byte for byte"; exit 1; }
expect transitive-importer-error "^error: .*a.odin:6:2: 'b.f' requires that its results must be handled" sh -c "\"$OLS\" query attr add \"$dir/tr/c.f\" require_results --apply 2>&1 || true"
rm -rf "$dir/tr" "$dir/tr.orig"
# A touched file that the host does not build is checked for a target it builds on: require_results on
# W breaks the discarded call in the same windows-only file. An importer that has no file for the host is
# checked on the host without a refusal, and for windows through its own file.
if [[ "$(uname -s)" != MINGW* && "$(uname -s)" != MSYS* ]]; then
	mkdir -p "$dir/tg/plat" "$dir/tg/use"
	printf 'package plat\n\nimport "core:sys/windows"\n\nW :: proc() -> int {\n\treturn 1\n}\n\nuse_w :: proc() {\n\t_ = windows.GetLastError()\n\tW()\n}\n' > "$dir/tg/plat/plat_windows.odin"
	cp "$dir/tg/plat/plat_windows.odin" "$dir/tg.orig"
	expect_exit 4 other-target-rolled-back "$OLS" query attr add "$dir/tg/plat/plat_windows.odin:5:1" require_results --apply
	cmp -s "$dir/tg/plat/plat_windows.odin" "$dir/tg.orig" || { echo "FAIL target rollback is not byte for byte"; exit 1; }
	echo '{"checker_targets": ["linux_amd64"]}' > "$dir/ols.json"
	expect_exit 4 explicit-target-adds-to-the-needed-ones "$OLS" query attr add "$dir/tg/plat/plat_windows.odin:5:1" require_results --apply
	echo '{}' > "$dir/ols.json"
	rm -rf "$dir/tg" "$dir/tg.orig"
	mkdir -p "$dir/ig/lib" "$dir/ig/use"
	printf 'package lib\n\nL :: proc() -> int {\n\treturn 1\n}\n' > "$dir/ig/lib/lib.odin"
	printf '#+build windows\npackage use\n\nimport "../lib"\n\nmain :: proc() {\n\t_ = lib.L()\n}\n' > "$dir/ig/use/use_win.odin"
	expect importer-without-a-host-file-is-checked "^attr add: 1 edit in 1 file written, 2 packages checked, also on windows_amd64$" "$OLS" query attr add "$dir/ig/lib.L" cold --apply
	expect_exit 4 importer-without-a-host-file-rolled-back "$OLS" query attr add "$dir/ig/lib.L" private --apply
	rm -rf "$dir/ig"
	# An importer whose js_wasm32 check fails in core (core:os panics there) does not build on that target,
	# so the gate skips it there with a warning. An importer that builds on js_wasm32 keeps its gate.
	mkdir -p "$dir/jw/wl" "$dir/jw/nat" "$dir/jw/web"
	printf 'package wl\n\nH :: proc() -> int {\n\treturn 1\n}\n' > "$dir/jw/wl/wl.odin"
	printf 'package wl\n\nJ :: proc() -> int {\n\treturn 2\n}\n' > "$dir/jw/wl/wl_js.odin"
	printf 'package nat\n\nimport "core:os"\nimport "../wl"\n\nmain :: proc() {\n\t_ = wl.H()\n\t_, _ = os.read_entire_file("x", context.allocator)\n}\n' > "$dir/jw/nat/nat.odin"
	printf 'package web\n\nimport "../wl"\n\nmain :: proc() {\n\t_ = wl.J()\n}\n' > "$dir/jw/web/web_js.odin"
	expect native-importer-skipped-on-js "^warning: jw/nat does not build on target js_wasm32: odin check there reports errors in .*, outside the workspace" sh -c "\"$OLS\" query attr add \"$dir/jw/wl/wl_js.odin:3:1\" cold --apply 2>&1"
	expect_exit 4 js-importer-keeps-its-gate "$OLS" query attr add "$dir/jw/wl/wl_js.odin:4:1" private --apply
	rm -rf "$dir/jw"
fi
mkdir "$dir/pre"
printf 'package pre\n\nx: int = "s"\n\nhelper :: proc() -> int {\n\treturn 1\n}\n' > "$dir/pre/pre.odin"
expect_exit 0 existing-errors-exit "$OLS" query rename "$dir/pre.helper" helper2 --apply
expect existing-errors-warning "^warning: odin check already reports errors in pre;" sh -c "\"$OLS\" query rename \"$dir/pre.helper2\" helper3 --apply 2>&1"
rm -rf "$dir/pre"
mkdir "$dir/fr"
printf 'package fr\n\ncount :: proc() -> int {\n\treturn 1\n}\n\nmain :: proc() {\n\ts: string = count()\n\t_ = s\n}\n' > "$dir/fr/fr.odin"
expect_exit 0 existing-error-renamed "$OLS" query rename "$dir/fr.count" tally --apply
grep -q "s: string = tally()" "$dir/fr/fr.odin" || { echo "FAIL existing-error-renamed text"; exit 1; }
rm -rf "$dir/fr"
mkdir -p "$dir/rp/rpold" "$dir/rp/user"
printf 'package rpold\n\nP :: proc() -> int {\n\treturn 1\n}\n' > "$dir/rp/rpold/p.odin"
printf 'package user\n\nimport "../rpold"\n\nmain :: proc() {\n\ts: string = rpold.P()\n\t_ = s\n}\n' > "$dir/rp/user/u.odin"
expect_exit 0 existing-error-package-renamed "$OLS" query rename-package "$dir/rp/rpold" rpnew --apply
[[ -d "$dir/rp/rpnew" ]] && grep -q "s: string = rpnew.P()" "$dir/rp/user/u.odin" || { echo "FAIL existing-error-package-renamed text"; exit 1; }
rm -rf "$dir/rp"
# Compile gate and checker command line. A repeated flag in checker_args no longer blanks the diagnostics,
# a check that cannot run exits 1, the gate checks without the style vets, and the gate asks odin for
# every error, so the set does not change between runs.
mkdir "$dir/dupe"
printf 'package dupe\n\nf :: proc() {\n\tx: int = "s"\n\t_ = x\n}\n' > "$dir/dupe/d.odin"
echo '{"checker_args": "-no-entry-point"}' > "$dir/ols.json"
expect_exit1 dupe-flag-reports-the-error "d.odin:4:11: error: Cannot convert" "$OLS" query check "$dir/dupe"
# The skip list also holds each path with symlinks resolved, since the CLI resolves its paths (/var on macOS).
echo '{"checker_skip_packages": ["'"$dir/dupe"'"]}' > "$dir/ols.json"
expect_exit 0 check-skipped-package "$OLS" query check "$dir/dupe"
echo '{"odin_command": "/nonexistent/odin"}' > "$dir/ols.json"
expect_exit 1 check-without-odin "$OLS" query check "$dir/dupe"
expect check-without-odin-message "^error: \`odin check\` could not start" sh -c "\"$OLS\" query check \"$dir/dupe\" 2>&1 || true"
echo '{}' > "$dir/ols.json"
rm -rf "$dir/dupe"
mkdir -p "$dir/vs/lib" "$dir/vs/use"
printf 'package lib\n\nT :: struct {\n\ta, b: int\n}\n\nL :: proc() -> int {\n\treturn 1\n}\n' > "$dir/vs/lib/lib.odin"
printf 'package use\n\nimport "../lib"\n\nmain :: proc() {\n\t_ = lib.L()\n}\n' > "$dir/vs/use/use.odin"
expect_exit 4 gate-sees-past-a-style-syntax-error "$OLS" query attr add "$dir/vs/lib.L" private --apply
rm -rf "$dir/vs"
mkdir "$dir/many"
{
	printf 'package many\n\nf :: proc(x: int) {\n\tif (x > 0) {}\n}\n'
	for i in $(seq 1 60); do printf 'g_%d :: proc() { missing_%d() }\n' "$i" "$i"; done
} > "$dir/many/many.odin"
cp "$dir/many/many.odin" "$dir/many.orig"
for run in 1 2 3 4 5; do
	cp "$dir/many.orig" "$dir/many/many.odin"
	expect_exit 0 "gate-stable-over-the-error-limit-$run" "$OLS" query modernize "$dir/many" --apply
done
rm -rf "$dir/many" "$dir/many.orig"
# A missing trailing comma is a Syntax Error under -vet-style and hides every type error of the package,
# so the check reruns without the style flags and keeps the comma as a warning.
mkdir "$dir/sty"
printf 'package sty\n\nS :: struct {\n\ta: int,\n}\n\nf :: proc() {\n\ts := S{\n\t\ta = 1\n\t}\n\tx: int = "s"\n\t_, _ = s, x\n}\n' > "$dir/sty/s.odin"
expect_exit1 style-syntax-error-is-a-warning "s.odin:9:7: warning: Syntax Error: Expected a comma" "$OLS" query check "$dir/sty"
expect_exit1 style-rerun-reports-the-type-error "s.odin:11:11: error: Cannot convert" "$OLS" query check "$dir/sty"
rm -rf "$dir/sty"
# A quoted checker_args value keeps its space.
mkdir -p "$dir/sp/my lib/lib" "$dir/sp/use"
printf 'package lib\n\nV :: 3\n' > "$dir/sp/my lib/lib/l.odin"
printf 'package use\n\nimport "x:lib"\n\nf :: proc() -> int {\n\treturn lib.V\n}\n' > "$dir/sp/use/u.odin"
echo '{"checker_args": "-collection:x=\"'"$dir"'/sp/my lib\""}' > "$dir/ols.json"
out="$("$OLS" query check "$dir/sp/use" 2>&1 || true)"
if grep -q "error" <<<"$out"; then
	echo "FAIL checker-args-quoted-space:" >&2
	echo "$out" >&2
	exit 1
fi
echo "ok checker-args-quoted-space"
rm -rf "$dir/sp"
echo '{}' > "$dir/ols.json"

# Path arguments, the workspace root and the commands without an argument.
mkdir -p "$dir/cli/pkg" "$dir/cli/other"
echo '{}' > "$dir/cli/ols.json"
printf 'package pkg\n\nhelper :: proc() {}\n\nuse_a :: proc() { helper() }\n\nOne :: struct {\n\tx: int,\n}\n\nzed :: proc() {}\n\nalpha :: proc() {}\n' > "$dir/cli/pkg/a.odin"
printf 'package pkg\n\nuse_b :: proc() { helper() }\n' > "$dir/cli/pkg/b.odin"
printf 'package other\n\nimport "core:testing"\n\n@(test)\nnamed :: proc(t: ^testing.T) {}\n\nx: int = "s"\n' > "$dir/cli/other/o_test.odin"
# A relative --root is made absolute: the search still reaches b.odin.
expect refs-relative-root "b.odin:3:" sh -c "cd \"$dir/cli/pkg\" && \"$OLS\" query refs a.odin:3:1 --root ."
expect_exit 0 rename-relative-root sh -c "cd \"$dir/cli/pkg\" && \"$OLS\" query rename a.odin:3:1 helper2 --root . --apply --no-check"
grep -q "helper2()" "$dir/cli/pkg/b.odin" || { echo "FAIL rename-relative-root did not reach b.odin"; exit 1; }
sh -c "cd \"$dir/cli/pkg\" && \"$OLS\" query rename a.odin:3:1 helper --root . --apply --no-check" >/dev/null
# move --to is relative to the cwd, like every other path; an absolute path may go through a symlink.
expect move-to-relative-to-cwd "^+++ b/pkg/c.odin" sh -c "cd \"$dir/cli\" && \"$OLS\" query move pkg/a.odin:3:1 --to pkg/c.odin"
expect move-to-in-cwd "^+++ b/pkg/c.odin" sh -c "cd \"$dir/cli/pkg\" && \"$OLS\" query move a.odin:3:1 --to c.odin"
expect_exit 1 move-to-relative-to-declaration-is-gone sh -c "cd \"$dir/cli\" && \"$OLS\" query move pkg/a.odin:3:1 --to c.odin"
expect move-to-symlink "^+++ b/pkg/c.odin" "$OLS" query --root "$dir/cli" move "$dir/cli/pkg/a.odin:3:1" --to "$dir.link/cli/pkg/c.odin"
# symbols: FILE:LINE:COL: KIND NAME, by position, the same on every run.
sym_expected=$'a.odin:3:1: Function helper\na.odin:5:1: Function use_a\na.odin:7:1: Struct One\na.odin:8:2:   Field x\na.odin:11:1: Function zed\na.odin:13:1: Function alpha'
for run in 1 2 3; do
	got="$("$OLS" query symbols "$dir/cli/pkg/a.odin" | sed 's|^[^ ]*/a.odin:|a.odin:|')"
	[[ "$got" == "$sym_expected" ]] || { echo "FAIL symbols-order run $run:" >&2; echo "$got" >&2; exit 1; }
done
echo "ok symbols-order"
# A symbol path may name the package in the cwd.
expect symbol-path-cwd-dot "^+helper3 :: proc" sh -c "cd \"$dir/cli/pkg\" && \"$OLS\" query rename .helper helper3"
expect symbol-path-cwd-dot-slash "^+helper3 :: proc" sh -c "cd \"$dir/cli/pkg\" && \"$OLS\" query rename ./helper helper3"
expect symbol-path-cwd-member "^+[[:space:]]y: int," sh -c "cd \"$dir/cli/pkg\" && \"$OLS\" query rename ./One.x y"
# actions --apply on a file that cannot be read is a refusal with a summary, and a JSON object under --json.
expect actions-apply-missing-file "^actions: refused, nothing written$" sh -c "\"$OLS\" query actions \"$dir/cli/missing.odin:1:1\" --apply T 2>&1 || true"
expect actions-apply-missing-file-json '"status": "refused"' sh -c "\"$OLS\" query actions \"$dir/cli/missing.odin:1:1\" --apply T --json || true"
expect_exit 1 actions-apply-missing-file-exit "$OLS" query actions "$dir/cli/missing.odin:1:1" --apply T
# check and tests without an argument cover every package below the root; check exits 1 on an error.
expect tests-root "other/o_test.odin:6:1: named" sh -c "cd \"$dir/cli\" && \"$OLS\" query tests"
expect_exit1 check-root "other/o_test.odin:8:10: error:" sh -c "cd \"$dir/cli\" && \"$OLS\" query check"
mkdir "$dir/cli/empty"
expect_exit 1 check-empty-dir "$OLS" query check "$dir/cli/empty"
expect check-empty-dir-message "^error: no package in .*cli/empty$" sh -c "\"$OLS\" query check \"$dir/cli/empty\" 2>&1 || true"
expect check-empty-dir-message-tests "^error: no package in .*cli/empty$" sh -c "\"$OLS\" query tests \"$dir/cli/empty\" 2>&1 || true"
mkdir "$dir/cli/none"
echo '{}' > "$dir/cli/none/ols.json"
expect check-no-package-message "^error: no package in .*cli/none$" sh -c "cd \"$dir/cli/none\" && \"$OLS\" query check 2>&1 || true"
# In a directory with .odin files they cover that package alone; with no ols.json and no package it is an error.
out="$(cd "$dir/cli/pkg" && "$OLS" query check 2>&1 || true)"
[[ "$out" != *o_test* ]] || { echo "FAIL check-cwd-package-only: $out"; exit 1; }
echo "ok check-cwd-package-only"
expect_exit 0 check-cwd-package-exit sh -c "cd \"$dir/cli/pkg\" && \"$OLS\" query check"
expect tests-cwd-package "o_test.odin:6:1: named" sh -c "cd \"$dir/cli/other\" && \"$OLS\" query tests"
mkdir "$dir.bare"
expect_exit 1 check-no-ols-json sh -c "cd \"$dir.bare\" && \"$OLS\" query check"
expect check-no-ols-json-message "^error: no package in .*\.bare$" sh -c "cd \"$dir.bare\" && \"$OLS\" query check 2>&1 || true"
rmdir "$dir.bare"
expect_exit 1 tests-no-package sh -c "cd \"$dir/cli/none\" && \"$OLS\" query tests"
expect_exit 0 check-clean-exit "$OLS" query check "$dir/cli/pkg"
# test DIR NAME names a test that exists.
expect_exit 1 test-unknown-name "$OLS" query test "$dir/cli/other" nope
expect test-unknown-name-message '^error: no test "nope" in ' sh -c "\"$OLS\" query test \"$dir/cli/other\" nope 2>&1 || true"
# tests lists what odin test builds on this host, so a file of another target and #+build ignore are left out.
mkdir "$dir/cli/plat"
printf 'package plat\n\nimport "core:testing"\n\n@(test)\nhost_one :: proc(t: ^testing.T) {}\n' > "$dir/cli/plat/a_test.odin"
printf 'package plat\n\nimport "core:testing"\n\n@(test)\nother_one :: proc(t: ^testing.T) {}\n' > "$dir/cli/plat/b_windows.odin"
printf '#+build ignore\npackage plat\n\nimport "core:testing"\n\n@(test)\nignored_one :: proc(t: ^testing.T) {}\n' > "$dir/cli/plat/c_test.odin"
if [[ "$(uname -s)" != MINGW* && "$(uname -s)" != MSYS* ]]; then
	tests_out="$("$OLS" query tests "$dir/cli/plat")"
	[[ "$tests_out" == *host_one* && "$tests_out" != *other_one* && "$tests_out" != *ignored_one* ]] || { echo "FAIL tests-build-rules: $tests_out"; exit 1; }
	echo "ok tests-build-rules"
fi
# find reports private declarations and those of other targets, and marks them.
printf 'package plat\n\n@(private)\nmarker_secret :: proc() {}\nmarker_open :: proc() {}\n' > "$dir/cli/plat/d.odin"
printf 'package plat\n\nmarker_other :: proc() {}\n' > "$dir/cli/plat/e_js.odin"
mkdir "$dir/cli/.hid"
printf 'package hid\n\nmarker_hidden :: proc() {}\n' > "$dir/cli/.hid/h.odin"
expect find-private "d.odin:4:1: Function marker_secret (private)$" "$OLS" query --root "$dir/cli" find marker
expect find-public "d.odin:5:1: Function marker_open$" "$OLS" query --root "$dir/cli" find marker
expect find-other-platform "e_js.odin:3:1: Function marker_other (other platform)$" "$OLS" query --root "$dir/cli" find marker
out="$("$OLS" query --root "$dir/cli" find marker_hidden || true)"
[[ -z "$out" ]] || { echo "FAIL find-hidden-dir: $out"; exit 1; }
echo "ok find-hidden-dir"
expect find-json-flags '"otherPlatform": true' "$OLS" query --root "$dir/cli" find marker_other --json
# find marks a declaration in a when branch the target does not take; an unknown condition marks nothing.
printf 'package plat

import "core:testing"

when ODIN_OS == .JS {
	marker_when_js :: proc() {}
	@(test)
	js_only :: proc(t: ^testing.T) {}
} else {
	marker_when_else :: proc() {}
}

when ODIN_TEST {
	marker_when_test :: proc() {}
	@(test)
	in_test :: proc(t: ^testing.T) {}
}
' > "$dir/cli/plat/h_test.odin"
expect find-when-inactive "h_test.odin:6:2: Function marker_when_js (other platform)$" "$OLS" query --root "$dir/cli" find marker_when
expect find-when-active "h_test.odin:10:2: Function marker_when_else$" "$OLS" query --root "$dir/cli" find marker_when
expect find-when-unknown "h_test.odin:14:2: Function marker_when_test$" "$OLS" query --root "$dir/cli" find marker_when
out="$("$OLS" query tests "$dir/cli/plat")"
[[ "$out" == *in_test* && "$out" != *js_only* ]] || { echo "FAIL tests-when: $out"; exit 1; }
echo "ok tests-when"
expect test-when-inactive-name '^error: no test "js_only" in ' sh -c "\"$OLS\" query test \"$dir/cli/plat\" js_only 2>&1 || true"
rm "$dir/cli/plat/h_test.odin"
# reorder-params names the one cause that applies.
printf 'package plat\n\nvariadic :: proc(a: int, b: ..int) {}\n\nwith_default :: proc(a: int, b: int = 1) {}\n' > "$dir/cli/plat/f.odin"
expect reorder-params-variadic "^error: the procedure is variadic$" sh -c "\"$OLS\" query reorder-params \"$dir/cli/plat/f.odin:3:1\" --order 1,0 2>&1 || true"
expect reorder-params-default "^error: a parameter has a default value$" sh -c "\"$OLS\" query reorder-params \"$dir/cli/plat/f.odin:5:1\" --order 1,0 2>&1 || true"
# An enum member used as `.B` in a literal that is assigned to `_` or passed to a call is a reference.
printf 'package plat\n\nKind :: enum { A, B }\nItem :: struct { kind: Kind }\ntake :: proc(it: Item) -> Kind { return it.kind }\nmain :: proc() {\n\t_ = take(Item{kind = .B})\n\t_ = Item{kind = .B}\n}\n' > "$dir/cli/plat/g.odin"
expect refs-enum-in-comp-lit-call "g.odin:7:" "$OLS" query refs "$dir/cli/plat/g.odin:3:19"
expect refs-enum-in-comp-lit-blank "g.odin:8:" "$OLS" query refs "$dir/cli/plat/g.odin:3:19"
# rename changes every platform variant of a declaration, read from the files on disk, from either variant.
mkdir "$dir/cli/variants"
printf '#+build !windows\npackage variants\n\nf :: proc() -> int { return 1 }\n' > "$dir/cli/variants/v_host.odin"
printf 'package variants\n\nf :: proc() -> int { return 2 }\n\ntwice :: proc() -> int { return 2 * f() }\n' > "$dir/cli/variants/v_windows.odin"
printf 'package variants\n\ng :: proc() -> int { return f() }\n' > "$dir/cli/variants/use.odin"
expect rename-variant-excluded '^+++ b/.*v_windows.odin' "$OLS" query rename "$dir/cli/variants/v_host.odin:4:1" h
expect rename-variant-host '^+++ b/.*v_host.odin' "$OLS" query rename "$dir/cli/variants/v_windows.odin:3:1" h
expect rename-variant-summary '^rename: 4 edits in 3 files$' "$OLS" query rename "$dir/cli/variants/v_windows.odin:3:1" h
rm -rf "$dir/cli"
echo "all ok"
