package tests

import "core:testing"

import test "src:testing"

@(test)
lint_fix_unreachable :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() -> int {
	return 1
	x{*} := 2
	_ = x
}
`,
		config = {enable_lint_unreachable_code = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Remove unreachable code",
		`package test

f :: proc() -> int {
	return 1
}
`,
	)
}

@(test)
lint_fix_self_assignment :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: int) -> int {
	a{*} = a
	return a
}
`,
		config = {enable_lint_self_assignment = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Remove self-assignment",
		`package test

f :: proc(a: int) -> int {
	return a
}
`,
	)
}

@(test)
lint_fix_unused_parameter :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a{*}: int, b: int) -> int {
	return b
}
`,
		config = {enable_lint_unused_parameter = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Rename parameter to `_`",
		`package test

f :: proc(_: int, b: int) -> int {
	return b
}
`,
	)
}

@(test)
lint_fix_outside_range :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: int, b: int) -> int {
	return b{*}
}
`,
		config = {enable_lint_unused_parameter = true},
	}

	test.expect_action_missing(t, &source, "Rename parameter to `_`")
}
