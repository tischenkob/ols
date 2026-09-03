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
}
ODIN
cat > "$dir/util.odin" <<'ODIN'
package smoke

add :: proc(a, b: int) -> int {
	return a + b
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
expect refs "main.odin" "$OLS" query refs "$dir/util.odin:3:1"
expect hover "add" "$OLS" query hover "$dir/main.odin:6:11"
expect symbols '"main"' "$OLS" query symbols "$dir/main.odin"
expect actions "Invert if" "$OLS" query actions "$dir/main.odin:7:2"
expect actions-apply "main.odin" "$OLS" query actions "$dir/main.odin:10:11-10:20" --apply "Extract variable"
grep -q "value \* 3" "$dir/main.odin" && grep -q "total := .* + 1" "$dir/main.odin"
odin check "$dir" -no-entry-point
echo "ok actions-apply check"
expect rename-apply "util.odin" "$OLS" query rename "$dir/util.odin:3:1" plus --apply
grep -q "plus(1, 2)" "$dir/main.odin" && grep -q "^plus ::" "$dir/util.odin"
odin check "$dir" -no-entry-point
echo "ok rename-apply check"
expect check "not an int\|Cannot assign\|cannot" "$OLS" query check "$dir/bad"
expect check-diagnostic '"diagnostic"' "$OLS" query check "$dir/bad"
if "$OLS" query nonsense >/dev/null 2>&1; then echo "FAIL usage exit"; exit 1; fi
echo "ok usage"
echo "all ok"
