#+feature dynamic-literals
package tests

import "core:strings"
import "core:testing"

import test "src:testing"

NAMED_FIELDS :: "Convert to named fields"
POSITIONAL_FIELDS :: "Convert to positional fields"
NAMED_ARGS :: "Convert to named arguments"
POSITIONAL_ARGS :: "Convert to positional arguments"

NAMED_PRELUDE :: `package test

P :: struct {
	x, y: int,
}

Base :: struct {
	n: int,
}

Derived :: struct {
	using base: Base,
	own:        int,
}

Blank :: struct {
	_: int,
	a: int,
}

Box :: struct($T: typeid) {
	v: T,
	n: int,
}

Vec :: [2]int

Un :: union {
	int,
}

two :: proc(a, b: int) -> int {return a + b}
defaults :: proc(a: int, b := 2, c := 3) -> int {return a + b + c}
unnamed: proc(_: int, _: int)
pair :: proc() -> (int, int) {return 1, 2}
one :: proc() -> int {return 1}
var :: proc(a: int, rest: ..int) {}
gi :: proc(a: int) -> int {return a}
gf :: proc(a: f32) -> f32 {return a}
grp :: proc {
	gi,
	gf,
}
gen :: proc(x: $T, y: T) -> T {return x}
kinds :: proc($T: typeid, x: T) -> T {return x}
blank_param :: proc(_: int, b: int) {}

`

named_source :: proc(body: string) -> string {
	return strings.concatenate({NAMED_PRELUDE, body}, context.temp_allocator)
}

expect_named :: proc(t: ^testing.T, title, body, expected: string) {
	source := test.Source {
		main = named_source(body),
		config = {enable_code_action_named_form = true},
	}
	test.expect_action_applied(t, &source, title, named_source(expected))
}

expect_no_named :: proc(t: ^testing.T, title, body: string) {
	source := test.Source {
		main = named_source(body),
		config = {enable_code_action_named_form = true},
	}
	test.expect_action_missing(t, &source, title)
}

@(test)
named_form_literal_both_ways :: proc(t: ^testing.T) {
	expect_named(
		t,
		NAMED_FIELDS,
		"main :: proc() {\n\tv := P{{*}1, 2}\n\t_ = v\n}\n",
		"main :: proc() {\n\tv := P{x = 1, y = 2}\n\t_ = v\n}\n",
	)
	expect_named(
		t,
		POSITIONAL_FIELDS,
		"main :: proc() {\n\tv := P{{*}x = 1, y = 2}\n\t_ = v\n}\n",
		"main :: proc() {\n\tv := P{1, 2}\n\t_ = v\n}\n",
	)
}

@(test)
named_form_literal_cursor_on_the_type_and_multi_line :: proc(t: ^testing.T) {
	expect_named(t, NAMED_FIELDS, "K := {*}P{\n\t1,\n\t2,\n}\n", "K := P{\n\tx = 1,\n\ty = 2,\n}\n")
}

@(test)
named_form_literal_without_a_type :: proc(t: ^testing.T) {
	expect_named(
		t,
		NAMED_FIELDS,
		"main :: proc() {\n\tv: P = {{*}1, 2}\n\t_ = v\n}\n",
		"main :: proc() {\n\tv: P = {x = 1, y = 2}\n\t_ = v\n}\n",
	)
	expect_named(
		t,
		NAMED_FIELDS,
		"main :: proc() {\n\tv := []P{{{*}1, 2}}\n\t_ = v\n}\n",
		"main :: proc() {\n\tv := []P{{x = 1, y = 2}}\n\t_ = v\n}\n",
	)
}

@(test)
named_form_literal_of_a_generic_struct :: proc(t: ^testing.T) {
	expect_named(
		t,
		NAMED_FIELDS,
		"main :: proc() {\n\tv := Box(int){{*}1, 2}\n\t_ = v\n}\n",
		"main :: proc() {\n\tv := Box(int){v = 1, n = 2}\n\t_ = v\n}\n",
	)
}

