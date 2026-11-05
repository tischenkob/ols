package tests

import "core:strings"
import "core:testing"

import test "src:testing"

EVALUATE :: "Evaluate constant"

expect_evaluate :: proc(t: ^testing.T, main, expected: string) {
	source := test.Source {
		main = main,
		config = {enable_code_action_evaluate = true},
	}
	test.expect_action_applied(t, &source, EVALUATE, expected)
}

expect_no_evaluate :: proc(t: ^testing.T, main: string) {
	source := test.Source {
		main = main,
		config = {enable_code_action_evaluate = true},
	}
	test.expect_action_missing(t, &source, EVALUATE)
}

@(test)
evaluate_takes_the_largest_constant_expression :: proc(t: ^testing.T) {
	expect_evaluate(t, "package test\nK :: 1 + {*}2 * (3 << 2)\n", "package test\nK :: 25\n")
}

@(test)
evaluate_keeps_the_rest_of_an_expression :: proc(t: ^testing.T) {
	expect_evaluate(
		t,
		"package test\nf :: proc(x: int) -> int {\n\treturn x + (1{*} + 2)\n}\n",
		"package test\nf :: proc(x: int) -> int {\n\treturn x + 3\n}\n",
	)
}

@(test)
evaluate_every_operator :: proc(t: ^testing.T) {
	cases := [][2]string {
		{"7 {*}/ 2", "3"},
		{"-7 {*}/ 2", "-3"},
		{"-7 {*}% 2", "-1"},
		{"-8 {*}>> 1", "-4"},
		{"6 {*}& 3", "2"},
		{"6 {*}| 1", "7"},
		{"0x10 {*}| 0b1", "17"},
		{"1_000 {*}+ 0o7", "1007"},
		{"5 {*}- 2", "3"},
		{"+1 {*}+ 2", "3"},
		{"1 {*}<< 62", "4611686018427387904"},
	}
	for item in cases {
		main := strings.concatenate({"package test\nK :: ", item[0], "\n"}, context.temp_allocator)
		expected := strings.concatenate({"package test\nK :: ", item[1], "\n"}, context.temp_allocator)
		expect_evaluate(t, main, expected)
	}
}

@(test)
evaluate_wraps_a_negative_value_after_an_operator :: proc(t: ^testing.T) {
	expect_evaluate(
		t,
		"package test\nf :: proc(x: int) -> int {\n\treturn x - (1{*} - 2)\n}\n",
		"package test\nf :: proc(x: int) -> int {\n\treturn x - (-1)\n}\n",
	)
}

// The whole expression is outside i64, so the action takes the largest part inside it.
@(test)
evaluate_refuses_to_negate_the_lowest_i64 :: proc(t: ^testing.T) {
	expect_evaluate(
		t,
		"package test\nK :: -({*}-9223372036854775807 - 1)\n",
		"package test\nK :: -(-9223372036854775808)\n",
	)
}

@(test)
evaluate_refuses :: proc(t: ^testing.T) {
	cases := []string {
		"package test\nK :: 1.5 {*}+ 2\n", // a float
		"package test\nN :: 1\nK :: N {*}+ 2\n", // a name
		"package test\nK :: 1 {*}/ 0\n", // a zero divisor
		"package test\nK :: 1 {*}% 0\n",
		"package test\nK :: 1 {*}<< 63\n", // outside i64
		"package test\nK :: 9223372036854775807 {*}+ 1\n",
		"package test\nK :: 9223372036854775808 {*}- 1\n",
		"package test\nK :: 1 {*}<< 64\n",
		"package test\nK :: {*}5\n", // a plain literal
		"package test\nK :: {*}-5\n",
		"package test\nK :: ({*}5)\n",
		"package test\nK :: 'a' {*}+ 1\n", // a rune
		"package test\nK :: 5 {*}%% 2\n", // an operator outside the list
		"package test\nK :: ~1 {*}+ 2\n",
		"package test\nK :: (-9223372036854775807 - 1) {*}/ -1\n", // the quotient and remainder of the lowest i64
		"package test\nK :: (-9223372036854775807 - 1) {*}% -1\n",
		"package test\nK :: 0 {*}<< -1\n", // a negative shift
		"package test\nK :: 8 {*}>> -1\n",
		"package test\nK :: 0b12 {*}+ 1\n", // a digit outside the base
		"package test\nK :: 18446744073709551617 {*}+ 1\n", // a literal outside i64 that would wrap
		"package test\nN :: 1\nK :: {[1 + 2 + N]}\n", // a selection that reaches past the constant
	}
	for main in cases {
		expect_no_evaluate(t, main)
	}
}

@(test)
evaluate_off_with_its_flag :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\nK :: 1 {*}+ 2\n",
		config = {enable_code_action_evaluate = false},
	}
	test.expect_action_missing(t, &source, EVALUATE)
}
