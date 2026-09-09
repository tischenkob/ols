#+feature dynamic-literals
package tests

import "core:testing"

import test "src:testing"

@(private = "file")
move_source :: proc(main: string, files: []test.File = {}) -> (src: test.Source) {
	src.main = main
	src.files = files
	src.config = {enable_code_action_move_decl = true, client_create_file_support = true}
	src.packages = make([]test.Package, 1, context.temp_allocator)
	src.packages[0] = {pkg = "fmt", source = "package fmt\nprintln :: proc(args: ..any) {}\n"}
	src.collections = {"core" = "test"}
	return src
}

@(test)
move_decl_to_existing_file_with_docs_and_attribute :: proc(t: ^testing.T) {
	source := move_source(`package test

first :: proc() {}

// Greets.
@(private)
gr{*}eet :: proc() -> string {
	return "hi"
} // trailing

last :: proc() {}
`, {{"b.odin", `package test

other :: proc() {}
`}})
	test.expect_move_declaration(
		t,
		&source,
		"b.odin",
		{
			{"main.odin", `package test

first :: proc() {}

last :: proc() {}
`},
			{"b.odin", `package test

other :: proc() {}

// Greets.
@(private)
greet :: proc() -> string {
	return "hi"
} // trailing
`},
		},
	)
}

@(test)
move_decl_to_new_file_with_import :: proc(t: ^testing.T) {
	source := move_source(`package test

import "core:fmt"

sh{*}ow :: proc() {
	fmt.println("x")
}

main :: proc() {
	show()
}
`)
	test.expect_move_declaration(
		t,
		&source,
		"show.odin",
		{
			{"main.odin", `package test

import "core:fmt"

main :: proc() {
	show()
}
`},
			{"show.odin", `package test

import "core:fmt"

show :: proc() {
	fmt.println("x")
}
`},
		},
	)
}

@(test)
move_decl_existing_target_without_trailing_newline_gets_import :: proc(t: ^testing.T) {
	source := move_source(`package test

import "core:fmt"

main :: proc() {}

sh{*}ow :: proc() {
	fmt.println("x")
}
`, {{"b.odin", `package test

other :: proc() {}`}})
	test.expect_move_declaration(
		t,
		&source,
		"b.odin",
		{
			{"main.odin", `package test

import "core:fmt"

main :: proc() {}
`},
			{"b.odin", `package test

import "core:fmt"

other :: proc() {}

show :: proc() {
	fmt.println("x")
}
`},
		},
	)
}

@(test)
move_decl_refused_for_file_private :: proc(t: ^testing.T) {
	source := move_source(`package test

@(private = "file")
hid{*}den :: proc() {}
`, {{"b.odin", "package test\n"}})
	test.expect_move_declaration(t, &source, "b.odin", {})
}

@(test)
move_decl_refused_under_when :: proc(t: ^testing.T) {
	source := move_source(`package test

when ODIN_OS == .Linux {
	on{*}ly :: proc() {}
}
`, {{"b.odin", "package test\n"}})
	test.expect_move_declaration(t, &source, "b.odin", {})
}

@(test)
move_decl_refused_when_using_file_private_symbol :: proc(t: ^testing.T) {
	source := move_source(`package test

@(private = "file")
helper :: proc() {}

us{*}er :: proc() {
	helper()
}
`, {{"b.odin", "package test\n"}})
	test.expect_move_declaration(t, &source, "b.odin", {})
}

@(test)
move_decl_actions_list_targets :: proc(t: ^testing.T) {
	source := move_source(`package test

Sha{*}pe :: struct {}
`, {{"b.odin", "package test\n"}, {"a.odin", "package test\n"}})
	test.expect_action(t, &source, {"Move to new file shape.odin", "Move to a.odin", "Move to b.odin"})
}

@(test)
move_decl_action_not_offered_without_create_support :: proc(t: ^testing.T) {
	source := move_source(`package test

Sha{*}pe :: struct {}
`)
	source.config.client_create_file_support = false
	test.expect_action_missing(t, &source, "Move to new file shape.odin")
}
