#+feature dynamic-literals
package tests

import "core:strings"
import "core:testing"

import test "src:testing"

EXPAND :: "Expand using"
SUBTYPE :: "Convert using to #subtype"

EXPAND_PRELUDE :: `#+feature using-stmt
package test

Inner :: struct {
	x, y: int,
}

Outer :: struct {
	inner: Inner,
	count: int,
}

Base :: struct {
	base_x: int,
}

Derived :: struct {
	using base: Base,
	own:        int,
}

Kind :: enum {
	A,
	B,
}

use :: proc(values: ..int) {}

`

expand_source :: proc(body: string) -> string {
	return strings.concatenate({EXPAND_PRELUDE, body}, context.temp_allocator)
}

expect_expand_using :: proc(t: ^testing.T, body, expected: string) {
	source := test.Source {
		main = expand_source(body),
		config = {enable_code_action_expand_using = true},
	}
	test.expect_action_applied(t, &source, EXPAND, expand_source(expected))
}

expect_no_expand_using :: proc(t: ^testing.T, body: string) {
	source := test.Source {
		main = expand_source(body),
		config = {enable_code_action_expand_using = true},
	}
	test.expect_action_missing(t, &source, EXPAND)
}

@(test)
expand_using_qualifies_each_promoted_name :: proc(t: ^testing.T) {
	expect_expand_using(
		t,
		"main :: proc() {\n\ta: Outer\n\tusing{*} a.inner\n\tx = 1\n\tuse(x, y, a.count)\n}\n",
		"main :: proc() {\n\ta: Outer\n\ta.inner.x = 1\n\tuse(a.inner.x, a.inner.y, a.count)\n}\n",
	)
}

@(test)
expand_using_restores_what_lift_using_wrote :: proc(t: ^testing.T) {
	original := expand_source("main :: proc() {\n\ta: Outer\n\ta.inner.x = 1\n\tuse(a.{*}inner.y)\n}\n")
	lifted := expand_source("main :: proc() {\n\ta: Outer\n\tusing a.inner\n\tx = 1\n\tuse(y)\n}\n")
	restored := expand_source("main :: proc() {\n\ta: Outer\n\ta.inner.x = 1\n\tuse(a.inner.y)\n}\n")
	lift := test.Source {
		main = original,
		config = {enable_code_action_lift_using = true},
	}
	test.expect_action_applied(t, &lift, "Lift using a.inner", lifted)

	cursor := expand_source("main :: proc() {\n\ta: Outer\n\tusing{*} a.inner\n\tx = 1\n\tuse(y)\n}\n")
	expand := test.Source {
		main = cursor,
		config = {enable_code_action_expand_using = true},
	}
	test.expect_action_applied(t, &expand, EXPAND, restored)
}

@(test)
expand_using_reaches_nested_blocks_and_stops_at_the_block_end :: proc(t: ^testing.T) {
	expect_expand_using(
		t,
		"main :: proc() {\n\ta: Inner\n\tx := 0\n\t{\n\t\tb: Inner\n\t\tusing{*} b\n\t\tif y > 0 {\n\t\t\tuse(y)\n\t\t}\n\t}\n\tuse(x, a.x)\n}\n",
		"main :: proc() {\n\ta: Inner\n\tx := 0\n\t{\n\t\tb: Inner\n\t\tif b.y > 0 {\n\t\t\tuse(b.y)\n\t\t}\n\t}\n\tuse(x, a.x)\n}\n",
	)
}

@(test)
expand_using_leaves_a_shadowing_local_and_uses_above_alone :: proc(t: ^testing.T) {
	expect_expand_using(
		t,
		"main :: proc() {\n\ty := 2\n\tuse(y)\n\t{\n\t\tb: Inner\n\t\tusing{*} b\n\t\t{\n\t\t\tx := x\n\t\t\tuse(x)\n\t\t}\n\t\tfor x in 0 ..< 2 {\n\t\t\tuse(x)\n\t\t}\n\t\tuse(x)\n\t}\n}\n",
		"main :: proc() {\n\ty := 2\n\tuse(y)\n\t{\n\t\tb: Inner\n\t\t{\n\t\t\tx := b.x\n\t\t\tuse(x)\n\t\t}\n\t\tfor x in 0 ..< 2 {\n\t\t\tuse(x)\n\t\t}\n\t\tuse(b.x)\n\t}\n}\n",
	)
}

