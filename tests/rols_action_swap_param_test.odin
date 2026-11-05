package tests

import "core:testing"

import test "src:testing"

@(private = "file")
LEFT :: "Move parameter left"
@(private = "file")
RIGHT :: "Move parameter right"

@(private = "file")
swap_source :: proc(main: string, files: []test.File = {}) -> test.Source {
	return {main = main, files = files, config = {enable_code_action_swap_param = true}}
}

@(test)
swap_param_right_updates_call_sites_in_another_file :: proc(t: ^testing.T) {
	source := swap_source(
		`package test

place :: proc(x{*}: int, y: int, name: string) {
}

main :: proc() {
	place(1, 2, "a")
}
`,
		{{"b.odin", `package test

other :: proc() {
	place(3, 4, "b")
}
`}},
	)
	test.expect_action_applied_files(
		t,
		&source,
		RIGHT,
		{
			{
				"main.odin",
				`package test

place :: proc(y: int, x: int, name: string) {
}

main :: proc() {
	place(2, 1, "a")
}
`,
			},
			{"b.odin", `package test

other :: proc() {
	place(4, 3, "b")
}
`},
		},
	)
}

@(test)
swap_param_left_from_the_type_of_the_parameter :: proc(t: ^testing.T) {
	source := swap_source(
		`package test

place :: proc(x: int, name: st{*}ring) {
}

main :: proc() {
	place(1, "a")
}
`,
	)
	test.expect_action_applied(
		t,
		&source,
		LEFT,
		`package test

place :: proc(name: string, x: int) {
}

main :: proc() {
	place("a", 1)
}
`,
	)
}

@(test)
swap_param_splits_a_shared_type :: proc(t: ^testing.T) {
	source := swap_source(`package test

place :: proc(a{*}, b: int) {
}
`)
	test.expect_action_applied(t, &source, RIGHT, `package test

place :: proc(b: int, a: int) {
}
`)
}

@(test)
swap_param_each_direction_needs_its_neighbor :: proc(t: ^testing.T) {
	first := swap_source(`package test

place :: proc(x{*}: int, y: int) {
}
`)
	test.expect_action_missing(t, &first, LEFT)
	last := swap_source(`package test

place :: proc(x: int, y{*}: int) {
}
`)
	test.expect_action_missing(t, &last, RIGHT)
}

@(test)
swap_param_refuses_a_procedure_used_as_a_value :: proc(t: ^testing.T) {
	main := `package test

place :: proc(x{*}: int, y: int) {
}

main :: proc() {
	f := place
	f(1, 2)
}
`
	source := swap_source(main)
	test.expect_action_missing(t, &source, RIGHT)
}

@(test)
swap_param_refuses_a_single_parameter :: proc(t: ^testing.T) {
	source := swap_source(`package test

place :: proc(x{*}: int) {
}
`)
	test.expect_action_missing(t, &source, RIGHT)
	again := swap_source(`package test

place :: proc(x{*}: int) {
}
`)
	test.expect_action_missing(t, &again, LEFT)
}

@(test)
swap_param_refuses_outside_a_parameter :: proc(t: ^testing.T) {
	in_body := swap_source(`package test

place :: proc(x: int, y: int) {
	_ = x{*}
}
`)
	test.expect_action_missing(t, &in_body, LEFT)
	on_name := swap_source(`package test

pl{*}ace :: proc(x: int, y: int) {
}
`)
	test.expect_action_missing(t, &on_name, RIGHT)
}

@(test)
swap_param_refuses_a_local_procedure :: proc(t: ^testing.T) {
	source := swap_source(`package test

main :: proc() {
	place := proc(x{*}: int, y: int) {
	}
	place(1, 2)
}
`)
	test.expect_action_missing(t, &source, RIGHT)
}

