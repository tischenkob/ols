#+feature dynamic-literals

package tests

import "core:testing"

import test "src:testing"

// File scope, so the slice old_package returns does not point into its stack frame.
@(private = "file")
old_files := [?]test.File {
	{"a.odin", "package old\n\nX :: 1\n\nS :: struct {\n\told: int,\n}\n"},
	{"a_test.odin", "package old_test\n\nT :: 2\n"},
}

@(private = "file")
old_package :: proc() -> []test.Package {
	packages := make([dynamic]test.Package, context.temp_allocator)
	append(&packages, test.Package{pkg = "old", files = old_files[:]})
	return packages[:]
}

// The clauses change, `_test` included, and so do the importer's path and qualifiers, but not a field named old.
@(test)
rename_package_clauses_and_importer :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "shared:old"

main :: proc() {
	s := old.S{}
	_ = old.X + s.old
}
`,
		packages = old_package(),
		collections = {"shared" = "test"},
	}
	test.expect_rename_package(
		t,
		&source,
		"old",
		"fresh",
		{
			{
				"main.odin",
				`package test

import "shared:fresh"

main :: proc() {
	s := fresh.S{}
	_ = fresh.X + s.old
}
`,
			},
			{"fresh/a.odin", "package fresh\n\nX :: 1\n\nS :: struct {\n\told: int,\n}\n"},
			{"fresh/a_test.odin", "package fresh_test\n\nT :: 2\n"},
		},
	)
}

// An aliased import keeps its qualifiers, even when its alias is the old name; a relative path keeps its style.
@(test)
rename_package_aliased_importers :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import o "shared:old"

main :: proc() {
	_ = o.X
}
`,
		files = {{"other.odin", `package test

import old "./old"

other :: proc() -> int {
	return old.X
}
`}},
		packages = old_package(),
		collections = {"shared" = "test"},
	}
	test.expect_rename_package(
		t,
		&source,
		"old",
		"fresh",
		{
			{"main.odin", `package test

import o "shared:fresh"

main :: proc() {
	_ = o.X
}
`},
			{"other.odin", `package test

import old "./fresh"

other :: proc() -> int {
	return old.X
}
`},
		},
	)
}

// A nested package keeps its name, but every path into it changes, including its own import of the parent.
// A relative import from the package that leaves it with `..` stays as it is.
@(test)
rename_package_nested_sub_package :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "shared:old/sub"

main :: proc() {
	_ = sub.Y
}
`,
		packages = {
			{pkg = "old", source = "package old\n\nimport \"../other\"\n\nX :: other.Z\n"},
			{pkg = "old/sub", source = "package sub\n\nimport \"shared:old\"\n\nY :: old.X\n"},
			{pkg = "other", source = "package other\n\nZ :: 1\n"},
		},
		collections = {"shared" = "test"},
	}
	test.expect_rename_package(
		t,
		&source,
		"old",
		"fresh",
		{
			{"main.odin", `package test

import "shared:fresh/sub"

main :: proc() {
	_ = sub.Y
}
`},
			{"fresh/package.odin", "package fresh\n\nimport \"../other\"\n\nX :: other.Z\n"},
			{"fresh/sub/package.odin", "package sub\n\nimport \"shared:fresh\"\n\nY :: fresh.X\n"},
		},
	)
}

// The resolve decides, not the text: a local named old keeps its uses, and a qualifier in a file-scope
// `when` changes.
@(test)
rename_package_resolves_qualifiers :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "shared:old"

S :: struct {
	a: int,
}

when ODIN_OS == .Linux {
	W :: old.X
}

main :: proc() {
	old := S{}
	_ = old.a
}
`,
		packages = {{pkg = "old", source = "package old\n\nX :: 1\n"}},
		collections = {"shared" = "test"},
	}
	test.expect_rename_package(
		t,
		&source,
		"old",
		"fresh",
		{
			{
				"main.odin",
				`package test

import "shared:fresh"

S :: struct {
	a: int,
}

when ODIN_OS == .Linux {
	W :: fresh.X
}

main :: proc() {
	old := S{}
	_ = old.a
}
`,
			},
		},
	)
}

