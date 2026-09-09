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

@(test)
lint_imports_cases :: proc(t: ^testing.T) {
	cases := []Lint_Case {
		{
			"the alias comes first",
			`package test

import f "core:fmt"
import "core:fmt"

main :: proc() {
	f.println("b")
}
`,
			{{3, "duplicate-import"}},
		},
		{
			"three imports of the same path report once each",
			`package test

import "core:fmt"
import "core:fmt"
import "core:fmt"

main :: proc() {
	fmt.println("a")
}
`,
			{{3, "duplicate-import"}, {4, "duplicate-import"}},
		},
		{
			// Tests run from `tests/`, where the document sits in `test/`, so this is `tests/builtin`.
			"an existing relative import",
			`package test

import "../builtin"
`,
			{},
		},
		{
			"imports cannot appear inside when",
			`package test

when ODIN_DEBUG {
	import "core:fmt"
}
`,
			{},
		},
	}

	expect_lint_cases(t, cases, {enable_lint_imports = true})
}

@(test)
lint_fix_duplicate_import :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "core:fmt"
import "core:strings"
import{*} "core:fmt"

main :: proc() {
	fmt.println(strings.to_upper("a"))
}
`,
		config = {enable_lint_imports = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Remove duplicate import",
		`package test

import "core:fmt"
import "core:strings"

main :: proc() {
	fmt.println(strings.to_upper("a"))
}
`,
	)
}

@(test)
lint_fix_duplicate_import_twice :: proc(t: ^testing.T) {
	cases := []Fix_Twice {
		{
			"duplicate-import",
			"Remove duplicate import",
			`package test

import "core:fmt"
import{*} "core:fmt"

main :: proc() {
	fmt.println("a")
}
`,
			`import "core:fmt"`,
		},
	}

	expect_fix_twice(t, cases, {enable_lint_imports = true})
}
