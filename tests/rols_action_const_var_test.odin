package tests

import "core:testing"

import test "src:testing"

@(private = "file")
expect_applied :: proc(t: ^testing.T, title, main, expected: string) {
	source := test.Source {
		main = main,
		config = {enable_code_action_const_var = true},
	}
	test.expect_action_applied(t, &source, title, expected)
}

@(private = "file")
expect_missing :: proc(t: ^testing.T, title, main: string) {
	source := test.Source {
		main = main,
		config = {enable_code_action_const_var = true},
	}
	test.expect_action_missing(t, &source, title)
}

@(test)
const_var_declaration :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Convert to constant",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} := 1
	y := x
	_ = y
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x :: 1
	y := x
	_ = y
}
`,
	)
}

@(test)
const_var_declaration_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Convert to variable",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} :: 1
	y := x
	_ = y
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x := 1
	y := x
	_ = y
}
`,
	)
}

@(test)
const_var_comparison :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Convert to constant",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} := 1
	if x > 0 {
	}
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x :: 1
	if x > 0 {
	}
}
`,
	)
}

@(test)
const_var_comparison_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Convert to variable",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} :: 1
	if x > 0 {
	}
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x := 1
	if x > 0 {
	}
}
`,
	)
}

@(test)
const_var_string_argument :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Convert to constant",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} := "a"
	use(x)
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x :: "a"
	use(x)
}
`,
	)
}

@(test)
const_var_string_argument_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Convert to variable",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} :: "a"
	use(x)
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x := "a"
	use(x)
}
`,
	)
}

@(test)
const_var_typed_value :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Convert to constant",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} := f32(1)
	y: f32 = x
	_ = y
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x :: f32(1)
	y: f32 = x
	_ = y
}
`,
	)
}

@(test)
const_var_typed_value_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Convert to variable",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} :: f32(1)
	y: f32 = x
	_ = y
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x := f32(1)
	y: f32 = x
	_ = y
}
`,
	)
}

@(test)
const_var_bool :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Convert to constant",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} := true
	if !x {
	}
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x :: true
	if !x {
	}
}
`,
	)
}

@(test)
const_var_bool_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Convert to variable",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} :: true
	if !x {
	}
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x := true
	if !x {
	}
}
`,
	)
}

@(test)
const_var_variable_arithmetic_and_index :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Convert to variable",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} :: 2
	a: [4]int
	y := a[x]
	z := x * 2 + 1
	_, _ = y, z
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x := 2
	a: [4]int
	y := a[x]
	z := x * 2 + 1
	_, _ = y, z
}
`,
	)
}

@(test)
const_var_constant_from_a_global_constant :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Convert to constant",
		`package test

MAX :: 5

main :: proc() {
	x{*} := MAX
	y := x
	_ = y
}
`,
		`package test

MAX :: 5

main :: proc() {
	x :: MAX
	y := x
	_ = y
}
`,
	)
}

@(test)
const_var_variable_ignores_a_shadow :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Convert to variable",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} :: 2
	y := x
	{
		x: [3]f32
		_ = x
	}
	_ = y
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x := 2
	y := x
	{
		x: [3]f32
		_ = x
	}
	_ = y
}
`,
	)
}

@(test)
const_var_constant_refuses_a_write :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to constant",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} := 1
	x = 2
}
`,
	)
}

@(test)
const_var_constant_refuses_a_compound_write :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to constant",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} := 1
	x += 2
}
`,
	)
}

@(test)
const_var_constant_refuses_an_address :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to constant",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} := 1
	p := &x
	_ = p
}
`,
	)
}

@(test)
const_var_constant_refuses_a_call :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to constant",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} := g()
	y := x
	_ = y
}
`,
	)
}

@(test)
const_var_constant_refuses_a_local :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to constant",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	n := 1
	x{*} := n
	y := x
	_ = y
}
`,
	)
}

@(test)
const_var_constant_refuses_a_type_change :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to constant",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} := 3
	y := 2.0 * x
	_ = y
}
`,
	)
}

@(test)
const_var_constant_refuses_a_conversion :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to constant",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} := 300
	y := u8(x)
	_ = y
}
`,
	)
}

@(test)
const_var_constant_refuses_a_division :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to constant",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} := 0
	y := 10 / x
	_ = y
}
`,
	)
}

@(test)
const_var_constant_refuses_an_earlier_use_of_the_name :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to constant",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x := 1
	{
		y := x
		x{*} := 2
		z := x
		_, _ = y, z
	}
	_ = x
}
`,
	)
}

@(test)
const_var_constant_refuses_a_typed_declaration :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to constant",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*}: int = 1
	y := x
	_ = y
}
`,
	)
}

