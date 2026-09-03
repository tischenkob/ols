package tests

import "core:testing"

import test "src:testing"

INLINE_VARIABLE_ACTION :: "Inline variable"

@(test)
action_inline_variable_simple :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x{*} := 5
	foo(x)
	bar(x + 1)
}
`,
		packages = {},
		config = {enable_code_action_inline_variable = true},
	}

	test.expect_action_applied(t, &source, INLINE_VARIABLE_ACTION, `package test

main :: proc() {
	foo(5)
	bar(5 + 1)
}
`)
}

@(test)
action_inline_variable_parenthesized :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := 1, 2
	v{*} := a + b
	y := v * 2
	bar(v)
}
`,
		packages = {},
		config = {enable_code_action_inline_variable = true},
	}

	test.expect_action_applied(t, &source, INLINE_VARIABLE_ACTION, `package test

main :: proc() {
	a, b := 1, 2
	y := (a + b) * 2
	bar(a + b)
}
`)
}

@(test)
action_inline_variable_single_call_use :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

foo :: proc() -> int {
	return 1
}

main :: proc() {
	x{*} := foo()
	bar(x)
}
`,
		packages = {},
		config = {enable_code_action_inline_variable = true},
	}

	test.expect_action_applied(t, &source, INLINE_VARIABLE_ACTION, `package test

foo :: proc() -> int {
	return 1
}

main :: proc() {
	bar(foo())
}
`)
}

@(test)
action_inline_variable_shadowing :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x{*} := 5
	{
		x := 6
		foo(x)
	}
	foo(x)
}
`,
		packages = {},
		config = {enable_code_action_inline_variable = true},
	}

	test.expect_action_applied(t, &source, INLINE_VARIABLE_ACTION, `package test

main :: proc() {
	{
		x := 6
		foo(x)
	}
	foo(5)
}
`)
}

@(test)
action_inline_variable_refused_assignment :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x{*} := 5
	x = 6
	foo(x)
}
`,
		packages = {},
		config = {enable_code_action_inline_variable = true},
	}

	test.expect_action_missing(t, &source, INLINE_VARIABLE_ACTION)
}

@(test)
action_inline_variable_refused_address_of :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x{*} := 5
	p := &x
	foo(x)
}
`,
		packages = {},
		config = {enable_code_action_inline_variable = true},
	}

	test.expect_action_missing(t, &source, INLINE_VARIABLE_ACTION)
}

@(test)
action_inline_variable_refused_field_write :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Point :: struct {
	y: int,
}

main :: proc() {
	x{*} := Point{}
	x.y = 1
	foo(x)
}
`,
		packages = {},
		config = {enable_code_action_inline_variable = true},
	}

	test.expect_action_missing(t, &source, INLINE_VARIABLE_ACTION)
}

@(test)
action_inline_variable_refused_call_with_two_uses :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

foo :: proc() -> int {
	return 1
}

main :: proc() {
	x{*} := foo()
	bar(x)
	bar(x)
}
`,
		packages = {},
		config = {enable_code_action_inline_variable = true},
	}

	test.expect_action_missing(t, &source, INLINE_VARIABLE_ACTION)
}

@(test)
action_inline_variable_refused_multi_name :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x{*}, y := 1, 2
	foo(x, y)
}
`,
		packages = {},
		config = {enable_code_action_inline_variable = true},
	}

	test.expect_action_missing(t, &source, INLINE_VARIABLE_ACTION)
}

@(test)
action_inline_variable_refused_reassigned_input :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a := 1
	x{*} := a
	a = 2
	foo(x)
}
`,
		packages = {},
		config = {enable_code_action_inline_variable = true},
	}

	test.expect_action_missing(t, &source, INLINE_VARIABLE_ACTION)
}

@(test)
action_inline_variable_disabled :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x{*} := 5
	foo(x)
}
`,
		packages = {},
		config = {enable_code_action_inline_variable = false},
	}

	test.expect_action_missing(t, &source, INLINE_VARIABLE_ACTION)
}
