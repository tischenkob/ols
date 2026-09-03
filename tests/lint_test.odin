package tests

import "core:testing"

import test "src:testing"

@(test)
lint_self_assignment :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

P :: struct {
	x: int,
}

f :: proc(y: int) -> int {
	return y
}

main :: proc() {
	x := 1
	y := 2
	p: P
	x = x
	p.x = p.x
	x = y
	x, y = y, x
	x = f(x)
	x += x
}
`,
		config = {enable_lint_self_assignment = true},
	}

	test.expect_lint_diagnostics(t, &source, {{14, "self-assignment"}, {15, "self-assignment"}})
}

@(test)
lint_identical_branches :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(c: bool) -> int {
	x := 0
	if c {
		x = 1
	} else {
		x = 1
	}
	if c {
		x = 1
	} else {
		x = 2
	}
	if c {
		x = 1
	} else if !c {
		x = 1
	}
	x = c ? 3 : 3
	x = c ? 3 : 4
	return x
}
`,
		config = {enable_lint_identical_branches = true},
	}

	test.expect_lint_diagnostics(t, &source, {{4, "identical-branches"}, {19, "identical-branches"}})
}

@(test)
lint_unreachable_code :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(c: bool) -> int {
	if c {
		return 1
	}
	for {
		if c {
			break
		}
		continue
		_ = c
	}
	switch c {
	case true:
		panic("no")
		return 2
		return 3
	}
	return 0
	return 1
}
`,
		config = {enable_lint_unreachable_code = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{{20, "unreachable-code"}, {11, "unreachable-code"}, {16, "unreachable-code"}},
	)
}

@(test)
lint_unreachable_code_range :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() -> int {
	return 0
	a := 1
	b := 2
	return a + b
}
`,
		config = {enable_lint_unreachable_code = true},
	}

	test.expect_lint_diagnostics(t, &source, {{4, "unreachable-code"}})
}

@(test)
lint_float_equality :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

P :: struct {
	x: f32,
	n: int,
}

f :: proc(a, b: f32, i, j: int, p: P) -> bool {
	r := a == b
	r = i == j
	r = i != 1
	r = i == 1.5
	r = p.x != p.x
	r = p.n == p.n
	r = a < b
	return r
}
`,
		config = {enable_lint_float_equality = true},
	}

	test.expect_lint_diagnostics(t, &source, {{8, "float-equality"}, {11, "float-equality"}, {12, "float-equality"}})
}

@(test)
lint_disabled :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: f32) -> bool {
	x := 1
	x = x
	if a == 1.0 {
		return true
	} else {
		return true
	}
	return false
	return false
}
`,
	}

	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
lint_ignored_result :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Allocator_Error :: enum {
	None,
	Out_Of_Memory,
}

Parse_Error :: union {
	Allocator_Error,
}

append_elem :: proc(array: ^$T/[dynamic]$E, arg: E) -> (n: int, err: Allocator_Error) #optional_allocator_error {
	return 0, .None
}

append :: proc {
	append_elem,
}

ok_proc :: proc() -> bool {
	return true
}

alloc_proc :: proc() -> (int, Allocator_Error) {
	return 0, .None
}

union_proc :: proc() -> Parse_Error {
	return nil
}

int_proc :: proc() -> int {
	return 0
}

main :: proc() {
	xs: [dynamic]int
	append(&xs, 1)
	ok_proc()
	_ = ok_proc()
	(alloc_proc())
	union_proc()
	int_proc()
	defer ok_proc()
	if ok_proc() {
	}
}
`,
		config = {enable_lint_ignored_result = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{{38, "ignored-result"}, {40, "ignored-result"}, {41, "ignored-result"}},
	)
}

@(test)
lint_unused_parameter :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

P :: struct {
	x: int,
}

used :: proc(a: int, b: int) -> int {
	return a
}

closure :: proc(a: int, b: int) -> int {
	f := proc(x: int) -> int {
		return x
	}
	return f(a)
}

underscore :: proc(_: int, _unused: int) {
	x := 1
}

using_param :: proc(using p: P) {
	x := 1
}

poly :: proc($T: typeid, v: T, n: int) {
	x := 1
}

stub :: proc(a: int) {
}

todo :: proc(a: int) {
	unreachable()
}

@(export)
exported :: proc(a: int) {
	x := 1
}

callback :: proc "c" (a: int) {
	x := 1
}

anon := proc(a: int, b: int) -> int {
	return b
}

field_name :: proc(x: int, y: int) -> P {
	return P{x = y}
}
`,
		config = {enable_lint_unused_parameter = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{
			{6, "unused-parameter"},
			{10, "unused-parameter"},
			{25, "unused-parameter"},
			{45, "unused-parameter"},
			{49, "unused-parameter"},
		},
	)
}

@(test)
lint_results_disabled :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

ok_proc :: proc(a: int) -> bool {
	return true
}

main :: proc() {
	ok_proc(1)
}
`,
	}

	test.expect_lint_diagnostics(t, &source, {})
}