@(test)
expand_using_leaves_members_and_nested_procedures_alone :: proc(t: ^testing.T) {
	expect_expand_using(
		t,
		"main :: proc() {\n\tb: Inner\n\tusing{*} b\n\tother := Inner{x = x}\n\tuse(other.x)\n\tf := proc() {\n\t\tx := 1\n\t\tuse(x)\n\t}\n\tf()\n}\n",
		"main :: proc() {\n\tb: Inner\n\tother := Inner{x = b.x}\n\tuse(other.x)\n\tf := proc() {\n\t\tx := 1\n\t\tuse(x)\n\t}\n\tf()\n}\n",
	)
}

@(test)
expand_using_of_a_pointer_and_a_parameter :: proc(t: ^testing.T) {
	expect_expand_using(
		t,
		"f :: proc(p: ^Inner) {\n\tusing{*} p\n\tx = 1\n}\n",
		"f :: proc(p: ^Inner) {\n\tp.x = 1\n}\n",
	)
}

@(test)
expand_using_of_a_struct_with_a_using_field :: proc(t: ^testing.T) {
	expect_expand_using(
		t,
		"main :: proc() {\n\td: Derived\n\tusing{*} d\n\tuse(base_x, own, base.base_x)\n}\n",
		"main :: proc() {\n\td: Derived\n\tuse(d.base_x, d.own, d.base.base_x)\n}\n",
	)
}

@(test)
expand_using_keeps_a_later_using_of_the_same_block :: proc(t: ^testing.T) {
	expect_expand_using(
		t,
		"main :: proc() {\n\ta: Outer\n\tusing{*} a\n\tusing inner\n\tuse(x, count)\n}\n",
		"main :: proc() {\n\ta: Outer\n\tusing a.inner\n\tuse(x, a.count)\n}\n",
	)
}

@(test)
expand_using_refuses_a_nested_local_that_shadows_the_root :: proc(t: ^testing.T) {
	expect_no_expand_using(t, "main :: proc() {\n\tb: Inner\n\tusing{*} b\n\t{\n\t\tb := 1\n\t\tuse(b, x)\n\t}\n}\n")
}

@(test)
expand_using_refuses_a_nested_using :: proc(t: ^testing.T) {
	expect_no_expand_using(
		t,
		"main :: proc() {\n\tb: Inner\n\tc: Inner\n\tusing{*} b\n\t{\n\t\tusing c\n\t\tuse(x)\n\t}\n}\n",
	)
}

@(test)
expand_using_refuses_an_import :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+feature using-stmt
package test

import "core:other"

