package tests

import "core:strings"
import "core:testing"

import test "src:testing"

@(private = "file")
BY_POINTER :: "Pass by pointer"
@(private = "file")
BY_VALUE :: "Pass by value"

@(private = "file")
pointer_source :: proc(main: string, files: []test.File = {}, enabled := true) -> test.Source {
	return {main = main, files = files, config = {enable_code_action_param_pointer = enabled}}
}

@(private = "file")
expect_no_param_pointer :: proc(t: ^testing.T, title, main: string, files: []test.File = {}, enabled := true) {
	source := pointer_source(main, files, enabled)
	test.expect_action_missing(t, &source, title)
}

// A selector reads a struct field through the pointer, a plain use dereferences it, and each call passes an address,
// also in another file.
@(test)
param_pointer_by_pointer_across_files :: proc(t: ^testing.T) {
	source := pointer_source(
		`package test

Point :: struct {
	x, y: f32,
}

area :: proc(p{*}: Point, scale: f32) -> f32 {
	q := p
	return p.x * q.y * scale
}

main :: proc() {
	pt := Point{1, 2}
	_ = area(pt, 2)
}
`,
		{
			{
				"b.odin",
				`package test

Box :: struct {
	corner: Point,
}

other :: proc(box: ^Box) {
	_ = area(box.corner, 1)
}
`,
			},
		},
	)
	test.expect_action_applied_files(
		t,
		&source,
		BY_POINTER,
		{
			{
				"main.odin",
				`package test

Point :: struct {
	x, y: f32,
}

area :: proc(p: ^Point, scale: f32) -> f32 {
	q := p^
	return p.x * q.y * scale
}

main :: proc() {
	pt := Point{1, 2}
	_ = area(&pt, 2)
}
`,
			},
			{
				"b.odin",
				`package test

Box :: struct {
	corner: Point,
}

other :: proc(box: ^Box) {
	_ = area(&box.corner, 1)
}
`,
			},
		},
	)
}

// A field that declares several names is split, and a value that is no struct is read through `^`.
@(test)
param_pointer_by_pointer_splits_a_field :: proc(t: ^testing.T) {
	source := pointer_source(
		`package test

add :: proc(a, b{*}: int) -> int {
	return a + b
}

main :: proc() {
	x := 1
	_ = add(1, x)
}
`,
	)
	test.expect_action_applied(
		t,
		&source,
		BY_POINTER,
		`package test

add :: proc(a: int, b: ^int) -> int {
	return a + b^
}

main :: proc() {
	x := 1
	_ = add(1, &x)
}
`,
	)
}

@(test)
param_pointer_by_value :: proc(t: ^testing.T) {
	source := pointer_source(
		`package test

Point :: struct {
	x, y: f32,
}

shift :: proc(p{*}: ^Point, d: f32) -> f32 {
	return p^.x + p.y + d
}

forward :: proc(p: ^Point) -> f32 {
	return shift(p, 1)
}

main :: proc() {
	pt := Point{1, 2}
	_ = shift(&pt, 1)
}
`,
	)
	test.expect_action_applied(
		t,
		&source,
		BY_VALUE,
		`package test

Point :: struct {
	x, y: f32,
}

shift :: proc(p: Point, d: f32) -> f32 {
	return p.x + p.y + d
}

forward :: proc(p: ^Point) -> f32 {
	return shift(p^, 1)
}

main :: proc() {
	pt := Point{1, 2}
	_ = shift(pt, 1)
}
`,
	)
}

@(test)
param_pointer_by_pointer_refuses_an_argument_without_an_address :: proc(t: ^testing.T) {
	arguments := []string{"1", "f()", "K", "n", "m[0]"}
	for argument in arguments {
		main := strings.concatenate(
			{
				"package test\n\nK :: 3\n\nf :: proc() -> int {\n\treturn 1\n}\n\ntake :: proc(x{*}: int) -> int {\n\treturn x\n}\n\nmain :: proc(n: int) {\n\tm: map[int]int\n\t_ = take(",
				argument,
				")\n\t_ = m\n}\n",
			},
			context.temp_allocator,
		)
		expect_no_param_pointer(t, BY_POINTER, main)
	}
}

// The argument would no longer convert to `any`, a union or `rawptr`.
@(test)
param_pointer_by_pointer_refuses_a_converting_type :: proc(t: ^testing.T) {
	for type in ([]string{"any", "Maybe(int)", "rawptr", "^int"}) {
		main := strings.concatenate(
			{"package test\n\ntake :: proc(x{*}: ", type, ") {\n\t_ = x\n}\n"},
			context.temp_allocator,
		)
		expect_no_param_pointer(t, BY_POINTER, main)
	}
}

// A copy would hide from the caller what the body writes, and a stored or compared pointer is not a value.
@(test)
param_pointer_by_value_refuses_uses_of_the_pointer :: proc(t: ^testing.T) {
	bodies := []string{"p^ = 1", "p^ += 1", "_ = p == nil", "q := p\n\t_ = q", "store(p)", "_ = &p^"}
	for body in bodies {
		main := strings.concatenate(
			{
				"package test\n\nstore :: proc(p: ^int) {}\n\ntake :: proc(p{*}: ^int) {\n\t",
				body,
				"\n}\n\nmain :: proc() {\n\tx := 1\n\ttake(&x)\n}\n",
			},
			context.temp_allocator,
		)
		expect_no_param_pointer(t, BY_VALUE, main)
	}
	field := "package test\n\nPoint :: struct {\n\tx: int,\n}\n\ntake :: proc(p{*}: ^Point) {\n\tp.x = 1\n}\n"
	expect_no_param_pointer(t, BY_VALUE, field)
}

// A procedure used as a value would keep the old type.
@(test)
param_pointer_refuses_a_value_use :: proc(t: ^testing.T) {
	main := "package test\n\ntake :: proc(x{*}: int) -> int {\n\treturn x\n}\n\nkeep := take\n"
	expect_no_param_pointer(t, BY_POINTER, main)
}

@(test)
param_pointer_refuses_when_disabled :: proc(t: ^testing.T) {
	expect_no_param_pointer(
		t,
		BY_POINTER,
		"package test\n\ntake :: proc(x{*}: int) -> int {\n\treturn x\n}\n",
		enabled = false,
	)
	expect_no_param_pointer(
		t,
		BY_VALUE,
		"package test\n\ntake :: proc(x{*}: ^int) -> int {\n\treturn x^\n}\n",
		enabled = false,
	)
}
