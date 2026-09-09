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

expect_inline_variable :: proc(t: ^testing.T, main, expected: string) {
	source := test.Source {
		main   = main,
		config = {enable_code_action_inline_variable = true},
	}
	test.expect_action_applied(t, &source, INLINE_VARIABLE_ACTION, expected)
}

expect_no_inline_variable :: proc(t: ^testing.T, main: string) {
	source := test.Source {
		main   = main,
		config = {enable_code_action_inline_variable = true},
	}
	test.expect_action_missing(t, &source, INLINE_VARIABLE_ACTION)
}

@(test)
action_inline_variable_parens_under_negation :: proc(t: ^testing.T) {
	expect_inline_variable(t, `package test

main :: proc() {
	a, b := 1, 2
	x{*} := a + b
	foo(-x)
}
`, `package test

main :: proc() {
	a, b := 1, 2
	foo(-(a + b))
}
`)
}

@(test)
action_inline_variable_parens_before_selector :: proc(t: ^testing.T) {
	expect_inline_variable(t, `package test

Point :: struct {
	y: int,
}

main :: proc() {
	p, q: Point
	c := true
	x{*} := c ? p : q
	foo(x.y)
}
`, `package test

Point :: struct {
	y: int,
}

main :: proc() {
	p, q: Point
	c := true
	foo((c ? p : q).y)
}
`)
}

@(test)
action_inline_variable_parens_before_index :: proc(t: ^testing.T) {
	expect_inline_variable(t, `package test

main :: proc() {
	a, b := []int{1}, []int{2}
	c := true
	x{*} := c ? a : b
	foo(x[0])
}
`, `package test

main :: proc() {
	a, b := []int{1}, []int{2}
	c := true
	foo((c ? a : b)[0])
}
`)
}

@(test)
action_inline_variable_ignores_name_inside_string :: proc(t: ^testing.T) {
	expect_inline_variable(t, `package test

main :: proc() {
	x{*} := 5
	foo("x")
	foo(x)
}
`, `package test

main :: proc() {
	foo("x")
	foo(5)
}
`)
}

@(test)
action_inline_variable_drops_trailing_comment :: proc(t: ^testing.T) {
	expect_inline_variable(t, `package test

main :: proc() {
	x{*} := 5 // the answer
	foo(x)
}
`, `package test

main :: proc() {
	foo(5)
}
`)
}

@(test)
action_inline_variable_refused_compound_assignment :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, `package test

main :: proc() {
	x{*} := 5
	x += 1
	foo(x)
}
`)
}

@(test)
action_inline_variable_refused_typed_decl :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, `package test

main :: proc() {
	x{*}: f32 = 1
	y := x / 2
}
`)
}

@(test)
action_inline_variable_then_extract_and_inline :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := 1, 2
	x{*} := a + b
	foo(x)
}
`,
		config = {enable_code_action_extract_variable = true, enable_code_action_inline_variable = true},
	}

	test.expect_action_chain(
		t,
		&source,
		{INLINE_VARIABLE_ACTION, EXTRACT_VARIABLE_ACTION, INLINE_VARIABLE_ACTION},
		`package test

main :: proc() {
	a, b := 1, 2
	foo(a + b)
}
`,
		{"a + b)", "value :="},
	)
}
