#+feature dynamic-literals

package tests

import "core:testing"

import "src:server"
import test "src:testing"

@(test)
rename_safe_struct_field_two_files :: proc(t: ^testing.T) {
	source := test.Source {
		main  = `package test

Foo :: struct {
	ba{*}r: int,
	baz: int,
}

main :: proc() {
	f := Foo{bar = 1}
	_ = f.bar + f.baz
}
`,
		files = {{"other.odin", `package test

other :: proc(f: Foo) -> int {
	return f.bar
}
`}},
	}
	test.expect_rename(
		t,
		&source,
		"count",
		{
			{
				"main.odin",
				`package test

Foo :: struct {
	count: int,
	baz: int,
}

main :: proc() {
	f := Foo{count = 1}
	_ = f.count + f.baz
}
`,
			},
			{"other.odin", `package test

other :: proc(f: Foo) -> int {
	return f.count
}
`},
		},
	)
}

@(test)
rename_safe_enum_member :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Color :: enum {
	Re{*}d,
	Green,
}

main :: proc() {
	c: Color = .Red
	_ = c == Color.Red
}
`,
	}
	test.expect_rename(
		t,
		&source,
		"Blue",
		{
			{
				"main.odin",
				`package test

Color :: enum {
	Blue,
	Green,
}

main :: proc() {
	c: Color = .Blue
	_ = c == Color.Blue
}
`,
			},
		},
	)
}

// A collection outside core:, vendor: and base: may hold workspace code, so its symbols rename.
@(test)
rename_safe_cross_package_proc :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "shared:util"

main :: proc() {
	_ = util.hel{*}per(1)
}
`,
		packages = {{pkg = "util", source = `package util

helper :: proc(x: int) -> int {
	return x + 1
}
`}},
		collections = {"shared" = "test"},
	}
	test.expect_rename(
		t,
		&source,
		"assist",
		{
			{"main.odin", `package test

import "shared:util"

main :: proc() {
	_ = util.assist(1)
}
`},
			{"util/package.odin", `package util

assist :: proc(x: int) -> int {
	return x + 1
}
`},
		},
	)
}

@(private = "file")
util_package :: proc() -> []test.Package {
	packages := make([dynamic]test.Package, context.temp_allocator)
	append(
		&packages,
		test.Package {
			pkg = "util",
			source = `package util

helper :: proc(x: int) -> int {
	return x + 1
}

assist :: proc(x: int) -> int {
	return x
}
`,
		},
	)
	return packages[:]
}

@(test)
rename_safe_refuses_collision_through_package_member :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "shared:util"

main :: proc() {
	_ = util.hel{*}per(1)
}
`,
		packages = util_package(),
		collections = {"shared" = "test"},
	}
	test.expect_rename_refused(
		t,
		&source,
		"assist",
		{"`assist` is already declared in the package at test/util/package.odin:7:1"},
	)
}

@(test)
rename_safe_refuses_builtin_through_package_member :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "shared:util"

main :: proc() {
	_ = util.hel{*}per(1)
}
`,
		packages = util_package(),
		collections = {"shared" = "test"},
	}
	test.expect_rename_refused(t, &source, "len", {"`len` is a builtin name"})
}

@(test)
rename_safe_allows_comp_lit_key_name :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Rect :: struct {
	width: int,
}

main :: proc() {
	w{*} := 3
	r := Rect{width = w}
	_ = r
}
`,
	}
	test.expect_rename(
		t,
		&source,
		"width",
		{
			{
				"main.odin",
				`package test

Rect :: struct {
	width: int,
}

main :: proc() {
	width := 3
	r := Rect{width = width}
	_ = r
}
`,
			},
		},
	)
}

@(test)
rename_safe_allows_named_argument_name :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

draw :: proc(width: int) {}

main :: proc() {
	w{*} := 3
	draw(width = w)
}
`,
	}
	test.expect_rename(
		t,
		&source,
		"width",
		{
			{
				"main.odin",
				`package test

draw :: proc(width: int) {}

main :: proc() {
	width := 3
	draw(width = width)
}
`,
			},
		},
	)
}

@(test)
rename_safe_refuses_capture_at_spread :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

da{*}ta := []int{1, 2}

sum :: proc(xs: ..int) -> int {
	return 0
}

main :: proc() {
	nums := 1
	_ = nums + sum(..data)
}
`,
	}
	test.expect_rename_refused(t, &source, "nums", {"at test/main.odin:11:19 `nums` already refers to `nums`"})
}

@(test)
rename_safe_marks_collision_in_when_branch :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

fo{*}o :: proc() {}

when ODIN_DEBUG {
	bar :: 1
}
`,
	}
	test.expect_rename_refused(t, &source, "bar", {"at test/main.odin:6:2 (in a when branch)"})
}

@(test)
rename_safe_refuses_keyword :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

fo{*}o :: proc() {}
`,
	}
	test.expect_rename_refused(t, &source, "proc", {"`proc` is a keyword"})
}

@(test)
rename_safe_refuses_builtin :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

fo{*}o :: proc() {}

main :: proc() {
	foo()
}
`,
	}
	test.expect_rename_refused(t, &source, "len", {"`len` is a builtin name"})
}

