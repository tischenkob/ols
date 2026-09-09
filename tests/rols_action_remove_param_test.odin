package tests

import "core:testing"

import test "src:testing"

expect_no_remove_param :: proc(t: ^testing.T, title, main: string, files: []test.File = {}, enabled := true) {
	source := test.Source {
		main   = main,
		files  = files,
		config = {enable_code_action_remove_param = enabled},
	}
	test.expect_action_missing(t, &source, title)
}

@(test)
action_remove_param_middle_across_files :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

add :: proc(a: int, un{*}used: int, b: int) -> int {
	return a + b
}

main :: proc() {
	x := add(1, 2, 3)
}
`,
		files = {
			{"b.odin", `package test

other :: proc() {
	y := add(4, 5, 6)
}
`},
		},
		config = {enable_code_action_remove_param = true},
	}
	test.expect_action_applied_files(
		t,
		&source,
		"Remove parameter unused",
		{
			{"main.odin", `package test

add :: proc(a: int, b: int) -> int {
	return a + b
}

main :: proc() {
	x := add(1, 3)
}
`},
			{"b.odin", `package test

other :: proc() {
	y := add(4, 6)
}
`},
		},
	)
}

@(test)
action_remove_param_multi_name_field :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

add :: proc(a, {*}b, c: int) -> int {
	return a + c
}

main :: proc() {
	x := add(1, 2, 3)
}
`,
		config = {enable_code_action_remove_param = true},
	}
	test.expect_action_applied_files(t, &source, "Remove parameter b", {{"main.odin", `package test

add :: proc(a, c: int) -> int {
	return a + c
}

main :: proc() {
	x := add(1, 3)
}
`}})
}

@(test)
action_remove_param_last :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

show :: proc(a: int, fla{*}g: bool) {
	_ = a
}

main :: proc() {
	show(1, true)
}
`,
		config = {enable_code_action_remove_param = true},
	}
	test.expect_action_applied_files(t, &source, "Remove parameter flag", {{"main.odin", `package test

show :: proc(a: int) {
	_ = a
}

main :: proc() {
	show(1)
}
`}})
}

@(test)
action_remove_param_refused_used :: proc(t: ^testing.T) {
	expect_no_remove_param(t, "Remove parameter a", `package test

add :: proc({*}a: int, b: int) -> int {
	return a + b
}

main :: proc() {
	x := add(1, 2)
}
`)
}

@(test)
action_remove_param_refused_named_argument_caller :: proc(t: ^testing.T) {
	expect_no_remove_param(t, "Remove parameter unused", `package test

add :: proc(a: int, un{*}used: int) -> int {
	return a
}

main :: proc() {
	x := add(a = 1, unused = 2)
}
`)
}

@(test)
action_remove_param_refused_proc_group_member :: proc(t: ^testing.T) {
	expect_no_remove_param(t, "Remove parameter unused", `package test

add :: proc(a: int, un{*}used: int) -> int {
	return a
}

add_f :: proc(a: f32) -> f32 {
	return a
}

group :: proc{add, add_f}

main :: proc() {
	x := add(1, 2)
}
`)
}

@(test)
action_remove_param_disabled :: proc(t: ^testing.T) {
	expect_no_remove_param(t, "Remove parameter unused", `package test

add :: proc(a: int, un{*}used: int) -> int {
	return a
}

main :: proc() {
	x := add(1, 2)
}
`, enabled = false)
}

@(test)
reorder_params_three_across_files :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

pl{*}ace :: proc(x: int, y: int, name: string) {
}

main :: proc() {
	place(1, 2, "a")
}
`,
		files = {
			{"b.odin", `package test

other :: proc() {
	place(3, 4, "b")
}
`},
		},
	}
	test.expect_reorder_params(
		t,
		&source,
		{2, 0, 1},
		{
			{"main.odin", `package test

place :: proc(name: string, x: int, y: int) {
}

main :: proc() {
	place("a", 1, 2)
}
`},
			{"b.odin", `package test

other :: proc() {
	place("b", 3, 4)
}
`},
		},
	)
}

@(test)
reorder_params_splits_shared_type :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

pl{*}ace :: proc(x, y: int, name: string) {
}

main :: proc() {
	place(1, 2, "a")
}
`,
	}
	test.expect_reorder_params(t, &source, {1, 2, 0}, {{"main.odin", `package test

place :: proc(y: int, name: string, x: int) {
}

main :: proc() {
	place(2, "a", 1)
}
`}})
}

@(test)
reorder_params_refused_bad_order :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

pl{*}ace :: proc(x: int, y: int) {
}

main :: proc() {
	place(1, 2)
}
`,
	}
	test.expect_reorder_params(t, &source, {1, 1}, {})
}

@(test)
action_remove_param_only_param :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(un{*}used: int) {
	print(1)
}

