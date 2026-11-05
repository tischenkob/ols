package tests

import "core:testing"

import test "src:testing"

@(private = "file")
ADD_INLINE :: "Add #force_inline"
@(private = "file")
ADD_NO_INLINE :: "Add #force_no_inline"
@(private = "file")
REMOVE_INLINE :: "Remove #force_inline"
@(private = "file")
ADD_CONTEXTLESS :: "Add \"contextless\""
@(private = "file")
REMOVE_CONTEXTLESS :: "Remove \"contextless\""

@(private = "file")
expect_proc_tag :: proc(t: ^testing.T, title, main, expected: string) {
	source := test.Source {
		main = main,
		config = {enable_code_action_proc_tags = true},
	}
	test.expect_action_applied(t, &source, title, expected)
}

@(private = "file")
expect_no_proc_tag :: proc(t: ^testing.T, title, main: string, enabled := true) {
	source := test.Source {
		main = main,
		config = {enable_code_action_proc_tags = enabled},
	}
	test.expect_action_missing(t, &source, title)
}

@(test)
proc_tags_add_force_inline :: proc(t: ^testing.T) {
	expect_proc_tag(
		t,
		ADD_INLINE,
		`package test

ad{*}d :: proc(a, b: int) -> int {
	return a + b
}
`,
		`package test

add :: #force_inline proc(a, b: int) -> int {
	return a + b
}
`,
	)
	expect_proc_tag(
		t,
		ADD_NO_INLINE,
		`package test

ad{*}d :: proc(a, b: int) -> int {
	return a + b
}
`,
		`package test

add :: #force_no_inline proc(a, b: int) -> int {
	return a + b
}
`,
	)
}

@(test)
proc_tags_remove_force_inline :: proc(t: ^testing.T) {
	expect_proc_tag(
		t,
		REMOVE_INLINE,
		`package test

ad{*}d :: #force_inline proc(a, b: int) -> int {
	return a + b
}
`,
		`package test

add :: proc(a, b: int) -> int {
	return a + b
}
`,
	)
	expect_no_proc_tag(
		t,
		ADD_INLINE,
		`package test

ad{*}d :: #force_inline proc(a, b: int) -> int {
	return a + b
}
`,
	)
}

// The compiler rejects `#force_inline` on a procedure that calls itself, and a procedure type has no body to inline.
@(test)
proc_tags_force_inline_refusals :: proc(t: ^testing.T) {
	expect_no_proc_tag(
		t,
		ADD_INLINE,
		`package test

fa{*}ct :: proc(n: int) -> int {
	if n <= 1 do return 1
	return n * fact(n - 1)
}
`,
	)
	expect_no_proc_tag(t, ADD_INLINE, `package test

Ca{*}llback :: proc(n: int) -> int
`)
	expect_no_proc_tag(t, ADD_NO_INLINE, `package test

Ca{*}llback :: proc(n: int) -> int
`)
}

@(test)
proc_tags_add_contextless :: proc(t: ^testing.T) {
	expect_proc_tag(
		t,
		ADD_CONTEXTLESS,
		`package test

helper :: proc "contextless" (x: int) -> int {
	return x
}

ca{*}lc :: proc(x: int) -> int {
	return helper(x) + len("ab") + int(f32(x))
}

main :: proc() {
	_ = calc(1)
}
`,
		`package test

helper :: proc "contextless" (x: int) -> int {
	return x
}

calc :: proc "contextless" (x: int) -> int {
	return helper(x) + len("ab") + int(f32(x))
}

main :: proc() {
	_ = calc(1)
}
`,
	)
}

// A read of `context`, a call of a procedure that takes a context, and a use as a procedure value each refuse.
@(test)
proc_tags_add_contextless_refusals :: proc(t: ^testing.T) {
	expect_no_proc_tag(t, ADD_CONTEXTLESS, `package test

ca{*}lc :: proc() -> rawptr {
	return context.user_ptr
}
`)
	expect_no_proc_tag(
		t,
		ADD_CONTEXTLESS,
		`package test

other :: proc(x: int) -> int {
	return x
}

ca{*}lc :: proc(x: int) -> int {
	return other(x)
}
`,
	)
	expect_no_proc_tag(
		t,
		ADD_CONTEXTLESS,
		`package test

ca{*}lc :: proc(x: int) -> int {
	return x
}

main :: proc() {
	f := calc
	_ = f(1)
}
`,
	)
	expect_no_proc_tag(t, ADD_CONTEXTLESS, `package test

ca{*}lc :: proc(x: int) -> int {
	return x
}
`, false)
}

@(test)
proc_tags_remove_contextless :: proc(t: ^testing.T) {
	expect_proc_tag(
		t,
		REMOVE_CONTEXTLESS,
		`package test

ca{*}lc :: proc "contextless" (x: int) -> int {
	return x
}

main :: proc() {
	_ = calc(1)
}
`,
		`package test

calc :: proc(x: int) -> int {
	return x
}

main :: proc() {
	_ = calc(1)
}
`,
	)
	// A contextless caller has no context to pass on.
	expect_no_proc_tag(
		t,
		REMOVE_CONTEXTLESS,
		`package test

ca{*}lc :: proc "contextless" (x: int) -> int {
	return x
}

outer :: proc "contextless" () -> int {
	return calc(1)
}
`,
	)
	expect_no_proc_tag(
		t,
		REMOVE_INLINE,
		`package test

ad{*}d :: #force_inline proc(a, b: int) -> int {
	return a + b
}
`,
		false,
	)
}
