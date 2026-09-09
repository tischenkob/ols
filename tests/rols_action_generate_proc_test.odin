package tests

import "core:strings"
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

@(test)
generate_proc_no_arguments :: proc(t: ^testing.T) {
	expect_generate_proc(t, `package test

main :: proc() {
	na{*}me()
}
`, `package test

main :: proc() {
	name()
}

name :: proc() {
}
`)
}

@(test)
generate_proc_struct_pointer_and_slice :: proc(t: ^testing.T) {
	expect_generate_proc(t, `package test

Point :: struct { x, y: int }

main :: proc() {
	p := Point{}
	na{*}me(p, &p, []int{1, 2})
}
`, `package test

Point :: struct { x, y: int }

main :: proc() {
	p := Point{}
	name(p, &p, []int{1, 2})
}

name :: proc(p: Point, arg2: ^Point, arg3: []int) {
}
`)
}

@(test)
generate_proc_procedure_value :: proc(t: ^testing.T) {
	expect_generate_proc(t, `package test

other :: proc(a: int) -> bool { return true }

main :: proc() {
	na{*}me(other)
}
`, `package test

other :: proc(a: int) -> bool { return true }

main :: proc() {
	name(other)
}

name :: proc(other: proc(a: int) -> bool) {
}
`)
}

@(test)
generate_proc_named_argument :: proc(t: ^testing.T) {
	expect_generate_proc(t, `package test

main :: proc() {
	na{*}me(a = 1)
}
`, `package test

main :: proc() {
	name(a = 1)
}

name :: proc(a: int) {
}
`)
}

@(test)
generate_proc_qualified_call :: proc(t: ^testing.T) {
	expect_no_generate_proc(t, `package test

main :: proc() {
	pkg.na{*}me()
}
`)
}

@(test)
generate_proc_name_of_a_type :: proc(t: ^testing.T) {
	expect_no_generate_proc(t, `package test

name :: struct { x: int }

main :: proc() {
	na{*}me()
}
`)
}

@(test)
generate_proc_in_a_proc_literal :: proc(t: ^testing.T) {
	expect_generate_proc(t, `package test

main :: proc() {
	g := proc() {
		na{*}me()
	}
	g()
}
`, `package test

main :: proc() {
	g := proc() {
		name()
	}
	g()
}

name :: proc() {
}
`)
}

@(test)
generate_proc_before_the_next_doc_comment :: proc(t: ^testing.T) {
	expect_generate_proc(t, `package test

main :: proc() {
	na{*}me()
}

// Does something else.
other :: proc() {}
`, `package test

main :: proc() {
	name()
}

name :: proc() {
}

// Does something else.
other :: proc() {}
`)
}

@(test)
generate_proc_twice :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	na{*}me()
}
`,
		config = {enable_code_action_generate_proc = true},
	}
	once, ok := test.apply_action(t, &source, "Generate procedure name")
	if !ok {
		return
	}
	again := test.Source {
		main   = strings.replace(once, "\tname()", "\tna{*}me()", 1, context.temp_allocator) or_else once,
		config = {enable_code_action_generate_proc = true},
	}
	test.expect_action_missing(t, &again, "Generate procedure name")
}

