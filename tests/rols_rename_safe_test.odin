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

// Corpus: karl2d karl2d.odin:5723 and five example files on the S17 rerun, see docs/corpus-validation.md.
@(test)
rename_safe_enum_member_in_call_inside_binary_expression :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Button :: enum {
	Le{*}ft,
	Right,
}

down :: proc(b: Button) -> bool {
	return b == .Left
}

f :: proc(in_rect: bool) -> bool {
	a := in_rect && down(.Left)
	b := down(.Left) || down(.Right)
	return a && b
}
`,
	}
	test.expect_rename(
		t,
		&source,
		"Primary",
		{
			{
				"main.odin",
				`package test

Button :: enum {
	Primary,
	Right,
}

down :: proc(b: Button) -> bool {
	return b == .Primary
}

f :: proc(in_rect: bool) -> bool {
	a := in_rect && down(.Primary)
	b := down(.Primary) || down(.Right)
	return a && b
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

// A package qualifier renames the import in this file, even of a library package.
@(test)
rename_safe_renames_package_qualifier :: proc(t: ^testing.T) {
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
	test.expect_rename(t, &source, "str", {{"main.odin", `package test

import str "core:strings"

main :: proc() {
	_ = str.clone("a")
}
`}})
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
	// A doc file that repeats a declaration is built nowhere, so it does not make Thing ambiguous.
	{"test/doc.odin", `#+build ignore
package test

Thing :: struct {
	field: int,
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

@(test)
rename_safe_refuses_field_capture_in_using_param_proc :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+feature using-stmt
package test

Foo :: struct {
	x{*}: int,
}

limit :: 10

f :: proc(using foo: ^Foo) -> int {
	return limit
}
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"limit",
		{"at test/main.odin:11:9 `limit` refers to `limit` declared at test/main.odin:8, but after the rename it would mean the field through `using foo`"},
	)
}

@(test)
rename_safe_refuses_field_capture_by_using_value_decl :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Foo :: struct {
	x{*}: int,
}

make_foo :: proc() -> Foo {
	return {}
}

limit :: 10

f :: proc() -> int {
	using v := make_foo()
	return limit
}
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"limit",
		{"at test/main.odin:15:9 `limit` refers to `limit` declared at test/main.odin:11, but after the rename it would mean the field through `using v`"},
	)
}

@(test)
rename_safe_refuses_field_capture_by_using_typed_decl :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Foo :: struct {
	x{*}: int,
}

limit :: 10

f :: proc() -> int {
	using v: Foo
	return limit
}
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"limit",
		{"at test/main.odin:11:9 `limit` refers to `limit` declared at test/main.odin:7, but after the rename it would mean the field through `using v`"},
	)
}

@(test)
rename_safe_refuses_field_capture_by_using_value_decl_in_file_without_type :: proc(t: ^testing.T) {
	source := test.Source {
		main  = `package test

Foo :: struct {
	x{*}: int,
}

make_foo :: proc() -> Foo {
	return {}
}
`,
		files = {{"other.odin", `package test

limit :: 10

g :: proc() -> int {
	using v := make_foo()
	return limit
}
`}},
	}
	test.expect_rename_refused(
		t,
		&source,
		"limit",
		{"at test/other.odin:7:9 `limit` refers to `limit` declared at test/other.odin:3, but after the rename it would mean the field through `using v`"},
	)
}

@(test)
rename_safe_refuses_field_collision_in_using_decl_scope :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Foo :: struct {
	x{*}: int,
}

f :: proc() {
	using v: Foo
	y := 1
	_ = y
}
`,
	}
	test.expect_rename_refused(t, &source, "y", {"`y` is already declared in the scope of `using v` at test/main.odin:9:2"})
}

@(test)
rename_safe_refuses_collision_through_using_decl :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Foo :: struct {
	x: int,
}

f :: proc() {
	using v: Foo
	y{*} := 1
	_ = y
}
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"x",
		{"`x` is already declared in the same scope through `using v` at test/main.odin:8:8"},
	)
}

