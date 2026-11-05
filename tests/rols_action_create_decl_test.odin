#+feature dynamic-literals
package tests

import "core:testing"

import test "src:testing"

LOCAL_X :: "Create local variable x"
GLOBAL_X :: "Create global variable x"
CONSTANT_X :: "Create constant x"

expect_create_decl :: proc(t: ^testing.T, title, main, expected: string) {
	source := test.Source {
		main = main,
		config = {enable_code_action_create_decl = true},
	}
	test.expect_action_applied(t, &source, title, expected)
}

expect_no_create_decl :: proc(t: ^testing.T, title, main: string, enabled := true) {
	source := test.Source {
		main = main,
		config = {enable_code_action_create_decl = enabled},
	}
	test.expect_action_missing(t, &source, title)
}

@(test)
create_local_from_assignment :: proc(t: ^testing.T) {
	expect_create_decl(t, LOCAL_X, `package test

main :: proc() {
	{*}x = "s"
	_ = x
}
`, `package test

main :: proc() {
	x := "s"
	_ = x
}
`)
}

@(test)
create_local_from_parameter :: proc(t: ^testing.T) {
	expect_create_decl(t, LOCAL_X, `package test

take :: proc(v: []f32) {}

main :: proc() {
	take({*}x)
	take(x)
}
`, `package test

take :: proc(v: []f32) {}

main :: proc() {
	x: []f32
	take(x)
	take(x)
}
`)
}

@(test)
create_local_from_operand :: proc(t: ^testing.T) {
	expect_create_decl(t, LOCAL_X, `package test

main :: proc() {
	n: i32 = 1
	if n < {*}x {
	}
}
`, `package test

main :: proc() {
	n: i32 = 1
	x: i32
	if n < x {
	}
}
`)
}

@(test)
create_local_when_the_value_reads_the_name :: proc(t: ^testing.T) {
	expect_create_decl(t, LOCAL_X, `package test

twice :: proc(v: int) -> int {return v * 2}

main :: proc() {
	{*}x = twice(x)
}
`, `package test

twice :: proc(v: int) -> int {return v * 2}

main :: proc() {
	x: int
	x = twice(x)
}
`)
}

@(test)
create_local_adds_the_import_of_a_parameter_type :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "core:lib"

main :: proc() {
	lib.take({*}x)
}
`,
		packages = {{pkg = "lib", source = "package lib\n\nItem :: struct {}\n\ntake :: proc(v: Item) {}\n"}},
		collections = {"core" = "test"},
		config = {enable_code_action_create_decl = true},
	}
	test.expect_action_applied(t, &source, LOCAL_X, `package test

import "core:lib"

main :: proc() {
	x: lib.Item
	lib.take(x)
}
`)
}

@(test)
create_global_from_parameter :: proc(t: ^testing.T) {
	expect_create_decl(t, GLOBAL_X, `package test

take :: proc(v: []f32) {}

main :: proc() {
	take({*}x)
}
`, `package test

take :: proc(v: []f32) {}

main :: proc() {
	take(x)
}

x: []f32
`)
}

@(test)
create_global_from_assignment_keeps_it :: proc(t: ^testing.T) {
	expect_create_decl(t, GLOBAL_X, `package test

main :: proc() {
	{*}x = 2
}
`, `package test

main :: proc() {
	x = 2
}

x: int
`)
}

@(test)
create_constant_from_a_literal :: proc(t: ^testing.T) {
	expect_create_decl(t, CONSTANT_X, `package test

main :: proc() {
	{*}x = 1 + 2
	y := x
	_ = y
}
`, `package test

main :: proc() {
	y := x
	_ = y
}

x :: 1 + 2
`)
}

@(test)
create_struct_from_a_literal :: proc(t: ^testing.T) {
	expect_create_decl(t, "Create struct Foo", `package test

