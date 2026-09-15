package tests

import "core:testing"

import test "src:testing"

EXTRACT_PROCEDURE_ACTION :: "Extract procedure"

@(test)
action_extract_procedure_no_inputs :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

foo :: proc(x: int) {
}

main :: proc() {
	{[foo(1)
	foo(2)]}
	foo(3)
}
`,
		packages = {},
		config = {enable_code_action_extract_procedure = true},
	}

	test.expect_action_applied(t, &source, EXTRACT_PROCEDURE_ACTION, `package test

foo :: proc(x: int) {
}

main :: proc() {
	extracted()
	foo(3)
}

extracted :: proc() {
	foo(1)
	foo(2)
}
`)
}

@(test)
action_extract_procedure_inputs :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

foo :: proc(x: int, y: f32) {
}

main :: proc() {
	x := 5
	y: f32 = 2
	{[foo(x, y)]}
}
`,
		packages = {},
		config = {enable_code_action_extract_procedure = true},
	}

	test.expect_action_applied(t, &source, EXTRACT_PROCEDURE_ACTION, `package test

foo :: proc(x: int, y: f32) {
}

main :: proc() {
	x := 5
	y: f32 = 2
	extracted(x, y)
}

extracted :: proc(x: int, y: f32) {
	foo(x, y)
}
`)
}

@(test)
action_extract_procedure_outputs :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

use :: proc(a: int, b: f64) {
}

main :: proc() {
	{[a := 1
	b := 2.0]}
	use(a, b)
}
`,
		packages = {},
		config = {enable_code_action_extract_procedure = true},
	}

	test.expect_action_applied(t, &source, EXTRACT_PROCEDURE_ACTION, `package test

use :: proc(a: int, b: f64) {
}

main :: proc() {
	a, b := extracted()
	use(a, b)
}

extracted :: proc() -> (int, f64) {
	a := 1
	b := 2.0
	return a, b
}
`)
}

@(test)
action_extract_procedure_struct_and_pointer_params :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Point :: struct {
	x: int,
}

use :: proc(p: Point, q: ^Point) {
}

main :: proc(p: Point, q: ^Point) {
	{[use(p, q)
	use(p, q)]}
}
`,
		packages = {},
		config = {enable_code_action_extract_procedure = true},
	}

	test.expect_action_applied(t, &source, EXTRACT_PROCEDURE_ACTION, `package test

Point :: struct {
	x: int,
}

use :: proc(p: Point, q: ^Point) {
}

main :: proc(p: Point, q: ^Point) {
	extracted(p, q)
}

extracted :: proc(p: Point, q: ^Point) {
	use(p, q)
	use(p, q)
}
`)
}

@(test)
action_extract_procedure_slice_and_map_params :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

use :: proc(s: []int, m: map[string]int) {
}

main :: proc() {
	s: []int
	m: map[string]int
	{[use(s, m)]}
	use(s, m)
}
`,
		packages = {},
		config = {enable_code_action_extract_procedure = true},
	}

	test.expect_action_applied(t, &source, EXTRACT_PROCEDURE_ACTION, `package test

use :: proc(s: []int, m: map[string]int) {
}

main :: proc() {
	s: []int
	m: map[string]int
	extracted(s, m)
	use(s, m)
}

extracted :: proc(s: []int, m: map[string]int) {
	use(s, m)
}
`)
}

@(test)
action_extract_procedure_inner_break_allowed :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x := true
	{[for {
		if x {
			break
		}
	}]}
}
`,
		packages = {},
		config = {enable_code_action_extract_procedure = true},
	}

	test.expect_action_applied(t, &source, EXTRACT_PROCEDURE_ACTION, `package test

main :: proc() {
	x := true
	extracted(x)
}

extracted :: proc(x: bool) {
	for {
		if x {
			break
		}
	}
}
`)
}

@(test)
action_extract_procedure_refused_return :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x := true
	{[if x {
		return
	}]}
}
`,
		packages = {},
		config = {enable_code_action_extract_procedure = true},
	}

	test.expect_action_missing(t, &source, EXTRACT_PROCEDURE_ACTION)
}

@(test)
action_extract_procedure_refused_outer_loop_break :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x := true
	for {
		{[if x {
			break
		}]}
	}
}
`,
		packages = {},
		config = {enable_code_action_extract_procedure = true},
	}

	test.expect_action_missing(t, &source, EXTRACT_PROCEDURE_ACTION)
}

@(test)
action_extract_procedure_refused_write_to_input :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

use :: proc(x: int) {
}

main :: proc() {
	x := 1
	{[x += 1]}
	use(x)
}
`,
		packages = {},
		config = {enable_code_action_extract_procedure = true},
	}

	test.expect_action_missing(t, &source, EXTRACT_PROCEDURE_ACTION)
}

@(test)
action_extract_procedure_refused_partial_statement :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

foo :: proc(a: int, b: int) {
}

main :: proc() {
	a, b := 1, 2
	foo({[a, b]})
}
`,
		packages = {},
		config = {enable_code_action_extract_procedure = true},
	}

	test.expect_action_missing(t, &source, EXTRACT_PROCEDURE_ACTION)
}

@(test)
action_extract_procedure_disabled :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

foo :: proc(x: int) {
}

