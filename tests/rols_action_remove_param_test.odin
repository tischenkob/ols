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
