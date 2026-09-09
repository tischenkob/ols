package tests

import "core:testing"

import test "src:testing"

INTRODUCE_PARAM_ACTION :: "Introduce parameter"

expect_introduce_param :: proc(t: ^testing.T, main, expected: string) {
	source := test.Source {
		main   = main,
		config = {enable_code_action_introduce_param = true},
	}
	test.expect_action_applied_files(t, &source, INTRODUCE_PARAM_ACTION, {{"main.odin", expected}})
}

expect_no_introduce_param :: proc(t: ^testing.T, main: string, files: []test.File = {}, enabled := true) {
	source := test.Source {
		main   = main,
		files  = files,
		config = {enable_code_action_introduce_param = enabled},
	}
	test.expect_action_missing(t, &source, INTRODUCE_PARAM_ACTION)
}

@(test)
action_introduce_param_two_callers :: proc(t: ^testing.T) {
	expect_introduce_param(t, `package test

grow :: proc(x: int) -> int {
	return x * {*}2
}

main :: proc() {
	a := grow(1)
	b := grow(a)
}
`, `package test

grow :: proc(x: int, value: int) -> int {
	return x * value
}

main :: proc() {
	a := grow(1, 2)
	b := grow(a, 2)
}
`)
}

@(test)
action_introduce_param_no_params_named_by_argument :: proc(t: ^testing.T) {
	expect_introduce_param(t, `package test

area :: proc(radius: f32) -> f32 {
	return radius * radius
}

run :: proc() {
	a := area({[3.5]})
}

main :: proc() {
	run()
}
`, `package test

area :: proc(radius: f32) -> f32 {
	return radius * radius
}

run :: proc(radius: f64) {
	a := area(radius)
}

main :: proc() {
	run(3.5)
}
`)
}

@(test)
action_introduce_param_caller_in_other_file :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

greet :: proc(name: string) -> string {
	return {["hi "]} + name
}
`,
		files = {
			{"b.odin", `package test

main :: proc() {
	s := greet("bob")
}
`},
		},
		config = {enable_code_action_introduce_param = true},
	}
	test.expect_action_applied_files(
		t,
		&source,
		INTRODUCE_PARAM_ACTION,
		{
			{"main.odin", `package test

greet :: proc(name: string, value: string) -> string {
	return value + name
}
`},
			{"b.odin", `package test

main :: proc() {
	s := greet("bob", "hi ")
}
`},
		},
	)
}

@(test)
action_introduce_param_refused_not_constant :: proc(t: ^testing.T) {
	expect_no_introduce_param(t, `package test

grow :: proc(x: int) -> int {
	y := 3
	return x * {[y + 1]}
}

main :: proc() {
	a := grow(1)
}
`)
}

@(test)
action_introduce_param_refused_used_as_value :: proc(t: ^testing.T) {
	expect_no_introduce_param(t, `package test

grow :: proc(x: int) -> int {
	return x * {*}2
}

main :: proc() {
	f := grow
	a := f(1)
}
`)
}

@(test)
action_introduce_param_refused_named_argument_in_other_file :: proc(t: ^testing.T) {
	expect_no_introduce_param(t, `package test

grow :: proc(x: int) -> int {
	return x * {*}2
}
`, {{"b.odin", `package test

main :: proc() {
	a := grow(x = 1)
}
`}})
}

@(test)
action_introduce_param_disabled :: proc(t: ^testing.T) {
	expect_no_introduce_param(t, `package test

grow :: proc(x: int) -> int {
	return x * {*}2
}

main :: proc() {
	a := grow(1)
}
`, enabled = false)
}
