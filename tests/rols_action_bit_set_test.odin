package tests

import "core:strings"
import "core:testing"

import test "src:testing"

TO_INTERSECTION :: "Convert to set intersection"
TO_EMPTY :: "Convert to empty intersection"
TO_IN :: "Convert to in"
TO_NOT_IN :: "Convert to not_in"

BIT_SET_PRELUDE :: `package test

Kind :: enum {
	A,
	B,
}

Set :: bit_set[Kind]

`

// body with `{*}` for the cursor, in a procedure with a local fl and a local a.
bit_set_source :: proc(body: string) -> string {
	return strings.concatenate(
		{BIT_SET_PRELUDE, "main :: proc() {\n\tfl: Set\n\ta: bool\n\t", body, "\n\t_ = a\n}\n"},
		context.temp_allocator,
	)
}

expect_bit_set :: proc(t: ^testing.T, title, body, expected: string) {
	source := test.Source {
		main = bit_set_source(body),
		config = {enable_code_action_bit_set = true},
	}
	test.expect_action_applied(t, &source, title, bit_set_source(expected))
}

expect_no_bit_set :: proc(t: ^testing.T, title, body: string) {
	source := test.Source {
		main = bit_set_source(body),
		config = {enable_code_action_bit_set = true},
	}
	test.expect_action_missing(t, &source, title)
}

@(test)
bit_set_in_both_ways :: proc(t: ^testing.T) {
	expect_bit_set(t, TO_INTERSECTION, "a = .A {*}in fl", "a = fl & {.A} != {}")
	expect_bit_set(t, TO_IN, "a = fl {*}& {.A} != {}", "a = .A in fl")
}

@(test)
bit_set_not_in_both_ways :: proc(t: ^testing.T) {
	expect_bit_set(t, TO_EMPTY, "a = .A {*}not_in fl", "a = fl & {.A} == {}")
	expect_bit_set(t, TO_NOT_IN, "a = fl & {{*}.A} == {}", "a = .A not_in fl")
}

@(test)
bit_set_in_an_if_header :: proc(t: ^testing.T) {
	expect_bit_set(t, TO_INTERSECTION, "if .A {*}in fl {\n\t}", "if fl & {.A} != {} {\n\t}")
	expect_bit_set(t, TO_IN, "if fl & {.A} {*}!= {} {\n\t}", "if .A in fl {\n\t}")
}

@(test)
bit_set_keeps_a_qualified_member :: proc(t: ^testing.T) {
	expect_bit_set(t, TO_INTERSECTION, "a = Kind.A {*}in fl", "a = fl & {Kind.A} != {}")
	expect_bit_set(t, TO_IN, "a = fl {*}& {Kind.A} != {}", "a = Kind.A in fl")
}

@(test)
bit_set_wraps_under_a_comparison :: proc(t: ^testing.T) {
	expect_bit_set(t, TO_INTERSECTION, "a = a == .A {*}in fl", "a = a == (fl & {.A} != {})")
	expect_bit_set(t, TO_INTERSECTION, "a = a && .A {*}in fl", "a = a && fl & {.A} != {}")
}

@(test)
bit_set_refuses :: proc(t: ^testing.T) {
	// A value that holds a member is not a constant, which a bit set literal needs.
	expect_no_bit_set(t, TO_INTERSECTION, "x := Kind.A\n\ta = x {*}in fl")
	// A map is no bit set.
	expect_no_bit_set(t, TO_INTERSECTION, "m: map[Kind]int\n\ta = .A {*}in m")
	expect_no_bit_set(t, TO_INTERSECTION, "p := &fl\n\ta = .A {*}in p")
	// More than one member.
	expect_no_bit_set(t, TO_IN, "a = fl {*}& {.A, .B} != {}")
	expect_no_bit_set(t, TO_IN, "a = fl {*}& {} != {}")
	expect_no_bit_set(t, TO_IN, "a = fl {*}& {.A} != {.B}")
	expect_no_bit_set(t, TO_IN, "other: Set\n\ta = fl {*}& other != {}")
	// Another operator, a member that is no constant, and a left side that is no bit set.
	expect_no_bit_set(t, TO_IN, "a = fl {*}| {.A} != {}")
	expect_no_bit_set(t, TO_IN, "x := Kind.A\n\ta = fl {*}& {x} != {}")
	expect_no_bit_set(t, TO_IN, "n: int\n\ta = n {*}& {.A} != {}")
	// A value of the enum, and a name that is no member.
	expect_no_bit_set(t, TO_INTERSECTION, "x := Kind.A\n\ta = x.A {*}in fl")
	expect_no_bit_set(t, TO_INTERSECTION, "a = Kind.Z {*}in fl")
	// A selection that reaches past the expression.
	expect_no_bit_set(t, TO_INTERSECTION, "a = {[.A in fl && a]}")
	// `in` does not parse in the header of a `for`, and makes a type switch of a `switch`.
	expect_no_bit_set(t, TO_IN, "for fl {*}& {.A} != {} {\n\t}")
	expect_no_bit_set(t, TO_IN, "for i := 0; fl {*}& {.A} != {}; {\n\t\t_ = i\n\t}")
	expect_no_bit_set(t, TO_IN, "switch fl {*}& {.A} != {} {\n\t}")
}

@(test)
bit_set_off_with_its_flag :: proc(t: ^testing.T) {
	cases := [][2]string {
		{TO_INTERSECTION, "a = .A {*}in fl"},
		{TO_EMPTY, "a = .A {*}not_in fl"},
		{TO_IN, "a = fl {*}& {.A} != {}"},
		{TO_NOT_IN, "a = fl {*}& {.A} == {}"},
	}
	for item in cases {
		source := test.Source {
			main = bit_set_source(item[1]),
			config = {enable_code_action_bit_set = false},
		}
		test.expect_action_missing(t, &source, item[0])
	}
}