main :: proc() {
	f(1)
}
`,
		config = {enable_code_action_remove_param = true},
	}
	test.expect_action_applied_files(t, &source, "Remove parameter unused", {{"main.odin", `package test

f :: proc() {
	print(1)
}

main :: proc() {
	f()
}
`}})
}

@(test)
action_remove_param_first_of_three :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

add :: proc(un{*}used: int, a: int, b: int) -> int {
	return a + b
}

main :: proc() {
	x := add(1, 2, 3)
}
`,
		config = {enable_code_action_remove_param = true},
	}
	test.expect_action_applied_files(t, &source, "Remove parameter unused", {{"main.odin", `package test

add :: proc(a: int, b: int) -> int {
	return a + b
}

main :: proc() {
	x := add(2, 3)
}
`}})
}

@(test)
action_remove_param_multi_line_caller_with_trailing_comma :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

add :: proc(a: int, un{*}used: int) -> int {
	return a
}

main :: proc() {
	x := add(
		1,
		2,
	)
}
`,
		config = {enable_code_action_remove_param = true},
	}
	test.expect_action_applied_files(t, &source, "Remove parameter unused", {{"main.odin", `package test

add :: proc(a: int) -> int {
	return a
}

main :: proc() {
	x := add(
		1,
	)
}
`}})
}

@(test)
action_remove_param_refused_variadic :: proc(t: ^testing.T) {
	expect_no_remove_param(t, "Remove parameter unused", `package test

f :: proc(un{*}used: int, xs: ..int) {
	print(1)
}

main :: proc() {
	f(1, 2)
}
`)
}

@(test)
action_remove_param_refused_side_effecting_argument :: proc(t: ^testing.T) {
	expect_no_remove_param(t, "Remove parameter unused", `package test

next :: proc() -> int {
	return 1
}

add :: proc(a: int, un{*}used: int) -> int {
	return a
}

main :: proc() {
	x := add(1, next())
}
`)
}

@(test)
action_remove_param_refused_name_reused_in_nested_proc_lit :: proc(t: ^testing.T) {
	expect_no_remove_param(t, "Remove parameter a", `package test

use :: proc(x: int) {
}

f :: proc({*}a: int) {
	g := proc(a: int) {
		use(a)
	}
	g(1)
}

main :: proc() {
	f(1)
}
`)
}

@(test)
action_remove_param_refused_used_in_when_block :: proc(t: ^testing.T) {
	expect_no_remove_param(t, "Remove parameter a", `package test

use :: proc(x: int) {
}

f :: proc({*}a: int) {
	when true {
		use(a)
	}
}

main :: proc() {
	f(1)
}
`)
}

@(test)
action_remove_param_refused_underscore_name :: proc(t: ^testing.T) {
	expect_no_remove_param(t, "Remove parameter _", `package test

f :: proc(a: int, {*}_: int) -> int {
	return a
}

main :: proc() {
	x := f(1, 2)
}
`)
}

@(test)
reorder_params_round_trip :: proc(t: ^testing.T) {
	rotated := `package test

place :: proc(name: string, x: int, y: int) {
}

main :: proc() {
	place("a", 1, 2)
}
`
	forward := test.Source {
		main = `package test

pl{*}ace :: proc(x: int, y: int, name: string) {
}

main :: proc() {
	place(1, 2, "a")
}
`,
	}
	test.expect_reorder_params(t, &forward, {2, 0, 1}, {{"main.odin", rotated}})

	back := test.Source {
		main = `package test

pl{*}ace :: proc(name: string, x: int, y: int) {
}

main :: proc() {
	place("a", 1, 2)
}
`,
	}
	test.expect_reorder_params(t, &back, {1, 2, 0}, {{"main.odin", `package test

place :: proc(x: int, y: int, name: string) {
}

main :: proc() {
	place(1, 2, "a")
}
`}})
}

@(test)
reorder_params_multi_line_caller :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

pl{*}ace :: proc(x: int, name: string) {
}

main :: proc() {
	place(
		1,
		"a",
	)
}
`,
	}
	test.expect_reorder_params(t, &source, {1, 0}, {{"main.odin", `package test

place :: proc(name: string, x: int) {
}

main :: proc() {
	place(
		"a",
		1,
	)
}
`}})
}

@(test)
reorder_params_refused_default_param :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

pl{*}ace :: proc(x: int, y: int = 1) {
}

main :: proc() {
	place(1, 2)
}
`,
	}
	test.expect_reorder_params(t, &source, {1, 0}, {})
}

@(test)
reorder_params_refused_caller_omits_an_argument :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

pl{*}ace :: proc(x: int, y: int) {
}

main :: proc() {
	place(1)
}
`,
	}
	test.expect_reorder_params(t, &source, {1, 0}, {})
}