@(test)
named_form_literal_refuses_a_different_order :: proc(t: ^testing.T) {
	expect_no_named(t, POSITIONAL_FIELDS, "main :: proc() {\n\tv := P{{*}y = 1, x = 2}\n\t_ = v\n}\n")
}

@(test)
named_form_literal_refuses_a_missing_field :: proc(t: ^testing.T) {
	expect_no_named(t, POSITIONAL_FIELDS, "main :: proc() {\n\tv := P{{*}x = 1}\n\t_ = v\n}\n")
}

@(test)
named_form_literal_refuses_using_fields :: proc(t: ^testing.T) {
	expect_no_named(t, NAMED_FIELDS, "main :: proc() {\n\tv := Derived{{*}{1}, 2}\n\t_ = v\n}\n")
	expect_no_named(t, POSITIONAL_FIELDS, "main :: proc() {\n\tv := Derived{{*}base = {1}, own = 2}\n\t_ = v\n}\n")
}

@(test)
named_form_literal_refuses_non_structs_and_blank_fields :: proc(t: ^testing.T) {
	expect_no_named(t, NAMED_FIELDS, "main :: proc() {\n\tv := Vec{{*}1, 2}\n\t_ = v\n}\n")
	expect_no_named(t, NAMED_FIELDS, "main :: proc() {\n\tv := []int{{*}1, 2}\n\t_ = v\n}\n")
	expect_no_named(t, NAMED_FIELDS, "main :: proc() {\n\tv := Blank{{*}1, 2}\n\t_ = v\n}\n")
}

@(test)
named_form_literal_refuses_an_empty_literal :: proc(t: ^testing.T) {
	expect_no_named(t, NAMED_FIELDS, "main :: proc() {\n\tv := P{{*}}\n\t_ = v\n}\n")
	expect_no_named(t, POSITIONAL_FIELDS, "main :: proc() {\n\tv := P{{*}}\n\t_ = v\n}\n")
}

@(test)
named_form_call_both_ways :: proc(t: ^testing.T) {
	expect_named(
		t,
		NAMED_ARGS,
		"main :: proc() {\n\t_ = t{*}wo(1, 2)\n}\n",
		"main :: proc() {\n\t_ = two(a = 1, b = 2)\n}\n",
	)
	expect_named(
		t,
		POSITIONAL_ARGS,
		"main :: proc() {\n\t_ = t{*}wo(a = 1, b = 2)\n}\n",
		"main :: proc() {\n\t_ = two(1, 2)\n}\n",
	)
}

@(test)
named_form_call_with_defaults_left_out :: proc(t: ^testing.T) {
	expect_named(
		t,
		NAMED_ARGS,
		"main :: proc() {\n\t_ = defaults({*}1, 5)\n}\n",
		"main :: proc() {\n\t_ = defaults(a = 1, b = 5)\n}\n",
	)
	expect_named(
		t,
		NAMED_ARGS,
		"main :: proc() {\n\t_ = defaults({*}1, b = 5)\n}\n",
		"main :: proc() {\n\t_ = defaults(a = 1, b = 5)\n}\n",
	)
	expect_named(
		t,
		POSITIONAL_ARGS,
		"main :: proc() {\n\t_ = defaults({*}1, b = 5)\n}\n",
		"main :: proc() {\n\t_ = defaults(1, 5)\n}\n",
	)
}

@(test)
named_form_call_innermost_at_the_cursor :: proc(t: ^testing.T) {
	expect_named(
		t,
		NAMED_ARGS,
		"main :: proc() {\n\t_ = two(two({*}1, 2), 3)\n}\n",
		"main :: proc() {\n\t_ = two(two(a = 1, b = 2), 3)\n}\n",
	)
}

@(test)
named_form_call_of_a_generic_procedure :: proc(t: ^testing.T) {
	expect_named(
		t,
		NAMED_ARGS,
		"main :: proc() {\n\t_ = g{*}en(1, 2)\n}\n",
		"main :: proc() {\n\t_ = gen(x = 1, y = 2)\n}\n",
	)
}

@(test)
named_form_call_refuses_a_skipped_parameter :: proc(t: ^testing.T) {
	expect_no_named(t, POSITIONAL_ARGS, "main :: proc() {\n\t_ = defaults({*}a = 1, c = 2)\n}\n")
}