main :: proc() {
	{[foo(1)]}
}
`,
		packages = {},
		config = {enable_code_action_extract_procedure = false},
	}

	test.expect_action_missing(t, &source, EXTRACT_PROCEDURE_ACTION)
}

@(test)
action_extract_procedure_then_inline_two_inputs :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

use :: proc(a: int, b: int) {
}

main :: proc() {
	a := 1
	b := 2
	{[use(a, b)
	use(b, a)]}
}
`,
		config = {enable_code_action_extract_procedure = true, enable_code_action_inline_proc = true},
	}

	test.expect_action_chain(t, &source, {EXTRACT_PROCEDURE_ACTION, INLINE_PROC_ACTION}, `package test

use :: proc(a: int, b: int) {
}

main :: proc() {
	a := 1
	b := 2
	{
		use(a, b)
		use(b, a)
	}
}

extracted :: proc(a: int, b: int) {
	use(a, b)
	use(b, a)
}
`)
}

@(test)
action_extract_procedure_single_output :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

use :: proc(a: int) {
}

main :: proc() {
	{[a := 1]}
	use(a)
}
`,
		config = {enable_code_action_extract_procedure = true},
	}

	test.expect_action_applied(t, &source, EXTRACT_PROCEDURE_ACTION, `package test

use :: proc(a: int) {
}

main :: proc() {
	a := extracted()
	use(a)
}

extracted :: proc() -> int {
	a := 1
	return a
}
`)
}

@(test)
action_extract_procedure_refused_defer :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

foo :: proc(x: int) {
}

main :: proc() {
	{[defer foo(1)
	foo(2)]}
}
`,
		config = {enable_code_action_extract_procedure = true},
	}

	test.expect_action_missing(t, &source, EXTRACT_PROCEDURE_ACTION)
}

@(test)
action_extract_procedure_then_inline_nested_proc_lit :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

run :: proc(f: proc()) {
}

main :: proc() {
	{[run(proc() {
		return
	})]}
}
`,
		config = {enable_code_action_extract_procedure = true, enable_code_action_inline_proc = true},
	}

	test.expect_action_chain(t, &source, {EXTRACT_PROCEDURE_ACTION, INLINE_PROC_ACTION}, `package test

run :: proc(f: proc()) {
}

main :: proc() {
	{
		run(proc() {
			return
		})
	}
}

extracted :: proc() {
	run(proc() {
		return
	})
}
`)
}

@(test)
action_extract_procedure_then_inline_context :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

foo :: proc(x: int) {
}

main :: proc() {
	{[foo(context.user_index)]}
}
`,
		config = {enable_code_action_extract_procedure = true, enable_code_action_inline_proc = true},
	}

	test.expect_action_chain(t, &source, {EXTRACT_PROCEDURE_ACTION, INLINE_PROC_ACTION}, `package test

foo :: proc(x: int) {
}

main :: proc() {
	{
		foo(context.user_index)
	}
}

extracted :: proc() {
	foo(context.user_index)
}
`)
}

@(test)
action_extract_procedure_named_result_as_input :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

use :: proc(x: int) {
}

f :: proc() -> (n: int) {
	n = 1
	{[use(n)]}
	return
}
`,
		config = {enable_code_action_extract_procedure = true},
	}

	test.expect_action_applied(t, &source, EXTRACT_PROCEDURE_ACTION, `package test

use :: proc(x: int) {
}

f :: proc() -> (n: int) {
	n = 1
	extracted(n)
	return
}

extracted :: proc(n: int) {
	use(n)
}
`)
}

@(test)
action_extract_procedure_trailing_comment_stays_at_call :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

foo :: proc(x: int) {
}

main :: proc() {
	{[foo(1) // why]}
}
`,
		config = {enable_code_action_extract_procedure = true},
	}

	test.expect_action_applied(t, &source, EXTRACT_PROCEDURE_ACTION, `package test

foo :: proc(x: int) {
}

main :: proc() {
	extracted() // why
}

extracted :: proc() {
	foo(1)
}
`)
}

@(test)
action_extract_procedure_then_inline_space_indented :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

foo :: proc(x: int) {
}

main :: proc() {
    {[foo(1)
    foo(2)]}
}
`,
		config = {enable_code_action_extract_procedure = true, enable_code_action_inline_proc = true},
	}

	test.expect_action_chain(t, &source, {EXTRACT_PROCEDURE_ACTION, INLINE_PROC_ACTION}, `package test

foo :: proc(x: int) {
}

main :: proc() {
    {
        foo(1)
        foo(2)
    }
}

extracted :: proc() {
	foo(1)
	foo(2)
}
`)
}

@(test)
action_extract_procedure_then_inline_keeps_comment_line :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

foo :: proc(x: int) {
}

main :: proc() {
	{[foo(1)
	// why
	foo(2)]}
}
`,
		config = {enable_code_action_extract_procedure = true, enable_code_action_inline_proc = true},
	}

	test.expect_action_chain(t, &source, {EXTRACT_PROCEDURE_ACTION, INLINE_PROC_ACTION}, `package test

foo :: proc(x: int) {
}

main :: proc() {
	{
		foo(1)
		// why
		foo(2)
	}
}

extracted :: proc() {
	foo(1)
	// why
	foo(2)
}
`)
}
