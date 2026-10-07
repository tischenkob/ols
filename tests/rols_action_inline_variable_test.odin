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
f :: proc() {
	v{*} := bump()
	counter += v
}
`)
}

@(test)
action_inline_variable_refused_input_written_before_deferred_use :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, `package test

main :: proc() {
	a := 1
	v{*} := a
	defer foo(v)
	a = 2
}
`)
}

@(test)
action_inline_variable_refused_using_pointer_field :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, `package test

Point :: struct {
	y: int,
}

clear_point :: proc(p: ^Point) {
	p.y = 0
}

main :: proc(using p: ^Point) {
	v{*} := y
	clear_point(p)
	foo(v)
}
`)
}

@(test)
action_inline_variable_refused_using_local_field :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, `package test

S :: struct {
	y: int,
}

main :: proc() {
	using s: S
	v{*} := y
	s.y = 2
	foo(v)
}
`)
}

@(test)
action_inline_variable_refused_literal_with_two_uses :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, `package test

clear_first :: proc(s: []int) {
	s[0] = 0
}

main :: proc() {
	v{*} := []int{1}
	clear_first(v)
	foo(v[0])
}
`)
}

@(test)
action_inline_variable_refused_input_sliced :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, `package test

main :: proc() {
	arr := [2]int{1, 2}
	s := arr[:]
	v{*} := arr
	s[0] = 9
	foo(v)
}
`)
}

@(test)
action_inline_variable_refused_input_ranged_by_reference :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, `package test

main :: proc() {
	arr := [2]int{1, 2}
	v{*} := arr
	for &e in arr {
		e = 0
	}
	foo(v)
}
`)
}

@(test)
action_inline_variable_refused_context_read :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, `package test

main :: proc() {
	v{*} := context
	context.user_index = 3
	foo(v)
}
`)
}

@(test)
action_inline_variable_refused_unresolved_read :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, `package test

main :: proc() {
	v{*} := unknown_global
	reset()
	foo(v)
}
`)
}

@(test)
action_inline_variable_builtin_len_past_statement :: proc(t: ^testing.T) {
	expect_inline_variable(t, `package test

main :: proc() -> int {
	s := []int{1, 2, 3}
	n{*} := len(s)
	x := 2
	return n + x
}
`, `package test

main :: proc() -> int {
	s := []int{1, 2, 3}
	x := 2
	return len(s) + x
}
`)
}

@(test)
action_inline_variable_refused_builtin_len_past_append :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, `package test

main :: proc() -> int {
	d: [dynamic]int
	n{*} := len(d)
	append(&d, 1)
	return n
}
`)
}

// align_of reads only the type of its argument, so a write to the global does not change it.
@(test)
action_inline_variable_align_of_global_past_write :: proc(t: ^testing.T) {
	expect_inline_variable(t, `package test

g: int

main :: proc() -> int {
	n{*} := align_of(g)
	g = 2
	return n
}
`, `package test

g: int

main :: proc() -> int {
	g = 2
	return align_of(g)
}
`)
}

// A local whose address is never taken cannot change in the call, so reading it first is safe.
@(test)
action_inline_variable_call_after_local_read :: proc(t: ^testing.T) {
	expect_inline_variable(t, INLINE_ORDER_PRELUDE + `
g :: proc(a, b: int) {}

f :: proc() {
	a := 1
	v{*} := bump()
	g(a, v)
}
`, INLINE_ORDER_PRELUDE + `
g :: proc(a, b: int) {}

f :: proc() {
	a := 1
	g(a, bump())
}
`)
}

@(test)
action_inline_variable_refused_call_after_address_taken_local_read :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, INLINE_ORDER_PRELUDE + `
g :: proc(a, b: int) {}

f :: proc() {
	a := 1
	p := &a
	_ = p
	v{*} := bump()
	g(a, v)
}
`)
}

// A plain `=` target is written after the value is computed, so a global target is safe too.
@(test)
action_inline_variable_call_into_global_assignment :: proc(t: ^testing.T) {
	expect_inline_variable(t, INLINE_ORDER_PRELUDE + `
f :: proc() {
	v{*} := bump()
	counter = v
}
`, INLINE_ORDER_PRELUDE + `
f :: proc() {
	counter = bump()
}
`)
}

// A recursive call writes the same static local, so reading it first changes the result.
@(test)
action_inline_variable_refused_call_after_static_local_read :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, `package test

f :: proc(n: int) -> int {
	@(static) calls: int
	calls += 1
	if n == 0 do return 0
	v{*} := f(n - 1)
	total := calls + v
	return total
}
`)
}

@(test)
action_inline_variable_refused_static_local_read_past_call :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, `package test

