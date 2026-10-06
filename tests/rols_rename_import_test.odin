#+feature dynamic-literals

package tests

import "core:testing"

import "src:common"

import test "src:testing"

@(private = "file")
PLAYTEST :: "package playtest\n\nadvance :: proc(n: int) {}\nkey_press :: proc(k: int) {}\n"

@(private = "file")
OTHER_FILE :: `package test

import testing "shared:playtest"

other :: proc() {
	testing.advance(1)
}
`

@(test)
rename_import_prepare_alias :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import tes{*}ting "shared:playtest"

main :: proc() {
	testing.advance(1)
}
`,
		packages = {{pkg = "playtest", source = PLAYTEST}},
		collections = {"shared" = "test"},
	}
	range := common.Range {
		start = {line = 2, character = 7},
		end = {line = 2, character = 14},
	}
	test.expect_prepare_rename_range(t, &source, range)
}

@(test)
rename_import_prepare_qualifier :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import testing "shared:playtest"

main :: proc() {
	testing.advance(1)
	test{*}ing.key_press(2)
}
`,
		packages = {{pkg = "playtest", source = PLAYTEST}},
		collections = {"shared" = "test"},
	}
	range := common.Range {
		start = {line = 6, character = 1},
		end = {line = 6, character = 8},
	}
	test.expect_prepare_rename_range(t, &source, range)
}

// The alias and every qualifier of this file change; a local named like the import and the other file
// of the package, which imports the package under the same name, do not.
@(test)
rename_import_from_qualifier :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import testing "shared:playtest"

Thing :: struct {
	advance: int,
}

alias :: testing

main :: proc() {
	testing.advance(1)
	test{*}ing.key_press(2)
}

shadowed :: proc() {
	testing := Thing{}
	_ = testing.advance
}
`,
		files = {{"other.odin", OTHER_FILE}},
		packages = {{pkg = "playtest", source = PLAYTEST}},
		collections = {"shared" = "test"},
	}
	test.expect_rename(
		t,
		&source,
		"pt",
		{
			{
				"main.odin",
				`package test

import pt "shared:playtest"

Thing :: struct {
	advance: int,
}

alias :: pt

main :: proc() {
	pt.advance(1)
	pt.key_press(2)
}

shadowed :: proc() {
	testing := Thing{}
	_ = testing.advance
}
`,
			},
			{"other.odin", OTHER_FILE},
		},
	)
}

@(test)
rename_import_from_alias :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import tes{*}ting "shared:playtest"

main :: proc() {
	testing.advance(1)
}
`,
		packages = {{pkg = "playtest", source = PLAYTEST}},
		collections = {"shared" = "test"},
	}
	test.expect_rename(
		t,
		&source,
		"pt",
		{{"main.odin", `package test

import pt "shared:playtest"

main :: proc() {
	pt.advance(1)
}
`}},
	)
}

@(test)
rename_import_unaliased_gets_alias :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "shared:playtest"

main :: proc() {
	play{*}test.advance(1)
}
`,
		packages = {{pkg = "playtest", source = PLAYTEST}},
		collections = {"shared" = "test"},
	}
	test.expect_rename(
		t,
		&source,
		"pt",
		{{"main.odin", `package test

import pt "shared:playtest"

main :: proc() {
	pt.advance(1)
}
`}},
	)
}

@(test)
rename_import_refuses_existing_import :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import testing "shared:playtest"
import pt "shared:other"

main :: proc() {
	test{*}ing.advance(1)
	_ = pt.Z
}
`,
		packages = {{pkg = "playtest", source = PLAYTEST}, {pkg = "other", source = "package other\n\nZ :: 2\n"}},
		collections = {"shared" = "test"},
	}
	test.expect_rename_refused(t, &source, "pt", {"test/main.odin:4:1: the file already imports a package as `pt`"})
}

@(test)
rename_import_refuses_package_declaration :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import testing "shared:playtest"

main :: proc() {
	test{*}ing.advance(1)
}
`,
		files = {{"other.odin", "package test\n\npt :: 1\n"}},
		packages = {{pkg = "playtest", source = PLAYTEST}},
		collections = {"shared" = "test"},
	}
	test.expect_rename_refused(t, &source, "pt", {"`pt` is already declared in the package"})
}

@(test)
rename_import_refuses_local_capture :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import testing "shared:playtest"

main :: proc() {
	pt := 1
	test{*}ing.advance(pt)
}
`,
		packages = {{pkg = "playtest", source = PLAYTEST}},
		collections = {"shared" = "test"},
	}
	test.expect_rename_refused(t, &source, "pt", {"so it would capture the qualifier of `testing.advance`"})
}

@(test)
rename_import_refuses_builtin_name :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import testing "shared:playtest"

main :: proc() {
	test{*}ing.advance(1)
}
`,
		packages = {{pkg = "playtest", source = PLAYTEST}},
		collections = {"shared" = "test"},
	}
	test.expect_rename_refused(t, &source, "len", {"`len` is a builtin name, which the import would shadow"})
}

@(test)
rename_import_refuses_keyword :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import testing "shared:playtest"

main :: proc() {
	test{*}ing.advance(1)
}
`,
		packages = {{pkg = "playtest", source = PLAYTEST}},
		collections = {"shared" = "test"},
	}
	test.expect_rename_refused(t, &source, "proc", {"`proc` is a keyword"})
}

@(test)
rename_import_refuses_file_scope_declaration :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import testing "shared:playtest"

pt :: 1

main :: proc() {
	test{*}ing.advance(pt)
}
`,
		packages = {{pkg = "playtest", source = PLAYTEST}},
		collections = {"shared" = "test"},
	}
	test.expect_rename_refused(t, &source, "pt", {"test/main.odin:5:1: `pt` is already declared at file scope"})
}
