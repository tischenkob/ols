#+feature dynamic-literals
package tests

import "core:strings"
import "core:testing"

import test "src:testing"

expect_create_field :: proc(t: ^testing.T, main, expected: string, title := "Create field foo") {
	source := test.Source {
		main = main,
		config = {enable_code_action_create_member = true},
	}
	test.expect_action_applied(t, &source, title, expected)
}

expect_no_create_member :: proc(t: ^testing.T, main, title: string, enabled := true) {
	source := test.Source {
		main = main,
		config = {enable_code_action_create_member = enabled},
	}
	test.expect_action_missing(t, &source, title)
}

@(test)
create_field_from_assignment :: proc(t: ^testing.T) {
	expect_create_field(
		t,
		`package test

Foo :: struct {
	a: int,
}

main :: proc() {
	x: Foo
	x.fo{*}o = "s"
}
`,
		`package test

Foo :: struct {
	a: int,
	foo: string,
}

main :: proc() {
	x: Foo
	x.foo = "s"
}
`,
	)
}

@(test)
create_field_from_parameter :: proc(t: ^testing.T) {
	expect_create_field(
		t,
		`package test

Foo :: struct {
	a: int, // first
}

take :: proc(v: []f32) {}

main :: proc() {
	x: Foo
	take(x.fo{*}o)
}
`,
		`package test

Foo :: struct {
	a: int, // first
	foo: []f32,
}

take :: proc(v: []f32) {}

main :: proc() {
	x: Foo
	take(x.foo)
}
`,
	)
}

@(test)
create_field_through_pointer_on_one_line :: proc(t: ^testing.T) {
	expect_create_field(
		t,
		`package test

Foo :: struct {a: int}

main :: proc() {
	x: ^Foo
	x.fo{*}o = 2.5
}
`,
		`package test

Foo :: struct {a: int, foo: f64}

main :: proc() {
	x: ^Foo
	x.foo = 2.5
}
`,
	)
}

@(test)
create_field_in_empty_struct :: proc(t: ^testing.T) {
	expect_create_field(
		t,
		`package test

Foo :: struct {}

take :: proc(v: int) {}

main :: proc() {
	x: Foo
	take(x.fo{*}o)
}
`,
		`package test

Foo :: struct {foo: int}

take :: proc(v: int) {}

main :: proc() {
	x: Foo
	take(x.foo)
}
`,
	)
}

@(test)
create_field_without_a_trailing_comma :: proc(t: ^testing.T) {
	expect_create_field(
		t,
		`package test

Foo :: struct {
	a: int ` + "`tag`" + `
}

main :: proc() {
	x: Foo
	x.fo{*}o = true
}
`,
		`package test

Foo :: struct {
	a: int ` + "`tag`" + `,
	foo: bool,
}

main :: proc() {
	x: Foo
	x.foo = true
}
`,
	)
}

@(test)
create_field_in_another_file :: proc(t: ^testing.T) {
	other := `package test

Foo :: struct {
	a: int,
}
`
	source := test.Source {
		main = `package test

Bar :: struct {}

main :: proc() {
	x: Foo
	x.fo{*}o = Bar{}
}
`,
		files = {{name = "other.odin", source = other}},
		config = {enable_code_action_create_member = true},
	}
	expected := `package test

Foo :: struct {
	a: int,
	foo: Bar,
}
`
	test.expect_action_applied_files(t, &source, "Create field foo", {{name = "other.odin", source = expected}})
}

@(test)
create_field_refuses_a_file_private_type_for_another_file :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

@(private = "file")
Bar :: struct {}

main :: proc() {
	x: Foo
	x.fo{*}o = Bar{}
}
`,
		files = {{name = "other.odin", source = "package test\n\nFoo :: struct {\n\ta: int,\n}\n"}},
		config = {enable_code_action_create_member = true},
	}
	test.expect_action_missing(t, &source, "Create field foo")
}

@(test)
create_field_refuses_an_unimported_package_of_another_file :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "core:lib"

main :: proc() {
	x: Foo
	x.fo{*}o = lib.Bar{}
}
`,
		files = {{name = "other.odin", source = "package test\n\nFoo :: struct {\n\ta: int,\n}\n"}},
		packages = {{pkg = "lib", source = "package lib\n\nBar :: struct {}\n"}},
		collections = {"core" = "test"},
		config = {enable_code_action_create_member = true},
	}
	test.expect_action_missing(t, &source, "Create field foo")
}

@(test)
create_field_refuses_a_struct_outside_the_workspace :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "core:lib"

main :: proc() {
	x: lib.Foo
	x.fo{*}o = 1
}
`,
		packages = {{pkg = "lib", source = "package lib\n\nFoo :: struct {\n\ta: int,\n}\n"}},
		collections = {"core" = "test"},
		config = {enable_code_action_create_member = true},
	}
	test.expect_action_missing(t, &source, "Create field foo")
}

@(test)
create_field_refuses_an_unknown_type :: proc(t: ^testing.T) {
	expect_no_create_member(t, `package test