@(test)
swap_param_refuses_what_signature_problem_refuses :: proc(t: ^testing.T) {
	poly := swap_source(`package test

place :: proc(x{*}: $T, y: T) {
}
`)
	test.expect_action_missing(t, &poly, RIGHT)
	default_value := swap_source(`package test

place :: proc(x{*}: int, y := 2) {
}
`)
	test.expect_action_missing(t, &default_value, RIGHT)
	variadic := swap_source(`package test

place :: proc(x{*}: int, y: ..int) {
}
`)
	test.expect_action_missing(t, &variadic, RIGHT)
}

@(test)
swap_param_refuses_a_named_argument :: proc(t: ^testing.T) {
	source := swap_source(
		`package test

place :: proc(x{*}: int, y: int) {
}

main :: proc() {
	place(x = 1, y = 2)
}
`,
	)
	test.expect_action_missing(t, &source, RIGHT)
}

@(test)
swap_param_refuses_arguments_with_side_effects :: proc(t: ^testing.T) {
	source := swap_source(
		`package test

next :: proc() -> int {
	return 1
}

place :: proc(x{*}: int, y: int) {
}

main :: proc() {
	v := 1
	place(v, next())
}
`,
	)
	test.expect_action_missing(t, &source, RIGHT)
}

@(test)
swap_param_keeps_an_argument_with_side_effects_it_does_not_cross :: proc(t: ^testing.T) {
	source := swap_source(
		`package test

next :: proc() -> int {
	return 1
}

place :: proc(x{*}: int, y: int, z: int) {
}

main :: proc() {
	place(1, 2, next())
}
`,
	)
	test.expect_action_applied(
		t,
		&source,
		RIGHT,
		`package test

next :: proc() -> int {
	return 1
}

place :: proc(y: int, x: int, z: int) {
}

main :: proc() {
	place(2, 1, next())
}
`,
	)
}

@(test)
swap_param_keeps_a_nested_call_it_does_not_cross :: proc(t: ^testing.T) {
	source := swap_source(
		`package test

place :: proc(x{*}: int, y: int, z: int) -> int {
	return z
}

main :: proc() {
	_ = place(1, 2, place(3, 4, 5))
}
`,
	)
	test.expect_action_applied(
		t,
		&source,
		RIGHT,
		`package test

place :: proc(y: int, x: int, z: int) -> int {
	return z
}

main :: proc() {
	_ = place(2, 1, place(4, 3, 5))
}
`,
	)
}

@(test)
swap_param_refuses_a_nested_call_it_crosses :: proc(t: ^testing.T) {
	source := swap_source(
		`package test

place :: proc(x{*}: int, y: int) -> int {
	return y
}

main :: proc() {
	_ = place(place(1, 2), 3)
}
`,
	)
	test.expect_action_missing(t, &source, RIGHT)
}

@(test)
swap_param_refuses_a_variable_or_a_declared_type :: proc(t: ^testing.T) {
	typed_variable := swap_source(`package test

place: proc(x: int, y: string) = proc(x{*}: int, y: string) {
}
`)
	test.expect_action_missing(t, &typed_variable, RIGHT)
	variable := swap_source(`package test

place := proc(x{*}: int, y: string) {
}
`)
	test.expect_action_missing(t, &variable, RIGHT)
	typed_constant := swap_source(`package test

place: proc(x: int, y: string) : proc(x{*}: int, y: string) {
}
`)
	test.expect_action_missing(t, &typed_constant, RIGHT)
	typed_variant := swap_source(
		`package test

when ODIN_OS == .Windows {
	place :: proc(x{*}: int, y: string) {
	}
} else {
	place: proc(x: int, y: string) : proc(x: int, y: string) {
	}
}
`,
	)
	test.expect_action_missing(t, &typed_variant, RIGHT)
}

@(test)
swap_param_disappears_with_its_flag :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

place :: proc(x{*}: int, y: int) {
}
`,
	}
	test.expect_action_missing(t, &source, RIGHT)
}
