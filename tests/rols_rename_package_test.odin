#+feature dynamic-literals

package tests

import "core:testing"

import "src:common"
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

// An import path with `\` separators, escaped or mixed with `/`, is rewritten and keeps each separator.
@(test)
rename_package_keeps_backslash_separators :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import s "shared:old\\sub"
import o ".\\old/sub"

main :: proc() {
	_ = s.Y + o.Y
}
`,
		packages = {
			{pkg = "old", source = "package old\n\nX :: 1\n"},
			{pkg = "old/sub", source = "package sub\n\nY :: 2\n"},
		},
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

import s "shared:fresh\\sub"
import o ".\\fresh/sub"

main :: proc() {
	_ = s.Y + o.Y
}
`,
			},
		},
	)
}

// A package file that imports its own package, which Odin rejects, gets its path rewritten, but OLS skips a
// self-import when it resolves `old`, so the qualifier stays as it is with a warning.
@(test)
rename_package_warns_on_unresolved_qualifier :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\n\nimport \"shared:old\"\n\nmain :: proc() {\n\t_ = old.X\n}\n",
		packages = {
			{
				pkg = "old",
				files = {
					{"a.odin", "package old\n\nX :: 1\n"},
					{"b.odin", "package old\n\nimport \"../old\"\n\nY :: old.X\n"},
				},
			},
		},
		collections = {"shared" = "test"},
	}
	test.expect_rename_package(
		t,
		&source,
		"old",
		"fresh",
		{{"fresh/b.odin", "package fresh\n\nimport \"../fresh\"\n\nY :: old.X\n"}},
		{"test/old/b.odin:5:6: cannot resolve `old.X`, so the rename does not change it"},
	)
}

// Corpus: reduced (odin-http review), see docs/corpus-validation.md. `#defined(old)` compiles inside a
// procedure and is true while the import binds old.
@(test)
rename_package_rewrites_bare_package_name :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "shared:old"

_ :: old

f :: proc() {
	when #defined(old) {}
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
			{"main.odin", `package test

import "shared:fresh"

_ :: fresh

f :: proc() {
	when #defined(fresh) {}
}
`},
			{"fresh/a.odin", "package fresh\n\nX :: 1\n\nS :: struct {\n\told: int,\n}\n"},
			{"fresh/a_test.odin", "package fresh_test\n\nT :: 2\n"},
		},
	)
}

@(test)
rename_package_leaves_fields_named_like_the_package :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "shared:old"

S :: struct {
	old: int,
}

alias :: old
s := S{old = 1}
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
			{"main.odin", `package test

import "shared:fresh"

S :: struct {
	old: int,
}

alias :: fresh
s := S{old = 1}
`},
			{"fresh/a.odin", "package fresh\n\nX :: 1\n\nS :: struct {\n\told: int,\n}\n"},
			{"fresh/a_test.odin", "package fresh_test\n\nT :: 2\n"},
		},
	)
}

// The cursor on the name of the package clause prepares that name, without the `_test` suffix.
@(test)
rename_package_clause_prepare :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package play{*}test_test\n\nX :: 1\n",
	}
	range := common.Range {
		start = {line = 0, character = 8},
		end = {line = 0, character = 16},
	}
	test.expect_prepare_rename_range(t, &source, range)
}

// File scope, so the source slices outlive the procedures that build the fixtures.
@(private = "file")
playtest_files := [?]test.File {
	{"playtest/a.odin", "package play{*}test\n\nT :: struct {}\n"},
	{"playtest/a_test.odin", "package playtest_test\n\nU :: 1\n"},
	{"main.odin", "package test\n\nimport \"shared:playtest\"\n\nV :: playtest.T\n"},
	{"other.odin", "package test\n\nimport p \"shared:playtest\"\n\nW :: p.T\n"},
}

// A rename on the package clause renames the package: every clause, the importers' paths, the qualifiers of
// an unaliased import and the directory, but not the qualifiers of an aliased import.
@(test)
rename_package_clause_renames_package :: proc(t: ^testing.T) {
	files := playtest_files
	source := test.Source {
		files = files[:],
		collections = {"shared" = "test"},
		config = {client_rename_file_support = true},
	}
	test.expect_rename_package_clause(
		t,
		&source,
		"gametest",
		{
			{"gametest/a.odin", "package gametest\n\nT :: struct {}\n"},
			{"gametest/a_test.odin", "package gametest_test\n\nU :: 1\n"},
			{"main.odin", "package test\n\nimport \"shared:gametest\"\n\nV :: gametest.T\n"},
			{"other.odin", "package test\n\nimport p \"shared:gametest\"\n\nW :: p.T\n"},
		},
	)
}

// A client without directory renames gets the command line instead.
@(test)
rename_package_clause_needs_client_renames :: proc(t: ^testing.T) {
	files := playtest_files
	source := test.Source {
		files = files[:],
		collections = {"shared" = "test"},
	}
	test.expect_rename_package_clause(t, &source, "gametest", {}, {"the client cannot rename directories"})
}

// The editor rename keeps the warnings of the package rename, so the server can show them.
@(test)
rename_package_clause_keeps_warnings :: proc(t: ^testing.T) {
	source := test.Source {
		files = {
			{"old/b.odin", "package o{*}ld\n\nimport \"../old\"\n\nY :: old.X\n"},
			{"old/a.odin", "package old\n\nX :: 1\n"},
		},
		collections = {"shared" = "test"},
		config = {client_rename_file_support = true},
	}
	test.expect_rename_package_clause(
		t,
		&source,
		"fresh",
		{{"fresh/b.odin", "package fresh\n\nimport \"../fresh\"\n\nY :: old.X\n"}},
		{},
		{"cannot resolve `old.X`, so the rename does not change it"},
	)
}

// The symbol rename of the command line points to rename-package on the package clause.
@(test)
rename_package_clause_symbol_rename_refused :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package te{*}st\n\nX :: 1\n",
	}
	test.expect_rename_refused(t, &source, "fresh", {"use rename-package"})
}
