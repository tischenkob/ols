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
move_decl_refused_to_new_file_without_platform_suffix :: proc(t: ^testing.T) {
	source := move_source("", {{"main_windows.odin", "package test\n\nhel{*}per :: proc() {}\n"}})
	test.expect_move_declaration(t, &source, "helper.odin", {}, "helper.odin has different build constraints")
}

@(test)
move_decl_action_new_file_keeps_platform_suffix :: proc(t: ^testing.T) {
	source := move_source("", {{"main_windows.odin", "package test\n\nhel{*}per :: proc() {}\n"}})
	test.expect_action_applied_files(
		t,
		&source,
		"Move to new file helper_windows.odin",
		{{"main_windows.odin", "package test\n"}, {"helper_windows.odin", "package test\n\nhelper :: proc() {}\n"}},
	)
}

@(test)
move_decl_action_new_file_keeps_os_and_arch_suffix :: proc(t: ^testing.T) {
	source := move_source("", {{"linux_amd64.odin", "package test\n\nhel{*}per :: proc() {}\n"}})
	test.expect_action_applied_files(
		t,
		&source,
		"Move to new file helper_linux_amd64.odin",
		{{"helper_linux_amd64.odin", "package test\n\nhelper :: proc() {}\n"}},
	)
}

// Corpus: docs/corpus-validation.md, 2026-10-05 rerun.
@(test)
move_decl_refused_into_file_private_file :: proc(t: ^testing.T) {
	main := `package test

hel{*}per :: proc() {}
`
	files := []test.File{{"b.odin", "#+private file\npackage test\n"}}
	source := move_source(main, files)
	test.expect_move_declaration(t, &source, "b.odin", {}, "b.odin is #+private file")
	action := move_source(main, files)
	test.expect_action_missing(t, &action, "Move to b.odin")
}

// Corpus: karl2d audio_backend_nil.odin:28 on the 2026-10-05 rerun, see docs/corpus-validation.md.
@(test)
move_decl_refused_from_package_private_into_public :: proc(t: ^testing.T) {
	main := `#+private
package test

hel{*}per :: proc() {}
`
	files := []test.File{{"b.odin", "package test\n"}}
	source := move_source(main, files)
	test.expect_move_declaration(t, &source, "b.odin", {}, "b.odin is public")
	action := move_source(main, files)
	test.expect_action_missing(t, &action, "Move to b.odin")
}

@(test)
move_decl_refused_from_public_into_package_private :: proc(t: ^testing.T) {
	main := `package test

hel{*}per :: proc() {}
`
	files := []test.File{{"b.odin", "#+private\npackage test\n"}}
	source := move_source(main, files)
	test.expect_move_declaration(t, &source, "b.odin", {}, "b.odin is #+private")
	action := move_source(main, files)
	test.expect_action_missing(t, &action, "Move to b.odin")
}

@(test)
move_decl_between_package_private_files :: proc(t: ^testing.T) {
	source := move_source(`#+private
package test

hel{*}per :: proc() {}
`, {{"b.odin", "#+private\npackage test\n"}})
	test.expect_move_declaration(
		t,
		&source,
		"b.odin",
		{{"main.odin", "#+private\npackage test\n"}, {"b.odin", "#+private\npackage test\n\nhelper :: proc() {}\n"}},
	)
}