main :: proc() {
	s := "t"
	v := Fo{*}o{a = 1, b = s, c = 2.5, d = true, e = []int{1}}
	_ = v
}
`, `package test

main :: proc() {
	s := "t"
	v := Foo{a = 1, b = s, c = 2.5, d = true, e = []int{1}}
	_ = v
}

Foo :: struct {
	a: int,
	b: string,
	c: f64,
	d: bool,
	e: []int,
}
`)
}

@(test)
create_struct_at_file_scope_and_empty :: proc(t: ^testing.T) {
	expect_create_decl(t, "Create struct Foo", `package test

v := Fo{*}o{}
`, `package test

v := Foo{}

Foo :: struct {}
`)
}

@(test)
create_struct_assigned_to_blank_reading_a_local_of_the_same_name :: proc(t: ^testing.T) {
	expect_create_decl(t, "Create struct Foo", `package test

main :: proc() {
	a := "s"
	_ = Fo{*}o{a = a}
}
`, `package test

main :: proc() {
	a := "s"
	_ = Foo{a = a}
}

Foo :: struct {
	a: string,
}
`)
}

@(test)
create_struct_refuses :: proc(t: ^testing.T) {
	title := "Create struct Foo"
	// A positional literal.
	expect_no_create_decl(t, title, `package test

main :: proc() {
	_ = Fo{*}o{1, 2}
}
`)
	// A value of unknown type.
	expect_no_create_decl(t, title, `package test

main :: proc() {
	_ = Fo{*}o{a = unknown}
}
`)
	expect_no_create_decl(t, title, `package test

main :: proc() {
	_ = Fo{*}o{a = {1, 2}}
}
`)
	// A repeated key, a resolved type and a package.
	expect_no_create_decl(t, title, `package test

main :: proc() {
	_ = Fo{*}o{a = 1, a = 2}
}
`)
	expect_no_create_decl(t, title, `package test

Foo :: struct {
	a: int,
}

main :: proc() {
	_ = Fo{*}o{a = 1}
}
`)
	expect_no_create_decl(t, title, `package test

main :: proc() {
	_ = lib.Fo{*}o{a = 1}
}
`)
	// The place of the literal has a type of its own.
	expect_no_create_decl(t, title, `package test

take :: proc(v: int) {}

main :: proc() {
	take(Fo{*}o{a = 1})
}
`)
	// A local type has no meaning at file scope, and a field name shadows its own type.
	expect_no_create_decl(t, title, `package test

main :: proc() {
	Bar :: struct {}
	_ = Fo{*}o{a = Bar{}}
}
`)
	expect_no_create_decl(t, title, `package test

Bar :: struct {}

main :: proc() {
	_ = Fo{*}o{Bar = Bar{}}
}
`)
}

ALL_CREATE_DECL_TITLES :: []string{LOCAL_X, GLOBAL_X, CONSTANT_X}

expect_no_create_name :: proc(t: ^testing.T, main: string, enabled := true) {
	for title in ALL_CREATE_DECL_TITLES {
		expect_no_create_decl(t, title, main, enabled)
	}
}

@(test)
create_name_refuses_a_resolved_name :: proc(t: ^testing.T) {
	expect_no_create_name(t, `package test

main :: proc() {
	x := 1
	{*}x = 2
}
`)
	expect_no_create_name(t, `package test

x := 1

main :: proc() {
	{*}x = 2
}
`)
}

@(test)
create_name_refuses_a_package_root :: proc(t: ^testing.T) {
	expect_no_create_name(t, `package test

main :: proc() {
	{*}x.foo = 2
}
`)
}

@(test)
create_name_refuses_without_a_type :: proc(t: ^testing.T) {
	// No use gives a type.
	expect_no_create_name(t, `package test

main :: proc() {
	y := {*}x
	_ = y
}
`)
	expect_no_create_name(t, `package test

main :: proc() {
	_ = {*}x
}
`)
	expect_no_create_name(t, `package test

