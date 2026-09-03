package tests

import "core:testing"

import test "src:testing"

EXTRACT_VARIABLE_ACTION :: "Extract variable"

@(test)
action_extract_variable_call_selection :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

foo :: proc(x: int) -> int {
	return x
}

main :: proc() {
	if {[foo(1)]} > 0 {
		bar()
	}
}
`,
		packages = {},
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_applied(t, &source, EXTRACT_VARIABLE_ACTION, `package test

foo :: proc(x: int) -> int {
	return x
}

main :: proc() {
	foo2 := foo(1)
	if foo2 > 0 {
		bar()
	}
}
`)
}

@(test)
action_extract_variable_binary_in_decl :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := 1, 2
	y := {[a * b]} + 2
}
`,
		packages = {},
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_applied(t, &source, EXTRACT_VARIABLE_ACTION, `package test

main :: proc() {
	a, b := 1, 2
	value := a * b
	y := value + 2
}
`)
}

@(test)
action_extract_variable_cursor_on_selector :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Point :: struct {
	x: int,
}

Player :: struct {
	position: Point,
}

main :: proc() {
	p: Player
	foo(p.posi{*}tion.x)
}
`,
		packages = {},
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_applied(t, &source, EXTRACT_VARIABLE_ACTION, `package test

Point :: struct {
	x: int,
}

Player :: struct {
	position: Point,
}

main :: proc() {
	p: Player
	position := p.position
	foo(position.x)
}
`)
}

@(test)
action_extract_variable_name_collision :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	value := 1
	x := {[value * 2]} + 3
}
`,
		packages = {},
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_applied(t, &source, EXTRACT_VARIABLE_ACTION, `package test

main :: proc() {
	value := 1
	value2 := value * 2
	x := value2 + 3
}
`)
}

@(test)
action_extract_variable_refused_lhs :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Point :: struct {
	x: int,
}

main :: proc() {
	p: Point
	{[p.x]} = 5
}
`,
		packages = {},
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, EXTRACT_VARIABLE_ACTION)
}

@(test)
action_extract_variable_refused_type :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x: {[[]int]}
}
`,
		packages = {},
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, EXTRACT_VARIABLE_ACTION)
}

@(test)
action_extract_variable_refused_loop_condition :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	i, n := 0, 3
	for {[i < n]} {
		i += 1
	}
}
`,
		packages = {},
		config = {enable_code_action_extract_variable = true},
	}

	test.expect_action_missing(t, &source, EXTRACT_VARIABLE_ACTION)
}

@(test)
action_extract_variable_disabled :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := 1, 2
	y := {[a * b]} + 2
}
`,
		packages = {},
		config = {enable_code_action_extract_variable = false},
	}

	test.expect_action_missing(t, &source, EXTRACT_VARIABLE_ACTION)
}
