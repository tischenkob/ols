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

INLINE_ORDER_PRELUDE :: `package test

counter: int

bump :: proc() -> int {
	counter += 1
	return counter
}

reset :: proc() {
	counter = 100
}
`

@(test)
action_inline_variable_refused_call_moved_past_statement :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, INLINE_ORDER_PRELUDE + `
f :: proc() -> int {
	v{*} := bump()
	reset()
	return v
}
`)
}

@(test)
action_inline_variable_call_into_next_statement :: proc(t: ^testing.T) {
	expect_inline_variable(
		t,
		INLINE_ORDER_PRELUDE + `
f :: proc() -> int {
	reset()
	v{*} := bump()
	return v + 1
}
`,
		INLINE_ORDER_PRELUDE + `
f :: proc() -> int {
	reset()
	return bump() + 1
}
`,
	)
}

@(test)
action_inline_variable_refused_call_after_earlier_call :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, INLINE_ORDER_PRELUDE + `
f :: proc() {
	v{*} := bump()
	foo(bump(), v)
}
`)
}

@(test)
action_inline_variable_refused_call_into_condition :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, INLINE_ORDER_PRELUDE + `
f :: proc(c: bool) {
	v{*} := bump()
	if c {
		foo(v)
	}
}
`)
}

@(test)
action_inline_variable_refused_call_into_short_circuit :: proc(t: ^testing.T) {
	expect_no_inline_variable(
		t,
		INLINE_ORDER_PRELUDE + `
f :: proc(c: bool) -> bool {
	v{*} := bump()
	return c && v > 1
}
`,
	)
}

@(test)
action_inline_variable_refused_call_into_loop :: proc(t: ^testing.T) {
	expect_no_inline_variable(
		t,
		INLINE_ORDER_PRELUDE + `
f :: proc() {
	v{*} := bump()
	for i in 0 ..< 3 {
		foo(v)
	}
}
`,
	)
}

@(test)
action_inline_variable_pure_past_statements :: proc(t: ^testing.T) {
	expect_inline_variable(
		t,
		INLINE_ORDER_PRELUDE + `
f :: proc() {
	a, b := 1, 2
	v{*} := a + b
	reset()
	foo(v)
}
`,
		INLINE_ORDER_PRELUDE + `
f :: proc() {
	a, b := 1, 2
	reset()
	foo(a + b)
}
`,
	)
}

@(test)
action_inline_variable_refused_global_read_past_call :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, INLINE_ORDER_PRELUDE + `
f :: proc() -> int {
	v{*} := counter
	reset()
	return v
}
`)
}

@(test)
action_inline_variable_refused_input_written_later_in_loop :: proc(t: ^testing.T) {
	expect_no_inline_variable(
		t,
		`package test

main :: proc() {
	a := 1
	v{*} := a
	for i in 0 ..< 3 {
		foo(v)
		a += 1
	}
}
`,
	)
}

@(test)
action_inline_variable_refused_input_address_taken_before :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, `package test

main :: proc() {
	a := 1
	p := &a
	v{*} := a
	p^ = 2
	foo(v)
}
`)
}

@(test)
action_inline_variable_refused_index_read_past_call :: proc(t: ^testing.T) {
	expect_no_inline_variable(
		t,
		`package test

clear_first :: proc(s: []int) {
	s[0] = 0
}

main :: proc() {
	s := []int{1}
	v{*} := s[0]
	clear_first(s)
	foo(v)
}
`,
	)
}

@(test)
action_inline_variable_call_into_next_declaration :: proc(t: ^testing.T) {
	expect_inline_variable(
		t,
		INLINE_ORDER_PRELUDE + `
f :: proc() -> int {
	v{*} := bump()
	y := v * 2
	return y
}
`,
		INLINE_ORDER_PRELUDE + `
f :: proc() -> int {
	y := bump() * 2
	return y
}
`,
	)
}

@(test)
action_inline_variable_refused_call_after_earlier_read :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, INLINE_ORDER_PRELUDE + `
f :: proc() -> int {
	v{*} := bump()
	return counter + v
}
`)
}

@(test)
action_inline_variable_refused_parameter_field_read_past_call :: proc(t: ^testing.T) {
	expect_no_inline_variable(
		t,
		`package test

Point :: struct {
	y: int,
}

clear_point :: proc(p: ^Point) {
	p.y = 0
}

main :: proc(p: ^Point) {
	v{*} := p.y
	clear_point(p)
	foo(v)
}
`,
	)
}

@(test)
action_inline_variable_refused_call_into_compound_assignment :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, INLINE_ORDER_PRELUDE + `
f :: proc() -> int {
	total := 1
	v{*} := bump()
	total += v
	return total
}
`)
}
