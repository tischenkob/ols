package tests

import "core:testing"

import test "src:testing"

@(test)
lint_allocator_mismatch :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

temp :: proc() {
	x := make([]int, 4, context.temp_allocator)
	delete(x)
}

matching :: proc() {
	y := make([]int, 4, context.temp_allocator)
	delete(y, context.temp_allocator)
}

default :: proc() {
	z := make([]int, 4, context.allocator)
	delete(z)
}
`,
		config = {enable_lint_allocator = true},
	}

	test.expect_lint_diagnostics(t, &source, {{4, "allocator-mismatch"}})
}

@(test)
lint_make_len_append :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

grow :: proc() {
	xs := make([dynamic]int, 4)
	append(&xs, 1)
}

empty :: proc() {
	ys := make([dynamic]int, 0)
	append(&ys, 1)
}

filled :: proc() {
	zs := make([dynamic]int, 4)
	zs[0] = 1
	append(&zs, 2)
}
`,
		config = {enable_lint_allocator = true},
	}

	test.expect_lint_diagnostics(t, &source, {{3, "make-len-append"}})
}

@(test)
lint_fix_allocator_mismatch :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() {
	x := make([]int, 4, context.temp_allocator)
	delete(x{*})
}
`,
		config = {enable_lint_allocator = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Free with context.temp_allocator",
		`package test

f :: proc() {
	x := make([]int, 4, context.temp_allocator)
	delete(x, context.temp_allocator)
}
`,
	)
}

@(test)
lint_fix_make_len_append :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() {
	xs := make([dynamic]int, 4{*})
	append(&xs, 1)
}
`,
		config = {enable_lint_allocator = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Make with capacity instead of length",
		`package test

f :: proc() {
	xs := make([dynamic]int, 0, 4)
	append(&xs, 1)
}
`,
	)
}

@(test)
lint_allocator_cases :: proc(t: ^testing.T) {
	cases := []Lint_Case {
		{
			"named allocator freed with the context allocator",
			`package test

Allocator :: struct {}

f :: proc(my_allocator: Allocator) {
	s := make([]int, 3, my_allocator)
	delete(s)
}
`,
			{{6, "allocator-mismatch"}},
		},
		{
			"named allocator matched on both sides",
			`package test

Allocator :: struct {}

f :: proc(my_allocator: Allocator) {
	s := make([]int, 3, my_allocator)
	delete(s, my_allocator)
}
`,
			{},
		},
		{
			"deferred free",
			`package test

f :: proc() {
	s := make([]int, 3, context.temp_allocator)
	defer delete(s)
}
`,
			{{4, "allocator-mismatch"}},
		},
		{
			"new freed with free",
			`package test

f :: proc() {
	p := new(int, context.temp_allocator)
	free(p)
}
`,
			{{4, "allocator-mismatch"}},
		},
		{
			"free_all is not a free",
			`package test

f :: proc() {
	p := new(int, context.temp_allocator)
	free_all(context.temp_allocator)
	_ = p
}
`,
			{},
		},
		{
			"the last allocation before the free wins",
			`package test

f :: proc() {
	s := make([]int, 3, context.temp_allocator)
	s = make([]int, 4, context.allocator)
	delete(s)
}
`,
			{},
		},
		{
			"make with capacity",
			`package test

f :: proc() {
	xs := make([dynamic]int, 0, 10)
	append(&xs, 1)
}
`,
			{},
		},
		{
			"make with a length and no append",
			`package test

f :: proc() {
	xs := make([dynamic]int, 4)
	xs[0] = 1
}
`,
			{},
		},
	}

	expect_lint_cases(t, cases, {enable_lint_allocator = true})
}

@(test)
lint_fix_allocator_free :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() {
	p := new(int, context.temp_allocator)
	free(p{*})
}
`,
		config = {enable_lint_allocator = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Free with context.temp_allocator",
		`package test

f :: proc() {
	p := new(int, context.temp_allocator)
	free(p, context.temp_allocator)
}
`,
	)
}

@(test)
lint_fix_allocator_twice :: proc(t: ^testing.T) {
	cases := []Fix_Twice {
		{
			"allocator-mismatch delete",
			"Free with context.temp_allocator",
			`package test

f :: proc() {
	x := make([]int, 4, context.temp_allocator)
	delete(x{*})
}
`,
			"delete(x, context.temp_allocator)",
		},
		{
			"allocator-mismatch free",
			"Free with context.temp_allocator",
			`package test

f :: proc() {
	p := new(int, context.temp_allocator)
	free(p{*})
}
`,
			"free(p, context.temp_allocator)",
		},
		{
			"make-len-append",
			"Make with capacity instead of length",
			`package test

f :: proc() {
	xs := make([dynamic]int, 4{*})
	append(&xs, 1)
}
`,
			"make([dynamic]int, 0, 4)",
		},
	}

	expect_fix_twice(t, cases, {enable_lint_allocator = true})
}
