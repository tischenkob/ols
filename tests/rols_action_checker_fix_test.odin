package tests

import "core:testing"

import test "src:testing"

@(test)
checker_fix_unused :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() {
	x{*} := 1
}
`,
		config = {enable_code_action_checker_fix = true},
	}

	test.seed_check_diagnostic(&source, 3, 1, 2, "'x' declared but not used")

	test.expect_action_applied(t, &source, "Remove 'x'", `package test

f :: proc() {
}
`)
}

@(test)
checker_fix_unused_discard :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: int) {
	x{*} := a + 1
}
`,
		config = {enable_code_action_checker_fix = true},
	}

	test.seed_check_diagnostic(&source, 3, 1, 2, "'x' declared but not used")

	test.expect_action_applied(
		t,
		&source,
		"Replace 'x' with _",
		`package test

f :: proc(a: int) {
	x := a + 1
	_ = x
}
`,
	)
}

@(test)
checker_fix_cast :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: int) -> int {
	return cast(int)a{*}
}
`,
		config = {enable_code_action_checker_fix = true},
	}

	test.seed_check_diagnostic(&source, 3, 8, 17, "Unneeded cast of 'a' to identical type 'int'")

	test.expect_action_applied(t, &source, "Remove cast", `package test

f :: proc(a: int) -> int {
	return a
}
`)
}
