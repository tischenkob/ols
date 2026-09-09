package tests

import "core:testing"

import test "src:testing"

EXTRACT_CONSTANT_ACTION :: "Extract constant"

expect_extract_constant :: proc(t: ^testing.T, main, expected: string) {
	source := test.Source {
		main   = main,
		config = {enable_code_action_extract_constant = true},
	}
	test.expect_action_applied(t, &source, EXTRACT_CONSTANT_ACTION, expected)
}

expect_no_extract_constant :: proc(t: ^testing.T, main: string, enabled := true) {
	source := test.Source {
		main   = main,
		config = {enable_code_action_extract_constant = enabled},
	}
	test.expect_action_missing(t, &source, EXTRACT_CONSTANT_ACTION)
}

@(test)
action_extract_constant_argument :: proc(t: ^testing.T) {
	expect_extract_constant(t, `package test

area :: proc(radius: f32) -> f32 {
	return radius * radius
}

main :: proc() {
	a := area(3.{*}14)
}
`, `package test

area :: proc(radius: f32) -> f32 {
	return radius * radius
}

RADIUS :: 3.14

main :: proc() {
	a := area(RADIUS)
}
`)
}

@(test)
action_extract_constant_variable :: proc(t: ^testing.T) {
	expect_extract_constant(t, `package test

main :: proc() {
	speed := {*}5
}
`, `package test

SPEED :: 5

main :: proc() {
	speed := SPEED
}
`)
}

@(test)
action_extract_constant_binary :: proc(t: ^testing.T) {
	expect_extract_constant(t, `package test

main :: proc() {
	x := 1
	if x > {[60 * 60]} {
	}
}
`, `package test

X_VALUE :: 60 * 60

main :: proc() {
	x := 1
	if x > X_VALUE {
	}
}
`)
}

@(test)
action_extract_constant_global :: proc(t: ^testing.T) {
	expect_extract_constant(t, `package test

SECONDS :: 60

main :: proc() {
	x := SECON{*}DS * 60
}
`, `package test

SECONDS :: 60

X :: SECONDS * 60

main :: proc() {
	x := X
}
`)
}

@(test)
action_extract_constant_comp_lit :: proc(t: ^testing.T) {
	expect_extract_constant(t, `package test

Vec2 :: struct {
	x, y: f32,
}

main :: proc() {
	origin := Vec2{{*}1, 2}
}
`, `package test

Vec2 :: struct {
	x, y: f32,
}

ORIGIN :: Vec2{1, 2}

main :: proc() {
	origin := ORIGIN
}
`)
}

@(test)
action_extract_constant_refused_local :: proc(t: ^testing.T) {
	expect_no_extract_constant(t, `package test

main :: proc() {
	a := 1
	x := {[a * 60]}
}
`)
}

@(test)
action_extract_constant_refused_ident :: proc(t: ^testing.T) {
	expect_no_extract_constant(t, `package test

SECONDS :: 60

main :: proc() {
	x := SEC{*}ONDS
}
`)
}

@(test)
action_extract_constant_collision :: proc(t: ^testing.T) {
	expect_extract_constant(t, `package test

SPEED :: 1

main :: proc() {
	speed := {*}5
}
`, `package test

SPEED :: 1

SPEED2 :: 5

main :: proc() {
	speed := SPEED2
}
`)
}

@(test)
action_extract_constant_doc_comment :: proc(t: ^testing.T) {
	expect_extract_constant(t, `package test

// Entry point.
main :: proc() {
	speed := {*}5
}
`, `package test

SPEED :: 5

// Entry point.
main :: proc() {
	speed := SPEED
}
`)
}

@(test)
action_extract_constant_disabled :: proc(t: ^testing.T) {
	expect_no_extract_constant(t, `package test

main :: proc() {
	speed := {*}5
}
`, enabled = false)
}
