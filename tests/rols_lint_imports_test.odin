#+feature dynamic-literals

package tests

import "core:testing"

import test "src:testing"

@(test)
lint_duplicate_import :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "core:fmt"
import "core:strings"
import f "core:fmt"

main :: proc() {
	fmt.println(strings.to_upper("a"))
	f.println("b")
}
`,
		config = {enable_lint_imports = true},
	}
	test.expect_lint_diagnostics(t, &source, {{4, "duplicate-import"}})
}

@(test)
lint_missing_import :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "core:nope"
import "unknown:whatever"

main :: proc() {
	nope.thing()
}
`,
		collections = {"core" = "test"},
		config = {enable_lint_imports = true},
	}
	test.expect_lint_diagnostics(t, &source, {{2, "missing-import"}})
}
