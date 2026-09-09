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

expect_extract_inline_round_trip :: proc(t: ^testing.T, main: string, cursor: string) {
	source := test.Source {
		main   = main,
		config = {enable_code_action_extract_variable = true, enable_code_action_inline_variable = true},
	}
	test.expect_action_round_trip(t, &source, {EXTRACT_VARIABLE_ACTION, INLINE_VARIABLE_ACTION}, {cursor})
}

expect_no_extract_variable :: proc(t: ^testing.T, main: string) {
	source := test.Source {
		main   = main,
		config = {enable_code_action_extract_variable = true},
	}
	test.expect_action_missing(t, &source, EXTRACT_VARIABLE_ACTION)
}

@(test)
action_extract_variable_round_trip_call :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(t, `package test

f :: proc(x: int) -> int {
	return x
}

main :: proc() {
	x := 1
	bar({[f(x)]})
}
`, "f2 :=")
}

@(test)
action_extract_variable_round_trip_binary_argument :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(t, `package test

main :: proc() {
	a, b := 1, 2
	bar({[a + b]})
}
`, "value :=")
}

@(test)
action_extract_variable_round_trip_index :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(t, `package test

main :: proc() {
	s := []int{1, 2}
	i := 0
	bar({[s[i]]})
}
`, "value :=")
}

@(test)
action_extract_variable_round_trip_selector_chain :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(t, `package test

Point :: struct {
	x: int,
}

Player :: struct {
	position: Point,
}

main :: proc() {
	p: Player
	bar({[p.position.x]})
}
`, "x :=")
}

@(test)
action_extract_variable_round_trip_literal :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(t, `package test

main :: proc() {
	bar({[1]})
}
`, "value :=")
}

@(test)
action_extract_variable_round_trip_string_with_braces :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(t, `package test

main :: proc() {
	bar({["{x}"]})
}
`, "value :=")
}

@(test)
action_extract_variable_round_trip_selection_with_spaces :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(t, `package test

main :: proc() {
	a, b := 1, 2
	bar({[ a + b ]})
}
`, "value :=")
}

@(test)
action_extract_variable_round_trip_ternary :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(t, `package test

main :: proc() {
	c := true
	bar({[c ? 1 : 2]})
}
`, "value :=")
}

@(test)
action_extract_variable_round_trip_paren :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(t, `package test

main :: proc() {
	a, b := 1, 2
	bar({[(a + b)]})
}
`, "value :=")
}

@(test)
action_extract_variable_round_trip_switch_case_body :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(t, `package test

main :: proc() {
	a, b := 1, 2
	switch a {
	case 1:
		bar({[a + b]})
	}
}
`, "value :=")
}

@(test)
action_extract_variable_round_trip_space_indented :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(t, `package test

main :: proc() {
    a, b := 1, 2
    bar({[a + b]})
}
`, "value :=")
}

@(test)
action_extract_variable_round_trip_name_taken :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(t, `package test

main :: proc() {
	a, b := 1, 2
	value := 0
	bar({[a + b]}, value)
}
`, "value2 :=")
}

@(test)
action_extract_variable_round_trip_callee_name_taken_twice :: proc(t: ^testing.T) {
	expect_extract_inline_round_trip(t, `package test

f :: proc(x: int) -> int {
	return x
}

main :: proc() {
	f2 := 1
	bar({[f(f2)]})
}
`, "f3 :=")
}

@(test)
action_extract_variable_refused_for_init :: proc(t: ^testing.T) {
	expect_no_extract_variable(t, `package test

main :: proc() {
	n := 3
	for i := {[n - 1]}; i >= 0; i -= 1 {
	}
}
`)
}

@(test)
action_extract_variable_refused_if_init :: proc(t: ^testing.T) {
	expect_no_extract_variable(t, `package test

main :: proc() {
	a, b := 1, 2
	if x := {[a + b]}; x > 0 {
	}
}
`)
}

@(test)
action_extract_variable_refused_do_body :: proc(t: ^testing.T) {
	expect_no_extract_variable(t, `package test

main :: proc() {
	a, b := 1, 2
	if a > 0 do bar({[a + b]})
}
`)
}
