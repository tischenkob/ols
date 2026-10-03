#+feature dynamic-literals

package tests

import "core:os"
import "core:testing"

import "src:common"
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

@(test)
rename_safe_refuses_collision_through_using_field :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Base :: struct {
	y: int,
}

Foo :: struct {
	using b: Base,
	x{*}: int,
}
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"y",
		{"`y` is already a member of the same type through `using b` at test/main.odin:8:8"},
	)
}

@(test)
rename_safe_refuses_embedded_field_collision :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Base :: struct {
	y{*}: int,
}

Foo :: struct {
	using b: Base,
	x: int,
}
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"x",
		{"`x` is already a member of a type that embeds this one through `using b` at test/main.odin:9:2"},
	)
}

@(test)
rename_safe_refuses_collision_through_using_param :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+feature using-stmt
package test

Foo :: struct {
	x: int,
}

f :: proc(using foo: Foo) {
	y{*} := 1
	_ = y
}
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"x",
		{"`x` is already declared in the same scope through `using foo` at test/main.odin:8:17"},
	)
}

@(test)
rename_safe_refuses_field_collision_in_using_param_scope :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+feature using-stmt
package test

Foo :: struct {
	x{*}: int,
}

f :: proc(using foo: Foo) {
	y := 1
	_ = y
}
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"y",
		{"`y` is already declared in the scope of `using foo` at test/main.odin:9:2"},
	)
}

@(test)
rename_safe_refuses_capture_through_using_param :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+feature using-stmt
package test

Foo :: struct {
	x: int,
}

li{*}mit :: 10

f :: proc(using foo: Foo) -> int {
	return limit
}
`,
	}
	test.expect_rename_refused(t, &source, "x", {"at test/main.odin:11:9 `x` already refers to"})
}

@(test)
rename_safe_refuses_capture_by_later_using_statement :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+feature using-stmt
package test

W :: struct {
	id: int,
}

f :: proc(w: W) -> int {
	x{*} := 1
	{
		using w
		return x
	}
}
`,
	}
	test.expect_rename_refused(t, &source, "id", {"`id` already refers to"})
}

@(test)
rename_safe_allows_name_of_later_inner_using_statement :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+feature using-stmt
package test

W :: struct {
	id: int,
}

f :: proc(w: W) -> int {
	x{*} := 1
	_ = x
	{
		using w
		return id
	}
}
`,
	}
	test.expect_rename(
		t,
		&source,
		"id",
		{
			{
				"main.odin",
				`#+feature using-stmt
package test

W :: struct {
	id: int,
}

f :: proc(w: W) -> int {
	id := 1
	_ = id
	{
		using w
		return id
	}
}
`,
			},
		},
	)
}

@(test)
rename_safe_refuses_capture_by_file_private_global :: proc(t: ^testing.T) {
	source := test.Source {
		main  = `package test

fo{*}o :: proc() -> int {
	return 1
}
`,
		files = {{"other.odin", `package test

@(private = "file")
bar :: 2

g :: proc() -> int {
	return foo()
}
`}},
	}
	test.expect_rename_refused(
		t,
		&source,
		"bar",
		{"at test/other.odin:7:9 `bar` already refers to `bar` declared at test/other.odin:4"},
	)
}

@(test)
rename_safe_refuses_capture_by_private_file_tag :: proc(t: ^testing.T) {
	source := test.Source {
		main  = `package test

fo{*}o :: proc() -> int {
	return 1
}
`,
		files = {{"other.odin", `#+private file
package test

bar :: 2

g :: proc() -> int {
	return foo()
}
`}},
	}
	test.expect_rename_refused(
		t,
		&source,
		"bar",
		{"at test/other.odin:7:9 `bar` already refers to `bar` declared at test/other.odin:4"},
	)
}

@(test)
rename_safe_refuses_using_field_named_like_its_member :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Base :: struct {
	y: int,
}

Foo :: struct {
	using b{*}: Base,
	x: int,
}
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"y",
		{"`y` is already a member of the same type through `using b` at test/main.odin:8:8"},
	)
}

@(test)
rename_safe_refuses_using_param_named_like_its_member :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+feature using-stmt
package test

Foo :: struct {
	x: int,
}

f :: proc(using fo{*}o: Foo) {}
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"x",
		{"`x` is already declared in the same scope through `using foo` at test/main.odin:8:17"},
	)
}

@(test)
rename_safe_refuses_embedded_field_named_like_using_field :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Base :: struct {
	y{*}: int,
}

Foo :: struct {
	using b: Base,
}
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"b",
		{"`b` is already a member of a type that embeds this one through `using b` at test/main.odin:8:8"},
	)
}

// Odin accepts a package global next to a file-private declaration of the same name in another file.
@(test)
rename_safe_allows_file_private_name_without_reference :: proc(t: ^testing.T) {
	source := test.Source {
		main  = `package test

