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

@(test)
checker_fix_unused_keeps_a_call :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() -> int { return 1 }

g :: proc() {
	x{*} := f()
}
`,
		config = {enable_code_action_checker_fix = true},
	}

	test.seed_check_diagnostic(&source, 5, 1, 2, "'x' declared but not used")

	test.expect_action_applied(t, &source, "Replace 'x' with _", `package test

f :: proc() -> int { return 1 }

g :: proc() {
	x := f()
	_ = x
}
`)

	removal := test.Source {
		main = `package test

f :: proc() -> int { return 1 }

g :: proc() {
	x{*} := f()
}
`,
		config = {enable_code_action_checker_fix = true},
	}

	test.seed_check_diagnostic(&removal, 5, 1, 2, "'x' declared but not used")

	test.expect_action_missing(t, &removal, "Remove 'x'")
}

// The removal takes a whole line only when nothing else is on it, so a trailing comment stays.
@(test)
checker_fix_unused_keeps_a_trailing_comment :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() {
	x{*} := 1 // counts nothing
}
`,
		config = {enable_code_action_checker_fix = true},
	}

	test.seed_check_diagnostic(&source, 3, 1, 2, "'x' declared but not used")

	test.expect_action_applied(t, &source, "Remove 'x'", `package test

f :: proc() {
 // counts nothing
}
`)
}

@(test)
checker_fix_unused_second_name :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() -> (int, int) { return 1, 2 }

g :: proc() -> int {
	x, y{*} := f()
	return x
}
`,
		config = {enable_code_action_checker_fix = true},
	}

	test.seed_check_diagnostic(&source, 5, 4, 5, "'y' declared but not used")

	test.expect_action_applied(t, &source, "Replace 'y' with _", `package test

f :: proc() -> (int, int) { return 1, 2 }

g :: proc() -> int {
	x, _ := f()
	return x
}
`)
}

// A range variable is not a declaration, so neither fix applies to it.
@(test)
checker_fix_unused_range_variable :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(xs: []int) {
	for x{*} in xs {
	}
}
`,
		config = {enable_code_action_checker_fix = true},
	}

	test.seed_check_diagnostic(&source, 3, 5, 6, "'x' declared but not used")

	test.expect_action_missing(t, &source, "Replace 'x' with _")
}

@(test)
checker_fix_conversion_call :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: int) -> int {
	return in{*}t(a)
}
`,
		config = {enable_code_action_checker_fix = true},
	}

	test.seed_check_diagnostic(&source, 3, 8, 14, "Unneeded cast of 'a' to identical type 'int'")

	test.expect_action_applied(t, &source, "Remove cast", `package test

f :: proc(a: int) -> int {
	return a
}
`)
}

@(test)
checker_fix_transmute :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: int) -> int {
	return transm{*}ute(int)a
}
`,
		config = {enable_code_action_checker_fix = true},
	}

	test.seed_check_diagnostic(&source, 3, 8, 22, "Unneeded transmute of 'a' to identical type 'int'")

	test.expect_action_applied(t, &source, "Remove transmute", `package test

f :: proc(a: int) -> int {
	return a
}
`)
}

@(test)
checker_fix_conversion_nested :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: int) -> f32 {
	return f32(in{*}t(a))
}
`,
		config = {enable_code_action_checker_fix = true},
	}

	test.seed_check_diagnostic(&source, 3, 12, 18, "Unneeded cast of 'a' to identical type 'int'")

	test.expect_action_applied(t, &source, "Remove cast", `package test

f :: proc(a: int) -> f32 {
	return f32(a)
}
`)
}

@(test)
checker_fix_off_the_name :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() {
	x{*} := 1
}
`,
		config = {enable_code_action_checker_fix = true},
	}

	test.seed_check_diagnostic(&source, 3, 6, 7, "'x' declared but not used")

	test.expect_action_missing(t, &source, "Remove 'x'")
}

@(test)
checker_fix_other_line :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() {
	x := 1
	y{*} := 2
}
`,
		config = {enable_code_action_checker_fix = true},
	}

	test.seed_check_diagnostic(&source, 3, 1, 2, "'x' declared but not used")

	test.expect_action_missing(t, &source, "Remove 'x'")
}

@(test)
checker_fix_no_check_diagnostics :: proc(t: ^testing.T) {
	source := test.Source {
		files = {{"clean.odin", `package test

f :: proc() {
	x{*} := 1
}
`}},
		config = {enable_code_action_checker_fix = true},
	}

	test.expect_action_missing(t, &source, "Remove 'x'")
}