main :: proc() {
	using{*} other
}
`,
		packages = {{pkg = "other", source = "package other\n\nx: int\n"}},
		collections = {"core" = "test"},
		config = {enable_code_action_expand_using = true},
	}
	test.expect_action_missing(t, &source, EXPAND)
}

@(test)
expand_using_refuses_a_type :: proc(t: ^testing.T) {
	expect_no_expand_using(t, "main :: proc() {\n\tusing{*} Kind\n\tuse(int(A))\n}\n")
}

@(test)
expand_using_refuses_a_when_body :: proc(t: ^testing.T) {
	expect_no_expand_using(t, "main :: proc() {\n\tb: Inner\n\twhen true {\n\t\tusing{*} b\n\t}\n\tuse(x)\n}\n")
}

@(test)
expand_using_refuses_a_shared_line :: proc(t: ^testing.T) {
	expect_no_expand_using(t, "main :: proc() {\n\tb: Inner\n\tif true do using{*} b\n}\n")
	expect_no_expand_using(t, "main :: proc() {\n\tb: Inner\n\tusing{*} b; use(x)\n}\n")
	expect_no_expand_using(t, "main :: proc() {\n\tb: Inner\n\tusing{*} b // why\n\tuse(x)\n}\n")
}

@(test)
expand_using_refuses_several_targets :: proc(t: ^testing.T) {
	expect_no_expand_using(t, "main :: proc() {\n\tb: Inner\n\tc: Outer\n\tusing{*} b, c\n\tuse(x, count)\n}\n")
}

@(test)
expand_using_refuses_a_key_it_cannot_type :: proc(t: ^testing.T) {
	expect_no_expand_using(
		t,
		"take :: proc(i: Inner) {}\nmain :: proc() {\n\tb: Inner\n\tusing{*} b\n\ttake({x = 1})\n}\n",
	)
}

@(test)
expand_using_off_with_its_flag :: proc(t: ^testing.T) {
	source := test.Source {
		main = expand_source("main :: proc() {\n\tb: Inner\n\tusing{*} b\n\tuse(x)\n}\n"),
		config = {enable_code_action_expand_using = false},
	}
	test.expect_action_missing(t, &source, EXPAND)
	field := test.Source {
		main = "package test\nBase :: struct {\n\tn: int,\n}\nDerived :: struct {\n\tusing{*} base: Base,\n}\n",
		config = {enable_code_action_expand_using = false},
	}
	test.expect_action_missing(t, &field, SUBTYPE)
}

subtype_source :: proc(keyword, rest: string) -> string {
	return strings.concatenate(
		{
			"package test\nBase :: struct {\n\tn: int,\n}\nDerived :: struct {\n\t",
			keyword,
			" base: Base,\n\town: int,\n}\n",
			rest,
		},
		context.temp_allocator,
	)
}

expect_subtype :: proc(t: ^testing.T, rest: string) {
	source := test.Source {
		main = subtype_source("using{*}", rest),
		config = {enable_code_action_expand_using = true},
	}
	test.expect_action_applied(t, &source, SUBTYPE, subtype_source("#subtype", rest))
}

expect_no_subtype :: proc(t: ^testing.T, rest: string) {
	source := test.Source {
		main = subtype_source("using{*}", rest),
		config = {enable_code_action_expand_using = true},
	}
	test.expect_action_missing(t, &source, SUBTYPE)
}

@(test)
subtype_with_no_use_of_a_member :: proc(t: ^testing.T) {
	expect_subtype(t, "")
}

@(test)
subtype_keeps_uses_through_the_field_and_the_embedded_type :: proc(t: ^testing.T) {
	expect_subtype(
		t,
		"f :: proc(d: Derived, b: Base) -> int {\n\tc := Base{n = 1}\n\treturn d.base.n + b.n + c.n + d.own\n}\n",
	)
}

@(test)
subtype_keeps_a_using_parameter_of_the_embedded_type :: proc(t: ^testing.T) {
	expect_subtype(t, "f :: proc(using b: ^Base) -> int {\n\treturn n\n}\n")
}

@(test)
subtype_cursor_on_the_field_name :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\nBase :: struct {\n\tn: int,\n}\nDerived :: struct {\n\tusing ba{*}se: Base,\n\town: int,\n}\n",
		config = {enable_code_action_expand_using = true},
	}
	test.expect_action_applied(t, &source, SUBTYPE, subtype_source("#subtype", ""))
}

@(test)
subtype_refuses_a_promoted_selector :: proc(t: ^testing.T) {
	expect_no_subtype(t, "f :: proc(d: Derived) -> int {\n\treturn d.n\n}\n")
}

@(test)
subtype_refuses_a_promoted_selector_in_another_file :: proc(t: ^testing.T) {
	source := test.Source {
		main = subtype_source("using{*}", ""),
		files = {{name = "other.odin", source = "package test\nf :: proc(d: Derived) -> int {\n\treturn d.n\n}\n"}},
		config = {enable_code_action_expand_using = true},
	}
	test.expect_action_missing(t, &source, SUBTYPE)
}

@(test)
subtype_refuses_a_promoted_name_under_a_using_statement :: proc(t: ^testing.T) {
	expect_no_subtype(t, "f :: proc(d: Derived) -> int {\n\tusing d\n\treturn n\n}\n")
}

@(test)
subtype_refuses_a_promoted_key :: proc(t: ^testing.T) {
	expect_no_subtype(t, "f :: proc() -> Derived {\n\treturn Derived{n = 1}\n}\n")
}

@(test)
subtype_refuses_a_second_subtype_field :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\nA :: struct {\n\ta: int,\n}\nB :: struct {\n\tb: int,\n}\nD :: struct {\n\t#subtype a: A,\n\tusing{*} b: B,\n}\n",
		config = {enable_code_action_expand_using = true},
	}
	test.expect_action_missing(t, &source, SUBTYPE)
}

@(test)
subtype_refuses_a_blank_field_and_a_non_struct :: proc(t: ^testing.T) {
	blank := test.Source {
		main = "package test\nB :: struct {\n\tb: int,\n}\nD :: struct {\n\tusing{*} _: B,\n}\n",
		config = {enable_code_action_expand_using = true},
	}
	test.expect_action_missing(t, &blank, SUBTYPE)
	array := test.Source {
		main = "package test\nD :: struct {\n\tusing{*} v: [3]f32,\n}\n",
		config = {enable_code_action_expand_using = true},
	}
	test.expect_action_missing(t, &array, SUBTYPE)
}

@(test)
subtype_refuses_an_embedded_type_with_its_own_using :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\nA :: struct {\n\ta: int,\n}\nB :: struct {\n\tusing a: A,\n}\nD :: struct {\n\tusing{*} b: B,\n}\n",
		config = {enable_code_action_expand_using = true},
	}
	test.expect_action_missing(t, &source, SUBTYPE)
}
