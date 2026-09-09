package tests

import "core:testing"

import test "src:testing"

@(test)
lint_unused_variable :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

use :: proc(v: int) {}

locals :: proc() {
	unused := 1
	used := 2
	use(used)
	_ := 3
}

constants :: proc() {
	UNUSED :: 4
	USED :: 5
	use(USED)
}

loops :: proc(n: int) {
	for i := 0; i < n; i += 1 {
		use(i)
	}
	for v in 0 ..< n {
	}
}
`,
		config = {enable_lint_unused_variable = true},
	}

	test.expect_lint_diagnostics(t, &source, {{5, "unused-variable"}, {12, "unused-variable"}})
}

@(test)
lint_fix_unused_variable :: proc(t: ^testing.T) {
	removable := test.Source {
		main = `package test

f :: proc() {
	x{*} := 1
}
`,
		config = {enable_lint_unused_variable = true},
	}

	test.expect_action_applied(t, &removable, "Remove declaration", `package test

f :: proc() {
}
`)

	with_call := test.Source {
		main = `package test

g :: proc() -> int {
	return 0
}

f :: proc() {
	x{*} := g()
}
`,
		config = {enable_lint_unused_variable = true},
	}

	test.expect_action_applied(
		t,
		&with_call,
		"Replace with `_`",
		`package test

g :: proc() -> int {
	return 0
}

f :: proc() {
	x := g()
	_ = x
}
`,
	)
}