@(test)
named_form_call_refuses_a_different_order :: proc(t: ^testing.T) {
	expect_no_named(t, POSITIONAL_ARGS, "main :: proc() {\n\t_ = two({*}b = 1, a = 2)\n}\n")
}

@(test)
named_form_call_refuses_a_group :: proc(t: ^testing.T) {
	expect_no_named(t, NAMED_ARGS, "main :: proc() {\n\t_ = grp({*}1)\n}\n")
	expect_no_named(t, POSITIONAL_ARGS, "main :: proc() {\n\t_ = grp({*}a = 1)\n}\n")
}

@(test)
named_form_call_refuses_varargs :: proc(t: ^testing.T) {
	expect_no_named(t, NAMED_ARGS, "main :: proc() {\n\tvar({*}1, 2, 3)\n}\n")
}

@(test)
named_form_call_refuses_a_spread :: proc(t: ^testing.T) {
	expect_no_named(t, NAMED_ARGS, "main :: proc() {\n\txs := []int{1}\n\tvar({*}1, ..xs)\n}\n")
}

@(test)
named_form_call_refuses_results_spread_over_parameters :: proc(t: ^testing.T) {
	expect_no_named(t, NAMED_ARGS, "main :: proc() {\n\t_ = t{*}wo(pair())\n}\n")
	expect_named(
		t,
		NAMED_ARGS,
		"main :: proc() {\n\t_ = d{*}efaults(one())\n}\n",
		"main :: proc() {\n\t_ = defaults(a = one())\n}\n",
	)
}

@(test)
named_form_call_refuses_builtins_and_conversions :: proc(t: ^testing.T) {
	expect_no_named(t, NAMED_ARGS, "main :: proc() {\n\txs := []int{1}\n\t_ = len({*}xs)\n}\n")
	expect_no_named(t, NAMED_ARGS, "main :: proc() {\n\t_ = int({*}1.5)\n}\n")
}

@(test)
named_form_call_refuses_unnamed_blank_and_compile_time_parameters :: proc(t: ^testing.T) {
	expect_no_named(t, NAMED_ARGS, "main :: proc() {\n\tp: proc(int, int)\n\tp({*}1, 2)\n}\n")
	expect_no_named(t, NAMED_ARGS, "main :: proc() {\n\tblank_param({*}1, 2)\n}\n")
	expect_no_named(t, NAMED_ARGS, "main :: proc() {\n\t_ = kinds({*}int, 2)\n}\n")
}

@(test)
named_form_call_refuses_an_arrow_call :: proc(t: ^testing.T) {
	expect_no_named(
		t,
		NAMED_ARGS,
		"V :: struct {\n\tfn: proc(self: ^V, n: int) -> int,\n}\nmain :: proc() {\n\tv: V\n\t_ = v->fn({*}1)\n}\n",
	)
}

@(test)
named_form_call_in_another_package :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\nimport \"core:other\"\nmain :: proc() {\n\t_ = other.add({*}1, 2)\n}\n",
		packages = {{pkg = "other", source = "package other\nadd :: proc(a, b: int) -> int {return a + b}\n"}},
		collections = {"core" = "test"},
		config = {enable_code_action_named_form = true},
	}
	test.expect_action_applied(
		t,
		&source,
		NAMED_ARGS,
		"package test\nimport \"core:other\"\nmain :: proc() {\n\t_ = other.add(a = 1, b = 2)\n}\n",
	)
}

@(test)
named_form_off_with_its_flag :: proc(t: ^testing.T) {
	source := test.Source {
		main = named_source("main :: proc() {\n\t_ = t{*}wo(1, 2)\n}\n"),
		config = {enable_code_action_named_form = false},
	}
	test.expect_action_missing(t, &source, NAMED_ARGS)
	lit := test.Source {
		main = named_source("main :: proc() {\n\tv := P{{*}1, 2}\n\t_ = v\n}\n"),
		config = {enable_code_action_named_form = false},
	}
	test.expect_action_missing(t, &lit, NAMED_FIELDS)
}
