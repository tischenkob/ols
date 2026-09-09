package tests

import "core:testing"

import test "src:testing"

expect_generate_proc :: proc(t: ^testing.T, main, expected: string) {
	source := test.Source{main = main, config = {enable_code_action_generate_proc = true}}
	test.expect_action_applied(t, &source, "Generate procedure name", expected)
}

expect_no_generate_proc :: proc(t: ^testing.T, main: string, enabled := true) {
	source := test.Source{main = main, config = {enable_code_action_generate_proc = enabled}}
	test.expect_action_missing(t, &source, "Generate procedure name")
}

@(test)
generate_proc_statement :: proc(t: ^testing.T) {
	expect_generate_proc(t, `package test

main :: proc() {
	x := 5
	na{*}me(x, "hi")
}
`, `package test

main :: proc() {
	x := 5
	name(x, "hi")
}

name :: proc(x: int, arg2: string) {
}
`)
}

@(test)
generate_proc_if_condition :: proc(t: ^testing.T) {
	expect_generate_proc(t, `package test

main :: proc() {
	if na{*}me() {
	}
}
`, `package test

main :: proc() {
	if name() {
	}
}

name :: proc() -> bool {
	return false
}
`)
}

@(test)
generate_proc_typed_decl :: proc(t: ^testing.T) {
	expect_generate_proc(t, `package test

main :: proc() {
	y := 2
	x: f32 = na{*}me(y)
}
`, `package test

main :: proc() {
	y := 2
	x: f32 = name(y)
}

name :: proc(y: int) -> f32 {
	return 0
}
`)
}

@(test)
generate_proc_return :: proc(t: ^testing.T) {
	expect_generate_proc(t, `package test

Point :: struct { x, y: int }

f :: proc(a: Point) -> int {
	return na{*}me(a)
}
`, `package test

Point :: struct { x, y: int }

f :: proc(a: Point) -> int {
	return name(a)
}

name :: proc(a: Point) -> int {
	return 0
}
`)
}

@(test)
generate_proc_argument :: proc(t: ^testing.T) {
	expect_generate_proc(t, `package test

Point :: struct { x, y: int }

foo :: proc(v: Point) {
}

main :: proc() {
	p := Point{}
	foo(na{*}me(p.x))
}
`, `package test

Point :: struct { x, y: int }

foo :: proc(v: Point) {
}

main :: proc() {
	p := Point{}
	foo(name(p.x))
}

name :: proc(x: int) -> Point {
	return {}
}
`)
}

@(test)
generate_proc_resolved :: proc(t: ^testing.T) {
	expect_no_generate_proc(t, `package test

name :: proc() {
}

main :: proc() {
	na{*}me()
}
`)
}

@(test)
generate_proc_unknown_argument :: proc(t: ^testing.T) {
	expect_no_generate_proc(t, `package test

main :: proc() {
	na{*}me(unknown)
}
`)
}

@(test)
generate_proc_unknown_result :: proc(t: ^testing.T) {
	expect_no_generate_proc(t, `package test

main :: proc() {
	x := na{*}me()
}
`)
}

@(test)
generate_proc_disabled :: proc(t: ^testing.T) {
	expect_no_generate_proc(t, `package test

main :: proc() {
	na{*}me()
}
`, false)
}