fo{*}o :: proc() -> int {
	return 1
}
`,
		files = {{"other.odin", `package test

@(private = "file")
bar :: 2
`}},
	}
	test.expect_rename(t, &source, "bar", {{"main.odin", `package test

bar :: proc() -> int {
	return 1
}
`}})
}

@(test)
rename_safe_refuses_type_switch_collision :: proc(t: ^testing.T) {
	variable := test.Source {
		main = `package test

U :: union {
	int,
	f32,
}

main :: proc() {
	u: U
	switch v{*} in u {
	case int:
		w := 1
		_ = w + v
	case f32:
	}
}
`,
	}
	test.expect_rename_refused(
		t,
		&variable,
		"w",
		{
			"`w` is already declared in the same scope at test/main.odin:12:3",
			"at test/main.odin:13:11 `w` already refers to",
		},
	)

	body_local := test.Source {
		main = `package test

U :: union {
	int,
	f32,
}

main :: proc() {
	u: U
	switch v in u {
	case int:
		w{*} := 1
		_ = w + v
	case f32:
	}
}
`,
	}
	test.expect_rename_refused(
		t,
		&body_local,
		"v",
		{"`v` is already declared in the same scope at test/main.odin:10:9", "at test/main.odin:13:11 `v` refers to"},
	)
}

// A cursor resolves the locals of the `when` branch that holds it, and each target here is in the else
// branch, which the host builds because ODIN_DEBUG is false.
@(test)
rename_safe_refuses_collision_in_when_body :: proc(t: ^testing.T) {
	inside := test.Source {
		main = `package test

main :: proc() {
	x := 1
	when ODIN_DEBUG {
	} else {
		y{*} := 2
		_ = y
	}
	_ = x
}
`,
	}
	test.expect_rename_refused(
		t,
		&inside,
		"x",
		{"`x` is already declared in the same scope at test/main.odin:4:2", "at test/main.odin:10:6 `x` refers to"},
	)

	outside := test.Source {
		main = `package test

main :: proc() {
	x{*} := 1
	when ODIN_DEBUG {
	} else {
		y := 2
		_ = y
	}
	_ = x
}
`,
	}
	test.expect_rename_refused(
		t,
		&outside,
		"y",
		{
			"`y` is already declared in the same scope at test/main.odin:7:3",
			"at test/main.odin:10:6 `y` already refers to",
		},
	)
}

@(test)
rename_safe_allows_member_name_of_later_local_type :: proc(t: ^testing.T) {
	field := test.Source {
		main = `package test

main :: proc() {
	n{*} := 1
	Point :: struct {
		width: int,
	}
	p := Point{}
	_ = n + p.width
}
`,
	}
	test.expect_rename(
		t,
		&field,
		"width",
		{
			{
				"main.odin",
				`package test

main :: proc() {
	width := 1
	Point :: struct {
		width: int,
	}
	p := Point{}
	_ = width + p.width
}
`,
			},
		},
	)

	member := test.Source {
		main = `package test

main :: proc() {
	n{*} := 1
	Shade :: enum {
		Dark,
		Light = 2,
	}
	_ = n + int(Shade.Light)
}
`,
	}
	test.expect_rename(
		t,
		&member,
		"Light",
		{
			{
				"main.odin",
				`package test

main :: proc() {
	Light := 1
	Shade :: enum {
		Dark,
		Light = 2,
	}
	_ = Light + int(Shade.Light)
}
`,
			},
		},
	)
}

// The harness files lie under test/, which does not exist, so canonical_dir resolves them below the
// working directory, as it does the workspace folder.
@(test)
rename_safe_allows_missing_dir_in_workspace :: proc(t: ^testing.T) {
	cwd, err := os.get_working_directory(context.temp_allocator)
	if !testing.expect_value(t, err, nil) do return
	source := test.Source {
		main = `package test

fo{*}o :: proc() {}
`,
	}
	source.config.workspace_folders = make([dynamic]common.WorkspaceFolder, context.temp_allocator)
	append(
		&source.config.workspace_folders,
		common.WorkspaceFolder{uri = common.create_uri(cwd, context.temp_allocator).uri},
	)
	test.expect_rename(t, &source, "bar", {{"main.odin", `package test

bar :: proc() {}
`}})
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

@(test)
rename_local_in_inactive_when_branch :: proc(t: ^testing.T) {
	// FOLLOWUPS "Safe-rename check": get_locals took only the active branch.
	source := test.Source {
		main = `package test

DEBUG :: true

f :: proc() -> int {
	when !DEBUG {
		va{*}lue := 1
		return value
	} else {
		return 2
	}
}
`,
	}
	test.expect_rename(
		t,
		&source,
		"count",
		{
			{
				"main.odin",
				`package test

DEBUG :: true

f :: proc() -> int {
	when !DEBUG {
		count := 1
		return count
	} else {
		return 2
	}
}
`,
			},
		},
	)
}