@(test)
rename_safe_refuses_field_collision_with_later_using_decl :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Foo :: struct {
	x{*}: int,
}

Bar :: struct {
	limit: int,
}

f :: proc() {
	using v: Foo
	using w: Bar
}
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"limit",
		{"`limit` is already declared in the scope of `using v` at test/main.odin:13:8"},
	)
}

@(test)
rename_safe_refuses_field_collision_with_earlier_using_decl :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Foo :: struct {
	x{*}: int,
}

Bar :: struct {
	limit: int,
}

f :: proc() {
	using w: Bar
	using v: Foo
}
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"limit",
		{"`limit` is already declared in the scope of `using v` at test/main.odin:12:8"},
	)
}

@(test)
rename_safe_refuses_collision_through_using_statement :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+feature using-stmt
package test

Foo :: struct {
	x: int,
}

f :: proc(p: Foo) {
	using p
	y{*} := 1
	_ = y
}
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"x",
		{"`x` is already declared in the same scope through `using p` at test/main.odin:9:8"},
	)
}

@(test)
rename_safe_refuses_field_named_like_its_using_decl :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Foo :: struct {
	x{*}: int,
}

f :: proc() {
	using v: Foo
}
`,
	}
	test.expect_rename_refused(t, &source, "v", {"`v` is already declared in the scope of `using v` at test/main.odin:8:8"})
}

@(test)
rename_safe_allows_field_rename_in_using_param_proc :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+feature using-stmt
package test

Foo :: struct {
	x{*}: int,
}

limit :: 10

f :: proc(using foo: Foo) -> int {
	if true {
		z := x
		_ = z
	}
	return limit + x
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
				`#+feature using-stmt
package test

Foo :: struct {
	width: int,
}

limit :: 10

f :: proc(using foo: Foo) -> int {
	if true {
		z := width
		_ = z
	}
	return limit + width
}
`,
			},
		},
	)
}

@(test)
rename_safe_refuses_field_collision_in_nested_block_of_using_param_proc :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+feature using-stmt
package test

Foo :: struct {
	x{*}: int,
}

f :: proc(using foo: Foo) {
	if true {
		y := 1
		_ = y
	}
}
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"y",
		{"`y` is already declared in the scope of `using foo` at test/main.odin:10:3"},
	)
}

@(test)
rename_safe_allows_field_rename_to_name_used_in_nested_proc_literal :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+feature using-stmt
package test

Foo :: struct {
	x{*}: int,
}

limit :: 10

f :: proc(using foo: Foo) -> int {
	g := proc() -> int {
		return limit
	}
	return g() + x
}
`,
	}
	test.expect_rename(
		t,
		&source,
		"limit",
		{
			{
				"main.odin",
				`#+feature using-stmt
package test

Foo :: struct {
	limit: int,
}

limit :: 10

f :: proc(using foo: Foo) -> int {
	g := proc() -> int {
		return limit
	}
	return g() + limit
}
`,
			},
		},
	)
}

@(test)
rename_safe_refuses_collision_in_transitive_embedder :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Base :: struct {
	y{*}: int,
}

Mid :: struct {
	using b: Base,
}

Top :: struct {
	using m: Mid,
	x: int,
}
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"x",
		{"`x` is already a member of a type that embeds this one through `using m` at test/main.odin:13:2"},
	)
}

@(test)
rename_safe_refuses_collision_in_using_param_of_transitive_embedder :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+feature using-stmt
package test

Base :: struct {
	y{*}: int,
}

Mid :: struct {
	using b: Base,
}

f :: proc(using m: Mid) {
	x := 1
	_ = x
}
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"x",
		{"`x` is already declared in the scope of `using m` at test/main.odin:13:2"},
	)
}

@(test)
rename_safe_allows_field_rename_through_transitive_embedder :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Base :: struct {
	y{*}: int,
}

Mid :: struct {
	using b: Base,
}