@(test)
const_var_constant_refuses_a_static :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to constant",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	@(static) x{*} := 1
	y := x
	_ = y
}
`,
	)
}

@(test)
const_var_constant_refuses_several_names :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to constant",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*}, z := 1, 2
	_, _ = x, z
}
`,
	)
}

@(test)
const_var_constant_refuses_a_literal :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to constant",
		`package test

Foo :: struct {
	a: int,
}

main :: proc() {
	x{*} := Foo{1}
	y := x
	_ = y
}
`,
	)
}

@(test)
const_var_variable_refuses_a_type :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to variable",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	T{*} :: int
	y: T
	_ = y
}
`,
	)
}

@(test)
const_var_variable_refuses_a_struct :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to variable",
		`package test

main :: proc() {
	T{*} :: struct {
		a: int,
	}
	y: T
	_ = y
}
`,
	)
}

@(test)
const_var_variable_refuses_a_procedure :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to variable",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	h{*} :: proc() {
	}
	h()
}
`,
	)
}

@(test)
const_var_variable_refuses_a_procedure_name :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to variable",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	h{*} :: g
	y := h()
	_ = y
}
`,
	)
}

@(test)
const_var_variable_refuses_an_array_length :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to variable",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} :: 3
	a: [x]int
	_ = a
}
`,
	)
}

@(test)
const_var_variable_refuses_a_length_expression :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to variable",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} :: 3
	a: [x + 1]int
	_ = a
}
`,
	)
}

@(test)
const_var_variable_refuses_a_when :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to variable",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} :: 3
	when x > 1 {
	}
}
`,
	)
}

@(test)
const_var_variable_refuses_a_constant_declaration :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to variable",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} :: 3
	y :: x + 1
	_ = y
}
`,
	)
}

@(test)
const_var_variable_refuses_an_assert :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to variable",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} :: 3
	#assert(x > 1)
}
`,
	)
}

@(test)
const_var_variable_refuses_a_nested_procedure :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to variable",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} :: 3
	h :: proc() -> int {
		return x
	}
	_ = h
}
`,
	)
}

@(test)
const_var_variable_refuses_an_implicit_conversion :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to variable",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} :: 3
	y: f32 = x
	_ = y
}
`,
	)
}

@(test)
const_var_variable_refuses_a_typed_operand :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to variable",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} :: 3
	z: f32 = 1
	y := z * x
	_ = y
}
`,
	)
}

@(test)
const_var_variable_refuses_a_parameter_of_another_type :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to variable",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} :: 3
	use_f32(x)
}
`,
	)
}

@(test)
const_var_variable_refuses_a_constant_parameter :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to variable",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} :: 3
	use_const(x)
}
`,
	)
}

@(test)
const_var_variable_refuses_a_use_above :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to variable",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	y := x
	x{*} :: 3
	_ = y
}
`,
	)
}

@(test)
const_var_variable_refuses_float_arithmetic :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to variable",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} :: 0.1
	y := x * 3.0
	_ = y
}
`,
	)
}

@(test)
const_var_variable_refuses_no_use :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Convert to variable",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}
use :: proc(s: string) {
}
use_f32 :: proc(v: f32) {
}
use_const :: proc($N: int) {
}

main :: proc() {
	x{*} :: 3
}
`,
	)
}

@(test)
const_var_variable_refuses_a_package_constant :: proc(t: ^testing.T) {
	expect_missing(t, "Convert to variable", `package test

X{*} :: 3

main :: proc() {
	y := X
	_ = y
}
`)
}

@(test)
const_var_constant_needs_its_flag :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*} := 1
	y := x
	_ = y
}
`,
	}
	test.expect_action_missing(t, &source, "Convert to constant")
}

@(test)
const_var_variable_needs_its_flag :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*} :: 1
	y := x
	_ = y
}
`,
	}
	test.expect_action_missing(t, &source, "Convert to variable")
}

@(test)
const_var_one_character_range_matches_the_cursor :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Convert to constant",
		`package test

main :: proc() {
	{[x]} := 1
	y := x
	_ = y
}
`,
		`package test

main :: proc() {
	x :: 1
	y := x
	_ = y
}
`,
	)
}

@(test)
const_var_variable_compares_with_a_local_of_its_type :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Convert to variable",
		`package test

main :: proc() {
	x{*} :: 2
	n := 3
	if n > x {
	}
}
`,
		`package test

main :: proc() {
	x := 2
	n := 3
	if n > x {
	}
}
`,
	)
}

@(test)
const_var_variable_from_size_of :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Convert to variable",
		`package test

main :: proc() {
	x{*} :: size_of(int)
	y: int = x
	_ = y
}
`,
		`package test

main :: proc() {
	x := size_of(int)
	y: int = x
	_ = y
}
`,
	)
}