// Corpus: karl2d audio_backend_core_audio.odin:94 on the 2026-10-05 rerun, see docs/corpus-validation.md.
@(test)
move_decl_to_new_file_keeps_file_tags :: proc(t: ^testing.T) {
	source := move_source(`#+build darwin
#+private
package test

hel{*}per :: proc() {}

use :: proc() {
	helper()
}
`)
	test.expect_move_declaration(
		t,
		&source,
		"helper.odin",
		{
			{"main.odin", "#+build darwin\n#+private\npackage test\n\nuse :: proc() {\n\thelper()\n}\n"},
			{"helper.odin", "#+build darwin\n#+private\npackage test\n\nhelper :: proc() {}\n"},
		},
	)
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

// A parameter that shadows the import makes the moved declaration spell the import without using it, so the
// target gets no import and the source keeps the one it already left unused.
@(test)
move_decl_keeps_import_unused_before_the_move :: proc(t: ^testing.T) {
	source := move_source(`package test

import "core:strings"

T :: struct {
	f: int,
}

sh{*}ow :: proc(strings: T) {
	_ = strings.f
}

main :: proc() {}
`, {{"b.odin", "package test\n"}})
	test.expect_move_declaration(
		t,
		&source,
		"b.odin",
		{{"main.odin", `package test

import "core:strings"

T :: struct {
	f: int,
}

main :: proc() {}
`}, {"b.odin", `package test

show :: proc(strings: T) {
	_ = strings.f
}
`}},
	)
}

// The doc comment of a dropped import goes with it.
@(test)
move_decl_drops_import_with_its_doc_comment :: proc(t: ^testing.T) {
	source := move_source(`package test

import "core:fmt"
// Upper-casing.
import "core:strings"

keep :: proc() {
	fmt.println("x")
}

u{*}p :: proc(s: string) -> string {
	return strings.to_upper(s)
}
`, {{"b.odin", "package test\n"}})
	test.expect_move_declaration(
		t,
		&source,
		"b.odin",
		{{"main.odin", `package test

import "core:fmt"

keep :: proc() {
	fmt.println("x")
}
`}, {"b.odin", `package test

import "core:strings"

up :: proc(s: string) -> string {
	return strings.to_upper(s)
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

// Two spellings of one build constraint allow the move: the `#+build` groups in another order, and a `#+build` line
// against the OS suffix of a file name.
@(test)
move_decl_between_files_with_equivalent_build_constraints :: proc(t: ^testing.T) {
	reordered := move_source(
		"#+build linux, darwin\npackage test\n\nhel{*}per :: proc() {}\n",
		{{"b.odin", "#+build darwin, linux\npackage test\n"}},
	)
	test.expect_move_declaration(
		t,
		&reordered,
		"b.odin",
		{
			{"main.odin", "#+build linux, darwin\npackage test\n"},
			{"b.odin", "#+build darwin, linux\npackage test\n\nhelper :: proc() {}\n"},
		},
	)
	suffix := move_source(
		"#+build linux\npackage test\n\nhel{*}per :: proc() {}\n",
		{{"b_linux.odin", "package test\n"}},
	)
	test.expect_move_declaration(
		t,
		&suffix,
		"b_linux.odin",
		{{"main.odin", "#+build linux\npackage test\n"}, {"b_linux.odin", "package test\n\nhelper :: proc() {}\n"}},
	)
	new_file := move_source("#+build linux\npackage test\n\nhel{*}per :: proc() {}\n")
	test.expect_move_declaration(
		t,
		&new_file,
		"helper_linux.odin",
		{
			{"main.odin", "#+build linux\npackage test\n"},
			{"helper_linux.odin", "#+build linux\npackage test\n\nhelper :: proc() {}\n"},
		},
	)
	narrower := move_source(
		"#+build linux, darwin\npackage test\n\nhel{*}per :: proc() {}\n",
		{{"b.odin", "#+build linux\npackage test\n"}},
	)
	test.expect_move_declaration(t, &narrower, "b.odin", {}, "b.odin has different build constraints")
}

// A local spelled like an import is no use of it, so the import goes with its only user.
@(test)
move_decl_drops_import_that_a_same_named_local_does_not_use :: proc(t: ^testing.T) {
	source := move_source(`package test

import "core:strings"

sh{*}ow :: proc() -> string {
	return strings.to_upper("a")
}

main :: proc() {
	strings := 1
	_ = strings
}
`, {{"b.odin", "package test\n"}})
	test.expect_move_declaration(
		t,
		&source,
		"b.odin",
		{{"main.odin", `package test

main :: proc() {
	strings := 1
	_ = strings
}
`}, {"b.odin", `package test

import "core:strings"

show :: proc() -> string {
	return strings.to_upper("a")
}
`}},
	)
}