// A foreign import path that names the package, here in a `when` block, stays as it is with a warning.
@(test)
rename_package_warns_on_foreign_import :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "shared:old"

when ODIN_OS == .Windows {
	foreign import lib "old/lib.lib"
}

main :: proc() {
	_ = old.X
}
`,
		packages = {{pkg = "old", source = "package old\n\nX :: 1\n"}},
		collections = {"shared" = "test"},
	}
	test.expect_rename_package(
		t,
		&source,
		"old",
		"fresh",
		{
			{
				"main.odin",
				`package test

import "shared:fresh"

when ODIN_OS == .Windows {
	foreign import lib "old/lib.lib"
}

main :: proc() {
	_ = fresh.X
}
`,
			},
		},
		{"test/main.odin:6:21: the foreign import path mentions `old`, which rename-package does not change"},
	)
}

@(test)
rename_package_refuses_keyword_and_invalid_name :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\n\nimport \"shared:old\"\n\nmain :: proc() {\n\t_ = old.X\n}\n",
		packages = old_package(),
		collections = {"shared" = "test"},
	}
	test.expect_rename_package_refused(t, &source, "old", "proc", {"`proc` is a keyword"})
	source2 := test.Source {
		main = "package test\n\nimport \"shared:old\"\n\nmain :: proc() {\n\t_ = old.X\n}\n",
		packages = old_package(),
		collections = {"shared" = "test"},
	}
	test.expect_rename_package_refused(t, &source2, "old", "9lives", {"`9lives` is not a valid Odin identifier"})
}

@(test)
rename_package_refuses_bound_name_in_importer :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "shared:old"
import fresh "shared:other"

fresh_value :: 3

main :: proc() {
	_ = old.X + fresh.Z
}
`,
		packages = {
			{pkg = "old", source = "package old\n\nX :: 1\n"},
			{pkg = "other", source = "package other\n\nZ :: 2\n"},
		},
		collections = {"shared" = "test"},
	}
	test.expect_rename_package_refused(
		t,
		&source,
		"old",
		"fresh",
		{"test/main.odin:4:1: the file already imports a package as `fresh`"},
	)
}

@(test)
rename_package_refuses_file_scope_declaration :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "shared:old"

fresh :: 3

main :: proc() {
	_ = old.X + fresh
}
`,
		packages = {{pkg = "old", source = "package old\n\nX :: 1\n"}},
		collections = {"shared" = "test"},
	}
	test.expect_rename_package_refused(
		t,
		&source,
		"old",
		"fresh",
		{"test/main.odin:5:1: `fresh` is already declared at file scope of an importer"},
	)
}

@(test)
rename_package_refuses_local_capture :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "shared:old"

main :: proc() {
	fresh := 1
	_ = old.X + fresh
}
`,
		packages = {{pkg = "old", source = "package old\n\nX :: 1\n"}},
		collections = {"shared" = "test"},
	}
	test.expect_rename_package_refused(
		t,
		&source,
		"old",
		"fresh",
		{
			"test/main.odin:7:6: `fresh` is a local here, declared at test/main.odin:6, so it would capture the qualifier of `old.X`",
		},
	)
}

@(test)
rename_package_refuses_clause_mismatch :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "shared:old"

main :: proc() {
	_ = old.X
}
`,
		packages = {
			{pkg = "old", files = {{"a.odin", "package old\n\nX :: 1\n"}, {"b.odin", "package other\n\nY :: 2\n"}}},
		},
		collections = {"shared" = "test"},
	}
	test.expect_rename_package_refused(
		t,
		&source,
		"old",
		"fresh",
		{"test/old/b.odin:1:9 declares `package other`, but Odin imports the package by its directory name `old`"},
	)
}