f :: proc(n: int) -> int {
	@(static) calls: int
	calls += 1
	if n == 0 do return 0
	v{*} := calls
	f(n - 1)
	return v
}
`)
}

// len of a cstring reads the bytes it points to.
@(test)
action_inline_variable_refused_cstring_len_past_write :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, `package test

main :: proc() -> int {
	buf := [4]u8{'a', 'b', 0, 0}
	c := cstring(&buf[0])
	n{*} := len(c)
	buf[0] = 0
	return n
}
`)
}

@(test)
action_inline_variable_refused_shadowed_len_past_statement :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, `package test

len :: proc(s: []int) -> int { return 0 }

main :: proc() -> int {
	s := []int{1, 2, 3}
	n{*} := len(s)
	x := 2
	return n + x
}
`)
}

@(test)
action_inline_variable_refused_len_of_pointer_past_statement :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, `package test

main :: proc() -> int {
	arr := [4]int{}
	p := &arr
	n{*} := len(p)
	x := 2
	return n + x
}
`)
}

@(test)
action_inline_variable_refused_call_after_method_base_local_read :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, INLINE_ORDER_PRELUDE + `
S :: struct {
	m: proc(s: ^S),
}

g :: proc(s: S, b: int) {}

f :: proc() {
	s: S
	s->m()
	v{*} := bump()
	g(s, v)
}
`)
}

@(test)
action_inline_variable_refused_call_after_sliced_local_read :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, INLINE_ORDER_PRELUDE + `
g :: proc(a: [2]int, b: int) {}

f :: proc() {
	arr := [2]int{}
	sl := arr[:]
	_ = sl
	v{*} := bump()
	g(arr, v)
}
`)
}

// A nested procedure sees the static local of the procedure around it, and bump writes it.
@(test)
action_inline_variable_refused_call_after_enclosing_static_local_read :: proc(t: ^testing.T) {
	expect_no_inline_variable(t, `package test

outer :: proc() {
	@(static) n: int
	bump :: proc() -> int {
		n += 1
		return n
	}
	inner :: proc() -> int {
		v{*} := bump()
		x := n + v
		return x
	}
}
`)
}

// An `any` argument points at the local itself, so a later call can write it through that pointer.
INLINE_ANY_PRELUDE :: `package test

p: ^int

stash :: proc(a: any) {
	p = (^int)(a.data)
}

stash_all :: proc(args: ..any) {
	p = (^int)(args[0].data)
}

bump :: proc() -> int {
	p^ += 1
	return 0
}

take :: proc(a: int) {}
`

@(test)
action_inline_variable_refused_call_after_any_argument_local_read :: proc(t: ^testing.T) {
	expect_no_inline_variable(
		t,
		INLINE_ANY_PRELUDE + `
f :: proc() -> int {
	n := 1
	stash(n)
	v{*} := bump()
	x := n + v
	return x
}
`,
	)
}

@(test)
action_inline_variable_refused_call_after_variadic_any_argument_local_read :: proc(t: ^testing.T) {
	expect_no_inline_variable(
		t,
		INLINE_ANY_PRELUDE + `
f :: proc() -> int {
	n := 1
	stash_all(n)
	v{*} := bump()
	x := n + v
	return x
}
`,
	)
}

@(test)
action_inline_variable_refused_call_after_named_any_argument_local_read :: proc(t: ^testing.T) {
	expect_no_inline_variable(
		t,
		INLINE_ANY_PRELUDE + `
f :: proc() -> int {
	n := 1
	stash(a = (n))
	v{*} := bump()
	x := n + v
	return x
}
`,
	)
}

@(test)
action_inline_variable_refused_call_after_by_ptr_argument_local_read :: proc(t: ^testing.T) {
	expect_no_inline_variable(
		t,
		INLINE_ANY_PRELUDE +
		`
keep :: proc(#by_ptr a: int) {}

f :: proc() -> int {
	n := 1
	keep(n)
	v{*} := bump()
	x := n + v
	return x
}
`,
	)
}

@(test)
action_inline_variable_refused_input_passed_as_any_past_use :: proc(t: ^testing.T) {
	expect_no_inline_variable(
		t,
		INLINE_ANY_PRELUDE + `
f :: proc() -> int {
	n := 1
	stash(n)
	v{*} := n + 1
	bump()
	return v
}
`,
	)
}

// A plain value parameter gets a copy, so the local still cannot change in the call.
@(test)
action_inline_variable_call_after_value_argument_local_read :: proc(t: ^testing.T) {
	expect_inline_variable(
		t,
		INLINE_ANY_PRELUDE + `
f :: proc() -> int {
	n := 1
	take(n)
	v{*} := bump()
	x := n + v
	return x
}
`,
		INLINE_ANY_PRELUDE + `
f :: proc() -> int {
	n := 1
	take(n)
	x := n + bump()
	return x
}
`,
	)
}
