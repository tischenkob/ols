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