Top :: struct {
	using m: Mid,
	x: int,
}
`,
	}
	test.expect_rename(
		t,
		&source,
		"z",
		{
			{
				"main.odin",
				`package test

Base :: struct {
	z: int,
}

Mid :: struct {
	using b: Base,
}

Top :: struct {
	using m: Mid,
	x: int,
}
`,
			},
		},
	)
}

@(test)
rename_safe_refuses_field_collision_with_using_statement :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+feature using-stmt
package test

Foo :: struct {
	x{*}: int,
}

f :: proc(foo: Foo) {
	using foo
	y := 1
	_ = y
}
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"y",
		{"`y` is already declared in the scope of `using foo` at test/main.odin:10:2"},
	)
}

@(test)
rename_safe_refuses_field_capture_by_using_statement :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+feature using-stmt
package test

Foo :: struct {
	x{*}: int,
}

limit :: 10

f :: proc(foo: ^Foo) -> int {
	using foo
	return limit
}
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"limit",
		{"at test/main.odin:12:9 `limit` refers to `limit` declared at test/main.odin:8, but after the rename it would mean the field through `using foo`"},
	)
}

@(test)
rename_safe_allows_field_rename_with_unrelated_using_statement :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+feature using-stmt
package test

Foo :: struct {
	x{*}: int,
}

limit :: 10

f :: proc(foo: Foo) -> int {
	y := 1
	{
		using foo
		_ = x
	}
	return limit + y
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
				`#+feature using-stmt
package test

Foo :: struct {
	width: int,
}

limit :: 10

f :: proc(foo: Foo) -> int {
	y := 1
	{
		using foo
		_ = width
	}
	return limit + y
}
`,
			},
		},
	)
}

// A use of the new name that already means a field through another `using` is captured by the inner `using`.
@(test)
rename_safe_refuses_field_capture_of_other_using_field :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+feature using-stmt
package test

Foo :: struct {
	x{*}: int,
}

Bar :: struct {
	limit: int,
}

f :: proc(using bar: Bar, foo: Foo) -> int {
	{
		using foo
		return limit
	}
}
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"limit",
		{
			"at test/main.odin:15:10 `limit` refers to `limit` declared at test/main.odin:9, but after the rename it would mean the field through `using foo`",
		},
	)
}

// A field that the `using` of a nested block brings in shadows the renamed field, so the use keeps its meaning.
@(test)
rename_safe_allows_field_of_using_in_nested_block :: proc(t: ^testing.T) {
	main := `#+feature using-stmt
package test

Foo :: struct {
	x{*}: int,
}

Bar :: struct {
	limit: int,
}

f :: proc(using foo: Foo, bar: Bar) -> int {
	{
		using bar
		return limit
	}
}
`
	source := test.Source {
		main = main,
	}
	test.expect_rename_refused(t, &source, "limit", {})
}

// An alias, a distinct type or a pointer alias of the owner carries the field to the structs and procedures that
// embed it through `using`.
@(test)
rename_safe_refuses_collision_in_embedder_of_alias :: proc(t: ^testing.T) {
	source := test.Source {
		main  = `package test

Foo :: struct {
	y{*}: int,
}

Alias :: Foo

Top :: struct {
	using a: Alias,
	x: int,
}
`,
		files = {
			{"other.odin", `package test

D :: distinct Foo

Top_D :: struct {
	using d: D,
	x: int,
}
`},
			{"ptr.odin", `#+feature using-stmt
package test

P :: ^Foo

g :: proc(using p: P) {
	x := 1
	_ = x
}
`},
		},
	}
	test.expect_rename_refused(
		t,
		&source,
		"x",
		{
			"`x` is already a member of a type that embeds this one through `using a` at test/main.odin:11:2",
			"`x` is already a member of a type that embeds this one through `using d` at test/other.odin:7:2",
			"`x` is already declared in the scope of `using p` at test/ptr.odin:7:2",
		},
	)
}

@(test)
rename_safe_refuses_collision_in_embedder_of_lone_alias :: proc(t: ^testing.T) {
	source := test.Source {
		main  = `package test