Foo :: struct {
	a: int,
}

main :: proc() {
	x: Foo
	y := x.fo{*}o
	_ = y
}
`, "Create field foo")
	expect_no_create_member(t, `package test

Foo :: struct {
	a: int,
}

main :: proc() {
	x: Foo
	x.fo{*}o = unknown
}
`, "Create field foo")
}

@(test)
create_field_reading_a_local_of_the_same_name :: proc(t: ^testing.T) {
	expect_create_field(
		t,
		`package test

Foo :: struct {
	a: int,
}

main :: proc() {
	x: Foo
	foo := "s"
	x.fo{*}o = foo
}
`,
		`package test

Foo :: struct {
	a: int,
	foo: string,
}

main :: proc() {
	x: Foo
	foo := "s"
	x.foo = foo
}
`,
	)
}

@(test)
create_field_refuses_a_pointer_to_a_pointer :: proc(t: ^testing.T) {
	expect_no_create_member(t, `package test

Foo :: struct {
	a: int,
}

main :: proc() {
	x: ^^Foo
	x.fo{*}o = 1
}
`, "Create field foo")
}

@(test)
create_field_refuses_a_parametric_struct :: proc(t: ^testing.T) {
	expect_no_create_member(t, `package test

Foo :: struct($T: typeid) {
	a: T,
}

main :: proc() {
	x: Foo(int)
	x.fo{*}o = 1
}
`, "Create field foo")
}

@(test)
create_field_refuses_a_positional_literal :: proc(t: ^testing.T) {
	expect_no_create_member(t, `package test

Foo :: struct {
	a: int,
}

main :: proc() {
	x := Foo{1}
	x.fo{*}o = 1
}
`, "Create field foo")
}

@(test)
create_field_refuses_a_name_that_shadows_the_type :: proc(t: ^testing.T) {
	expect_no_create_member(t, `package test

Bar :: struct {}

Foo :: struct {
	a: int,
}

main :: proc() {
	x: Foo
	x.Ba{*}r = Bar{}
}
`, "Create field Bar")
	expect_no_create_member(t, `package test

Bar :: struct {}

Foo :: struct {
	Bar: int,
}

main :: proc() {
	x: Foo
	y: Bar
	x.fo{*}o = y
}
`, "Create field foo")
}

@(test)
create_field_refuses_a_local_type_for_a_global_struct :: proc(t: ^testing.T) {
	expect_no_create_member(t, `package test

Foo :: struct {
	a: int,
}

main :: proc() {
	Bar :: struct {}
	x: Foo
	x.fo{*}o = Bar{}
}
`, "Create field foo")
}

@(test)
create_field_refuses_a_distinct_struct_and_a_type_name :: proc(t: ^testing.T) {
	expect_no_create_member(t, `package test

Foo :: struct {
	a: int,
}

Bar :: distinct Foo

main :: proc() {
	x: Bar
	x.fo{*}o = 1
}
`, "Create field foo")
	expect_no_create_member(t, `package test

Foo :: struct {
	a: int,
}

main :: proc() {
	Foo.fo{*}o = 1
}
`, "Create field foo")
}

@(test)
create_field_refuses_a_resolved_field_and_a_package_root :: proc(t: ^testing.T) {
	expect_no_create_member(t, `package test

Foo :: struct {
	a: int,
}

main :: proc() {
	x: Foo
	x.{*}a = 1
}
`, "Create field a")
	expect_no_create_member(t, `package test

main :: proc() {
	strings.fo{*}o = 1
}
`, "Create field foo")
}

@(test)
create_enum_member_after_the_last_one :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Kind :: enum {
	A,
	B = 4, // four
}

main :: proc() {
	k: Kind
	k = .Fo{*}o
}
`,
		config = {enable_code_action_create_member = true},
	}
	test.expect_action_applied(t, &source, "Create enum member Foo", `package test

Kind :: enum {
	A,
	B = 4, // four
	Foo,
}

main :: proc() {
	k: Kind
	k = .Foo
}
`)
}

ENUM_PLACE_HEAD :: `package test

Kind :: enum {A, B}

take :: proc(k: Kind) {}

Item :: struct {
	kind: Kind,
}

Set :: bit_set[Kind]

main :: proc() {
	k: Kind
	`

expect_create_enum_at :: proc(t: ^testing.T, place, applied: string) {
	source := test.Source {
		main = strings.concatenate({ENUM_PLACE_HEAD, place, "\n}\n"}, context.temp_allocator),
		config = {enable_code_action_create_member = true},
	}
	expected, _ := strings.replace(ENUM_PLACE_HEAD, "{A, B}", "{A, B, Foo}", 1, context.temp_allocator)
	expected = strings.concatenate({expected, applied, "\n}\n"}, context.temp_allocator)
	test.expect_action_applied(t, &source, "Create enum member Foo", expected)
}

