package tests

import "core:testing"

import test "src:testing"

DESTROY_FOO :: "Generate destroy_foo"
INIT_FOO :: "Generate init_foo"

expect_generate_lifetime :: proc(t: ^testing.T, title, main, expected: string) {
	source := test.Source {
		main = main,
		config = {enable_code_action_generate_lifetime = true},
	}
	test.expect_action_applied(t, &source, title, expected)
}

expect_no_generate_lifetime :: proc(t: ^testing.T, title, main: string, enabled := true) {
	source := test.Source {
		main = main,
		config = {enable_code_action_generate_lifetime = enabled},
	}
	test.expect_action_missing(t, &source, title)
}

LIFETIME_FOO :: `package test

Item :: struct {
	a: int,
}

F{*}oo :: struct {
	items:  [dynamic]Item,
	lookup: map[string]int,
	tags:   []string,
	name:   string,
	next:   ^Foo,
	shared: ^[dynamic]int,
	count:  int,
}
`

@(test)
generate_destroy_deletes_dynamic_and_map_fields_only :: proc(t: ^testing.T) {
	expect_generate_lifetime(t, DESTROY_FOO, LIFETIME_FOO, `package test

Item :: struct {
	a: int,
}

Foo :: struct {
	items:  [dynamic]Item,
	lookup: map[string]int,
	tags:   []string,
	name:   string,
	next:   ^Foo,
	shared: ^[dynamic]int,
	count:  int,
}

destroy_foo :: proc(foo: ^Foo) {
	delete(foo.items)
	delete(foo.lookup)
	// Not freed, since these can be borrowed: tags, name, next, shared.
}
`)
}

@(test)
generate_init_makes_dynamic_and_map_fields :: proc(t: ^testing.T) {
	expect_generate_lifetime(t, INIT_FOO, LIFETIME_FOO, `package test

Item :: struct {
	a: int,
}

Foo :: struct {
	items:  [dynamic]Item,
	lookup: map[string]int,
	tags:   []string,
	name:   string,
	next:   ^Foo,
	shared: ^[dynamic]int,
	count:  int,
}

init_foo :: proc(foo: ^Foo, allocator := context.allocator) {
	foo.items = make([dynamic]Item, allocator)
	foo.lookup = make(map[string]int, allocator)
}
`)
}

// A slice or a string alone gets a destroy procedure that only names them, and no init procedure.
@(test)
generate_destroy_names_borrowed_fields :: proc(t: ^testing.T) {
	main := `package test

F{*}oo :: struct {
	data: []u8,
	path: string,
}
`
	expect_generate_lifetime(t, DESTROY_FOO, main, `package test

Foo :: struct {
	data: []u8,
	path: string,
}

destroy_foo :: proc(foo: ^Foo) {
	// Not freed, since these can be borrowed: data, path.
}
`)
	expect_no_generate_lifetime(t, INIT_FOO, main)
}

@(test)
generate_lifetime_refuses_an_empty_struct :: proc(t: ^testing.T) {
	main := "package test\n\nF{*}oo :: struct {}\n"
	expect_no_generate_lifetime(t, DESTROY_FOO, main)
	expect_no_generate_lifetime(t, INIT_FOO, main)
	plain := "package test\n\nF{*}oo :: struct {\n\tcount: int,\n}\n"
	expect_no_generate_lifetime(t, DESTROY_FOO, plain)
	expect_no_generate_lifetime(t, INIT_FOO, plain)
}

@(test)
generate_lifetime_refuses_a_parametric_struct :: proc(t: ^testing.T) {
	main := "package test\n\nF{*}oo :: struct($T: typeid) {\n\titems: [dynamic]T,\n}\n"
	expect_no_generate_lifetime(t, DESTROY_FOO, main)
	expect_no_generate_lifetime(t, INIT_FOO, main)
}

// The fields of a raw union share memory, so freeing each would free it twice.
@(test)
generate_lifetime_refuses_a_raw_union :: proc(t: ^testing.T) {
	main := "package test\n\nF{*}oo :: struct #raw_union {\n\titems: [dynamic]int,\n\tm: map[int]int,\n}\n"
	expect_no_generate_lifetime(t, DESTROY_FOO, main)
	expect_no_generate_lifetime(t, INIT_FOO, main)
}

@(test)
generate_lifetime_refuses_a_taken_name :: proc(t: ^testing.T) {
	main := `package test

F{*}oo :: struct {
	items: [dynamic]int,
}

destroy_foo :: proc(foo: ^Foo) {}
`
	expect_no_generate_lifetime(t, DESTROY_FOO, main)
	source := test.Source {
		main = "package test\n\nF{*}oo :: struct {\n\titems: [dynamic]int,\n}\n",
		files = {{name = "other.odin", source = "package test\n\ninit_foo :: proc() {}\n"}},
		config = {enable_code_action_generate_lifetime = true},
	}
	test.expect_action_missing(t, &source, INIT_FOO)
}

@(test)
generate_lifetime_refuses_a_shadowed_builtin :: proc(t: ^testing.T) {
	main := `package test

F{*}oo :: struct {
	items: [dynamic]int,
}

delete :: proc(x: int) {}
`
	expect_no_generate_lifetime(t, DESTROY_FOO, main)
	expect_no_generate_lifetime(t, INIT_FOO, main)
}

@(test)
generate_lifetime_disabled :: proc(t: ^testing.T) {
	expect_no_generate_lifetime(t, DESTROY_FOO, LIFETIME_FOO, enabled = false)
	expect_no_generate_lifetime(t, INIT_FOO, LIFETIME_FOO, enabled = false)
}

// `context` is a keyword, so the parameter gets another name.
@(test)
generate_destroy_renames_a_keyword_parameter :: proc(t: ^testing.T) {
	expect_generate_lifetime(t, "Generate destroy_context", `package test

C{*}ontext :: struct {
	items: [dynamic]int,
}
`, `package test

Context :: struct {
	items: [dynamic]int,
}

destroy_context :: proc(value: ^Context) {
	delete(value.items)
}
`)
}

// A parameter would shadow the type name `allocator`, so the call names the type through the field.
@(test)
generate_init_spells_a_shadowed_type_through_the_field :: proc(t: ^testing.T) {
	expect_generate_lifetime(t, INIT_FOO, `package test

allocator :: struct {}

F{*}oo :: struct {
	pools: [dynamic]allocator,
}
`, `package test

allocator :: struct {}

Foo :: struct {
	pools: [dynamic]allocator,
}

init_foo :: proc(foo: ^Foo, allocator := context.allocator) {
	foo.pools = make(type_of(foo.pools), allocator)
}
`)
}