Foo :: struct {
	y{*}: int,
}
`,
		files = {
			{"alias.odin", `package test

Alias :: Foo
`},
			{"top.odin", `package test

Top :: struct {
	using a: Alias,
	x: int,
}
`},
		},
	}
	test.expect_rename_refused(
		t,
		&source,
		"x",
		{"`x` is already a member of a type that embeds this one through `using a` at test/top.odin:5:2"},
	)
}

@(test)
rename_safe_refuses_capture_by_using_of_call_result :: proc(t: ^testing.T) {
	source := test.Source {
		main  = `package test

Foo :: struct {
	y{*}: int,
}

limit :: 10

make_foo :: proc() -> ^Foo {
	return nil
}
`,
		files = {
			{"b.odin", `#+feature using-stmt
package test

g :: proc() -> int {
	f := make_foo()
	using f
	return limit
}
`},
		},
	}
	test.expect_rename_refused(
		t,
		&source,
		"limit",
		{"at test/b.odin:7:9 `limit` refers to `limit` declared at test/main.odin:7, but after the rename it would mean the field through `using f`"},
	)
}

// A `when` body opens no scope, so the fields that a `using` inside it brings in stay visible after it.
@(test)
rename_safe_refuses_field_capture_by_using_in_when_body :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Foo :: struct {
	x{*}: int,
}

limit :: 10

f :: proc() -> int {
	when true {
		using v: Foo
	}
	return limit
}
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"limit",
		{"at test/main.odin:13:9 `limit` refers to `limit` declared at test/main.odin:7, but after the rename it would mean the field through `using v`"},
	)
}

@(test)
rename_safe_refuses_field_capture_by_using_statement_in_when_body :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+feature using-stmt
package test

Foo :: struct {
	x{*}: int,
}

limit :: 10

f :: proc(foo: ^Foo) -> int {
	when true {
		using foo
	}
	return limit
}
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"limit",
		{"at test/main.odin:14:9 `limit` refers to `limit` declared at test/main.odin:8, but after the rename it would mean the field through `using foo`"},
	)
}

// A declaration after the `when` body shares the scope of the `using` inside it.
@(test)
rename_safe_refuses_collision_after_using_in_when_body :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Foo :: struct {
	x{*}: int,
}

f :: proc() -> int {
	when true {
		using v: Foo
	} else {
		w := 1
	}
	limit := 2
	return limit
}
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"limit",
		{"`limit` is already declared in the scope of `using v` at test/main.odin:13:2"},
	)
}

// A `using` of the struct variant that only another target builds embeds the renamed field too.
@(test)
rename_safe_refuses_embedder_collision_of_other_variant_file :: proc(t: ^testing.T) {
	source := test.Source {
		main  = `package test

g :: proc(s: S) -> int { return s.a{*} }
`,
		files = {
			{"s.odin", "#+build !windows\npackage test\n\nS :: struct { a: int }\n"},
			{"s_windows.odin", "package test\n\nS :: struct { a: int }\n"},
			{"e_windows.odin", "package test\n\nE :: struct {\n\tusing s: S,\n\tb: int,\n}\n"},
		},
	}
	test.expect_rename_refused(
		t,
		&source,
		"b",
		{"`b` is already a member of a type that embeds this one through `using s` at test/e_windows.odin:5:2"},
	)
}

@(test)
rename_safe_refuses_embedder_collision_of_other_variant_when :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

when ODIN_OS == .Windows {
	S :: struct { a: int }
	E :: struct {
		using s: S,
		b: int,
	}
} else {
	S :: struct { a: int }
}

g :: proc(s: S) -> int { return s.a{*} }
`,
	}
	test.expect_rename_refused(
		t,
		&source,
		"b",
		{"`b` is already a member of a type that embeds this one through `using s` at test/main.odin:7:3"},
	)
}

// An alias of the type in another package carries the field, and the alias's other platform variant keeps it.
@(test)
rename_safe_refuses_field_through_alias_with_variants_in_other_package :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