@(test)
create_enum_member_at_each_place :: proc(t: ^testing.T) {
	expect_create_enum_at(t, "take(.Fo{*}o)", "take(.Foo)")
	expect_create_enum_at(t, "_ = k == .Fo{*}o", "_ = k == .Foo")
	expect_create_enum_at(t, "j: Kind = .Fo{*}o", "j: Kind = .Foo")
	expect_create_enum_at(t, "_ = Item{kind = .Fo{*}o}", "_ = Item{kind = .Foo}")
	expect_create_enum_at(t, "s: Set = {.Fo{*}o}", "s: Set = {.Foo}")
}

@(test)
create_enum_member_in_a_switch_that_lists_it :: proc(t: ^testing.T) {
	expect_create_enum_at(
		t,
		"switch k {\n\tcase .A, .B:\n\tcase .Fo{*}o:\n\t}",
		"switch k {\n\tcase .A, .B:\n\tcase .Foo:\n\t}",
	)
}

@(test)
create_enum_member_in_another_file :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	k: Kind
	k = .Fo{*}o
}
`,
		files = {{name = "other.odin", source = "package test\n\nKind :: enum {\n\tA\n}\n"}},
		config = {enable_code_action_create_member = true},
	}
	test.expect_action_applied_files(
		t,
		&source,
		"Create enum member Foo",
		{{name = "other.odin", source = "package test\n\nKind :: enum {\n\tA,\n\tFoo,\n}\n"}},
	)
}

@(test)
create_enum_member_refuses :: proc(t: ^testing.T) {
	// The member exists.
	expect_no_create_member(t, `package test

Kind :: enum {A}

main :: proc() {
	k: Kind
	k = .{*}A
}
`, "Create enum member A")
	// No place gives the enum.
	expect_no_create_member(t, `package test

Kind :: enum {A}

main :: proc() {
	k := .Fo{*}o
	_ = k
}
`, "Create enum member Foo")
	// The enum has no declaration of its own.
	expect_no_create_member(t, `package test

main :: proc() {
	k: enum {A}
	k = .Fo{*}o
}
`, "Create enum member Foo")
	expect_no_create_member(t, `package test

Kind :: enum {A}

Other :: distinct Kind

main :: proc() {
	k: Other
	k = .Fo{*}o
}
`, "Create enum member Foo")
	// A complete switch would miss the new member.
	expect_no_create_member(t, `package test

Kind :: enum {A}

main :: proc() {
	k: Kind
	switch k {
	case .A:
	}
	k = .Fo{*}o
}
`, "Create enum member Foo")
	// So would an enumerated array literal.
	expect_no_create_member(t, `package test

Kind :: enum {A}

main :: proc() {
	k: Kind
	names := [Kind]string{.A = "a"}
	_ = names
	k = .Fo{*}o
}
`, "Create enum member Foo")
}

@(test)
create_enum_member_keeps_partial_places :: proc(t: ^testing.T) {
	expect_create_enum_at(
		t,
		"#partial switch k {\n\tcase .A:\n\t}\n\tnames := #partial [Kind]string{.A = \"a\"}\n\t_ = names\n\tk = .Fo{*}o",
		"#partial switch k {\n\tcase .A:\n\t}\n\tnames := #partial [Kind]string{.A = \"a\"}\n\t_ = names\n\tk = .Foo",
	)
}

@(test)
create_enum_member_refuses_an_enum_outside_the_workspace :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "core:lib"

main :: proc() {
	k: lib.Kind
	k = .Fo{*}o
}
`,
		packages = {{pkg = "lib", source = "package lib\n\nKind :: enum {A}\n"}},
		collections = {"core" = "test"},
		config = {enable_code_action_create_member = true},
	}
	test.expect_action_missing(t, &source, "Create enum member Foo")
}

@(test)
create_member_disappears_with_its_flag :: proc(t: ^testing.T) {
	expect_no_create_member(t, `package test

Foo :: struct {
	a: int,
}

main :: proc() {
	x: Foo
	x.fo{*}o = 1
}
`, "Create field foo", enabled = false)
	expect_no_create_member(t, `package test

Kind :: enum {A}

main :: proc() {
	k: Kind
	k = .Fo{*}o
}
`, "Create enum member Foo", enabled = false)
}

@(test)
create_member_costs_no_whole_file_resolve_on_a_resolved_name :: proc(t: ^testing.T) {
	field := test.Source {
		main = "package test\n\nFoo :: struct {\n\ta: int,\n}\n\nmain :: proc() {\n\tx: Foo\n\tx.{*}a = 1\n}\n",
		config = {enable_code_action_create_member = true},
	}
	test.expect_no_whole_file_resolve(t, &field)
	member := test.Source {
		main = "package test\n\nKind :: enum {A}\n\nmain :: proc() {\n\tk: Kind\n\tk = .{*}A\n}\n",
		config = {enable_code_action_create_member = true},
	}
	test.expect_no_whole_file_resolve(t, &member)
}