main :: proc() {
	{*}x = unknown
}
`)
	// `x := two()` holds two values.
	expect_no_create_name(t, `package test

two :: proc() -> (int, bool) {return 1, true}

main :: proc() {
	{*}x = two()
}
`)
	expect_no_create_name(t, `package test

main :: proc() {
	{*}x = nil
}
`)
	expect_no_create_name(t, `package test

take :: proc(v: ..int) {}

main :: proc() {
	take({*}x)
}
`)
	expect_no_create_name(t, `package test

take :: proc(v: $T) {}

main :: proc() {
	take({*}x)
}
`)
	// A shift amount has its own type.
	expect_no_create_name(t, `package test

main :: proc() {
	n := 1
	n <<= {*}x
}
`)
	// A callee belongs to Generate procedure, and a key to its literal.
	expect_no_create_name(t, `package test

main :: proc() {
	{*}x(1)
}
`)
	expect_no_create_name(t, `package test

Foo :: struct {
	a: int,
}

main :: proc() {
	_ = Foo{{*}x = 1}
}
`)
}

@(test)
create_local_refuses_a_use_it_cannot_reach :: proc(t: ^testing.T) {
	// An earlier use.
	expect_no_create_decl(t, LOCAL_X, `package test

take :: proc(v: int) {}

main :: proc() {
	take(x)
	take({*}x)
}
`)
	// A later use outside the block.
	expect_no_create_decl(t, LOCAL_X, `package test

take :: proc(v: int) {}

main :: proc() {
	if true {
		{*}x = 1
	}
	take(x)
}
`)
	// A later declaration of the name.
	expect_no_create_name(t, `package test

main :: proc() {
	{*}x = 1
	x := 2
	_ = x
}
`)
	// A statement that shares its line, and a label above.
	expect_no_create_decl(t, LOCAL_X, `package test

take :: proc(v: int) {}

main :: proc() {
	if true do take({*}x)
}
`)
	expect_no_create_decl(t, LOCAL_X, `package test

take :: proc(v: int) -> bool {return true}

main :: proc() {
	outer:
	for take({*}x) {
		break outer
	}
}
`)
}

@(test)
create_constant_refuses :: proc(t: ^testing.T) {
	// No constant value at the use.
	expect_no_create_decl(t, CONSTANT_X, `package test

take :: proc(v: int) {}

main :: proc() {
	take({*}x)
}
`)
	expect_no_create_decl(t, CONSTANT_X, `package test

main :: proc() {
	y := 1
	{*}x = y
}
`)
	// A second write.
	expect_no_create_decl(t, CONSTANT_X, `package test

main :: proc() {
	{*}x = 1
	x = 2
}
`)
	expect_no_create_decl(t, CONSTANT_X, `package test

main :: proc() {
	{*}x = 1
	x += 2
}
`)
	// `'a' + 1` has no type this server trusts, and a comment on the line would go away.
	expect_no_create_decl(t, CONSTANT_X, `package test

main :: proc() {
	{*}x = 'a' + 1
}
`)
	expect_no_create_decl(t, CONSTANT_X, `package test

main :: proc() {
	{*}x = 1 // keep
}
`)
}

@(test)
create_decl_disappears_with_its_flag :: proc(t: ^testing.T) {
	expect_no_create_name(t, `package test

main :: proc() {
	{*}x = 1
}
`, enabled = false)
	expect_no_create_decl(t, "Create struct Foo", `package test

main :: proc() {
	_ = Fo{*}o{a = 1}
}
`, enabled = false)
}

@(test)
create_decl_costs_no_whole_file_resolve_on_a_resolved_name :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\n\ntake :: proc(v: int) {}\n\nmain :: proc() {\n\tx := 1\n\ttake({*}x)\n}\n",
		config = {enable_code_action_create_decl = true},
	}
	test.expect_no_whole_file_resolve(t, &source)
}