import "other"

when ODIN_DEBUG {
	S :: struct { a: int }
} else {
	S :: other.S_Other
}

g :: proc(s: S) -> int { return s.a{*} }
`,
		// A relative import: the reference search parses the imports of other files with the global config.
		packages = {{pkg = "other", source = "package other\n\nS_Other :: struct { a: int }\n"}},
	}
	test.expect_rename_refused(
		t,
		&source,
		"b",
		{"`S` at test/main.odin:8 carries the renamed field `a`, but its platform variant `S` at test/main.odin:6 is another type, which the rename does not change"},
	)
}

// Two branches of one `when` never build together, so a use in one branch cannot be captured by a `using` in the
// other, and a declaration there does not collide with it.
@(test)
rename_safe_allows_using_and_use_in_separate_when_branches :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Foo :: struct {
	x{*}: int,
}

limit :: 10

f :: proc() -> int {
	when ODIN_DEBUG {
		using v: Foo
	} else {
		return limit
	}
	return 0
}
`,
	}
	test.expect_rename_refused(t, &source, "limit", {})
}

@(test)
rename_safe_allows_declaration_in_other_when_branch_than_using :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Foo :: struct {
	x{*}: int,
}

f :: proc() -> int {
	when ODIN_DEBUG {
		limit := 2
		_ = limit
	} else when ODIN_OS == .Windows {
		using v: Foo
	}
	return 0
}
`,
	}
	test.expect_rename_refused(t, &source, "limit", {})
}

// Two aliases that carry the field share a variant that does not, which is reported once.
@(test)
rename_safe_reports_shared_alias_variant_once :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

import "other"

when ODIN_OS == .Windows {
	S :: other.S_Other
} else when ODIN_OS == .Linux {
	S :: other.S_Other
} else {
	S :: struct { a: int }
}

g :: proc(s: other.S_Other) -> int { return s.a{*} }
`,
		packages = {{pkg = "other", source = "package other\n\nS_Other :: struct { a: int }\n"}},
	}
	test.expect_rename_refused(t, &source, "b", {"its platform variant `S` at test/main.odin:10 is another type"})
}

// Every variant of an embedder embeds the field's type, so each carries the renamed field.
@(test)
rename_safe_allows_embedder_variants_that_all_embed_the_type :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Common :: struct { a: int }

when ODIN_OS == .Windows {
	W :: struct { using base: Common }
} else {
	W :: struct { using base: Common, x: int }
}

g :: proc(w: W) -> int { return w.a{*} }
`,
	}
	test.expect_rename_refused(t, &source, "b", {})
}

@(test)
rename_safe_allows_embedder_variants_in_other_package_that_all_embed_the_type :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

import "other"

when ODIN_OS == .Windows {
	W :: struct { using base: other.Common }
} else {
	W :: struct { using base: other.Common, x: int }
}

g :: proc(w: W) -> int { return w.a{*} }
`,
		packages = {{pkg = "other", source = "package other\n\nCommon :: struct { a: int }\n"}},
	}
	test.expect_rename_refused(t, &source, "b", {})
}

// Every variant of the alias carries the field: one aliases the type, the other a distinct alias of it.
@(test)
rename_safe_allows_alias_variants_that_all_carry_the_field :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S_Other :: struct { a: int }

T :: S_Other

when ODIN_DEBUG {
	S :: S_Other
} else {
	S :: distinct T
}

g :: proc(s: S) -> int { return s.a{*} }
`,
	}
	test.expect_rename_refused(t, &source, "b", {})
}

@(test)
rename_safe_allows_alias_variants_in_other_package_that_all_carry_the_field :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

import "other"

T :: other.S_Other

when ODIN_DEBUG {
	S :: other.S_Other
} else {
	S :: distinct T
}

g :: proc(s: S) -> int { return s.a{*} }
`,
		packages = {{pkg = "other", source = "package other\n\nS_Other :: struct { a: int }\n"}},
	}
	test.expect_rename_refused(t, &source, "b", {})
}
