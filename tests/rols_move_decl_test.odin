#+feature dynamic-literals
package tests

import "core:testing"

import test "src:testing"

@(private = "file")
move_source :: proc(main: string, files: []test.File = {}) -> (src: test.Source) {
	src.main = main
	src.files = files
	src.config = {enable_code_action_move_decl = true, client_create_file_support = true}
	src.packages = make([]test.Package, 3, context.temp_allocator)
	src.packages[0] = {pkg = "fmt", source = "package fmt\nprintln :: proc(args: ..any) {}\n"}
	src.packages[1] = {pkg = "slice", source = "package slice\nreverse :: proc(s: []int) {}\n"}
	src.packages[2] = {pkg = "strings", source = "package strings\nto_upper :: proc(s: string) -> string {return s}\n"}
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

// Corpus: karl2d karl2d.odin:377 on the S17 rerun, see docs/corpus-validation.md.
@(test)
move_decl_refused_when_using_file_private_symbol :: proc(t: ^testing.T) {
	source := move_source(`package test

@(private = "file")
helper :: proc() {}

us{*}er :: proc() {
	helper()
}
`, {{"b.odin", "package test\n"}})
	test.expect_move_declaration(t, &source, "b.odin", {}, "helper")
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

@(test)
move_decl_target_keeps_its_import :: proc(t: ^testing.T) {
	source := move_source(`package test

import "core:fmt"

sh{*}ow :: proc() {
	fmt.println("x")
}

main :: proc() {
	show()
}
`, {{"b.odin", `package test

import "core:fmt"

other :: proc() {
	fmt.println("y")
}
`}})
	test.expect_move_declaration(
		t,
		&source,
		"b.odin",
		{
			{"main.odin", `package test

main :: proc() {
	show()
}
`},
			{"b.odin", `package test

import "core:fmt"

other :: proc() {
	fmt.println("y")
}

show :: proc() {
	fmt.println("x")
}
`},
		},
	)
}

@(test)
move_decl_last_of_the_file :: proc(t: ^testing.T) {
	source := move_source(`package test

first :: proc() {}

la{*}st :: proc() {}
`, {{"b.odin", "package test\n"}})
	test.expect_move_declaration(
		t,
		&source,
		"b.odin",
		{
			{"main.odin", `package test

first :: proc() {}
`},
			{"b.odin", `package test

last :: proc() {}
`},
		},
	)
}

@(test)
move_decl_round_trip :: proc(t: ^testing.T) {
	MAIN :: `package test

first :: proc() {}

greet :: proc() -> string {
	return "hi"
}
`
	B :: `package test

other :: proc() {}
`
	MOVED :: `package test

other :: proc() {}

greet :: proc() -> string {
	return "hi"
}
`
	there := move_source(`package test

first :: proc() {}

gr{*}eet :: proc() -> string {
	return "hi"
}
`, {{"b.odin", B}})
	test.expect_move_declaration(
		t,
		&there,
		"b.odin",
		{{"main.odin", `package test

first :: proc() {}
`}, {"b.odin", MOVED}},
	)

	back := move_source("")
	back.files = {
		{"b.odin", `package test

other :: proc() {}

gr{*}eet :: proc() -> string {
	return "hi"
}
`},
		{"main.odin", `package test

first :: proc() {}
`},
	}
	test.expect_move_declaration(t, &back, "main.odin", {{"b.odin", B}, {"main.odin", MAIN}})
}

// Corpus: karl2d karl2d.odin:7488, see docs/corpus-validation.md.
@(test)
move_decl_action_skips_file_with_other_build_tag :: proc(t: ^testing.T) {
	source := move_source(`package test

hel{*}per :: proc() {}

use :: proc() {
	helper()
}
`, {{"c.odin", "#+build linux\npackage test\n"}})
	test.expect_action_missing(t, &source, "Move to c.odin")
}

@(test)
move_decl_action_skips_file_with_other_platform_suffix :: proc(t: ^testing.T) {
	source := move_source(`package test

hel{*}per :: proc() {}

use :: proc() {
	helper()
}
`, {{"b_darwin.odin", "package test\n"}})
	test.expect_action_missing(t, &source, "Move to b_darwin.odin")
}

@(test)
move_decl_drops_import_only_the_moved_decl_used :: proc(t: ^testing.T) {
	source := move_source(`package test

import "core:strings"

u{*}p :: proc(s: string) -> string {
	return strings.to_upper(s)
}
`, {{"b.odin", "package test\n\nB :: 1\n"}})
	test.expect_move_declaration(
		t,
		&source,
		"b.odin",
		{{"main.odin", "package test\n"}, {"b.odin", `package test

import "core:strings"

B :: 1

up :: proc(s: string) -> string {
	return strings.to_upper(s)
}
`}},
	)
}

@(test)
move_decl_keeps_imports_the_rest_of_the_file_uses :: proc(t: ^testing.T) {
	source := move_source(`package test

import "core:fmt"
import sl "core:slice"
import "core:strings"

keep :: proc() {
	fmt.println("x")
}

mo{*}ved :: proc(s: []int) {
	sl.reverse(s)
	fmt.println(strings.to_upper("y"))
}

when ODIN_OS == .Linux {
	other :: proc() -> string {
		return strings.to_upper("z")
	}
}
`, {{"b.odin", "package test\n"}})
	test.expect_move_declaration(
		t,
		&source,
		"b.odin",
		{{"main.odin", `package test

import "core:fmt"
import "core:strings"

keep :: proc() {
	fmt.println("x")
}

when ODIN_OS == .Linux {
	other :: proc() -> string {
		return strings.to_upper("z")
	}
}
`}, {"b.odin", `package test

import "core:fmt"
import sl "core:slice"
import "core:strings"

moved :: proc(s: []int) {
	sl.reverse(s)
	fmt.println(strings.to_upper("y"))
}
`}},
	)
}

@(test)
move_decl_keeps_import_unused_before_the_move :: proc(t: ^testing.T) {
	source := move_source(`package test

import "core:fmt"
import "core:slice"

sh{*}ow :: proc() {
	fmt.println("x")
}

main :: proc() {}
`, {{"b.odin", "package test\n"}})
	test.expect_move_declaration(
		t,
		&source,
		"b.odin",
		{{"main.odin", `package test

import "core:slice"

main :: proc() {}
`}, {"b.odin", `package test

import "core:fmt"

show :: proc() {
	fmt.println("x")
}
`}},
	)
}

@(test)
move_decl_action_drops_import :: proc(t: ^testing.T) {
	source := move_source(`package test

import "core:fmt"

main :: proc() {}

sh{*}ow :: proc() {
	fmt.println("x")
}
`, {{"b.odin", "package test\n"}})
	test.expect_action_applied(t, &source, "Move to b.odin", `package test

main :: proc() {}
`)
}