@(test)
rename_safe_refuses_builtin_type_name :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

fo{*}o :: 1
`,
	}
	test.expect_rename_refused(t, &source, "int", {"`int` is a builtin name"})
}

@(test)
rename_safe_refuses_invalid_identifier :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

fo{*}o :: proc() {}
`,
	}
	test.expect_rename_refused(t, &source, "1abc", {"`1abc` is not a valid Odin identifier"})
}

@(test)
rename_safe_refuses_collision :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

fo{*}o :: proc() {}

bar :: proc() {}
`,
	}
	test.expect_rename_refused(t, &source, "bar", {"`bar` is already declared in the package at test/main.odin:5:1"})
}

@(test)
rename_safe_refuses_sibling_field :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Foo :: struct {
	ba{*}r: int,
	baz: int,
}
`,
	}
	test.expect_rename_refused(t, &source, "baz", {"`baz` is already a member of the same type at test/main.odin:5:2"})
}

@(test)
rename_safe_refuses_capture_at_reference :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

hel{*}per :: proc() -> int {
	return 1
}

main :: proc() {
	count := 2
	_ = count + helper()
}
`,
	}
	test.expect_rename_refused(t, &source, "count", {"at test/main.odin:9:14 `count` already refers to `count`"})
}

@(test)
rename_safe_refuses_shadowing_local :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

limit :: 10

main :: proc() {
	val{*}ue := 1
	_ = value + limit
}
`,
	}
	test.expect_rename_refused(t, &source, "limit", {"at test/main.odin:7:14 `limit` refers to `limit`"})
}

@(test)
rename_safe_allows_shadowing_global_unused :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

limit :: 10

main :: proc() {
	val{*}ue := 1
	_ = value
}
`,
	}
	test.expect_rename(
		t,
		&source,
		"limit",
		{{"main.odin", `package test

limit :: 10

main :: proc() {
	limit := 1
	_ = limit
}
`}},
	)
}

@(test)
rename_safe_refuses_core_target :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "core:strings"

main :: proc() {
	_ = strings.clo{*}ne("a")
}
`,
		packages = {{pkg = "strings", source = `package strings

clone :: proc(s: string) -> string {
	return s
}
`}},
		collections = {"core" = "test"},
	}
	test.expect_rename_refused(t, &source, "copy_string", {"the declaration is in core:strings"})
}

@(test)
rename_safe_refuses_package_qualifier :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "core:strings"

main :: proc() {
	_ = stri{*}ngs.clone("a")
}
`,
		packages = {{pkg = "strings", source = `package strings

clone :: proc(s: string) -> string {
	return s
}
`}},
		collections = {"core" = "test"},
	}
	test.expect_rename_refused(t, &source, "str", {"use rename-package"})
}

@(test)
rename_safe_same_name_is_not_refused :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

fo{*}o :: proc() {}

main :: proc() {
	foo()
}
`,
	}
	test.expect_rename_refused(t, &source, "foo", {})
}

@(private = "file")
symbol_path_files := []server.Package_File {
	{
		"test/a.odin",
		`package test

Thing :: struct {
	field: int,
}

Color :: enum {
	Red,
	Green = 2,
}

Flags :: bit_field u8 {
	low: u8 | 4,
}

total :: proc() -> int {
	return 0
}
`,
	},
	{"test/b.odin", `package test

when ODIN_OS == .Windows {
	twice :: 1
} else {
	twice :: 2
}
`},
}

@(test)
symbol_path_finds_declarations_and_members :: proc(t: ^testing.T) {
	Case :: struct {
		names:        string,
		line, column: int,
	}
	cases := []Case {
		{"Thing", 3, 1},
		{"Thing.field", 4, 2},
		{"Color.Green", 9, 2},
		{"Flags.low", 13, 2},
		{"total", 16, 1},
	}
	for c in cases {
		target, reason, ok := server.find_symbol_path("test", c.names, symbol_path_files)
		testing.expectf(t, ok, "%s: %s", c.names, reason)
		testing.expect_value(t, target, server.Symbol_Path_Target{"test/a.odin", c.line, c.column})
	}
}

@(test)
symbol_path_refusals :: proc(t: ^testing.T) {
	Case :: struct {
		names, reason: string,
	}
	cases := []Case {
		{"Nope", "no top-level declaration `Nope` in the package test"},
		{"Thing.nope", "`Thing` has no member `nope`"},
		{"total.x", "`total` is not a struct, enum or bit_field type, so it has no member `x`"},
		{"twice", "`twice` is declared 2 times in the package test, at test/b.odin:4:2, test/b.odin:6:2"},
		{"Thing.field.x", "`Thing.field.x` is not Name or Name.Member after the package test"},
	}
	for c in cases {
		_, reason, ok := server.find_symbol_path("test", c.names, symbol_path_files)
		testing.expectf(t, !ok, "%s resolved", c.names)
		testing.expectf(
			t,
			len(reason) >= len(c.reason) && reason[:len(c.reason)] == c.reason,
			"%s: %q",
			c.names,
			reason,
		)
	}
}
