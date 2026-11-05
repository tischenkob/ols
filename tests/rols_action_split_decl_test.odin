package tests

import "core:fmt"
import "core:testing"

import test "src:testing"

@(private = "file")
expect_applied :: proc(t: ^testing.T, title, main, expected: string) {
	source := test.Source {
		main = main,
		config = {enable_code_action_split_decl = true},
	}
	test.expect_action_applied(t, &source, title, expected)
}

@(private = "file")
expect_missing :: proc(t: ^testing.T, title, main: string) {
	source := test.Source {
		main = main,
		config = {enable_code_action_split_decl = true},
	}
	test.expect_action_missing(t, &source, title)
}

@(test)
split_decl_typed :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Split declaration",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*}: int = g()
	_ = x
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x: int
	x = g()
	_ = x
}
`,
	)
}

@(test)
split_decl_typed_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Join declaration",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*}: int
	x = g()
	_ = x
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x: int = g()
	_ = x
}
`,
	)
}

@(test)
split_decl_inferred_call :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Split declaration",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*} := g()
	_ = x
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x: int
	x = g()
	_ = x
}
`,
	)
}

@(test)
split_decl_inferred_call_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Join declaration with inferred type",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*}: int
	x = g()
	_ = x
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x := g()
	_ = x
}
`,
	)
}

@(test)
split_decl_inferred_literal :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Split declaration",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*} := 1
	_ = x
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x: int
	x = 1
	_ = x
}
`,
	)
}

@(test)
split_decl_inferred_literal_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Join declaration with inferred type",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*}: int
	x = 1
	_ = x
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x := 1
	_ = x
}
`,
	)
}

@(test)
split_decl_join_from_the_assignment :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Join declaration",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x: int
	x{*} = g()
	_ = x
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x: int = g()
	_ = x
}
`,
	)
}

@(test)
split_decl_keeps_a_trailing_comment :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Split declaration",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*}: int = g() // why
	_ = x
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x: int
	x = g() // why
	_ = x
}
`,
	)
}

@(test)
split_decl_keeps_indentation_in_a_block :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Split declaration",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	{
		x{*}: int = g()
		_ = x
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

main :: proc() {
	{
		x: int
		x = g()
		_ = x
	}
}
`,
	)
}

@(test)
split_decl_separate :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Split into separate declarations",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	a{*}, b := 1, 2
	_, _ = a, b
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	a := 1
	b := 2
	_, _ = a, b
}
`,
	)
}

@(test)
split_decl_separate_typed :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Split into separate declarations",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	a{*}, b: int = 1, 2
	_, _ = a, b
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	a: int = 1
	b: int = 2
	_, _ = a, b
}
`,
	)
}

@(test)
split_decl_separate_keeps_a_call_next_to_constants :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Split into separate declarations",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	a{*}, b := g(), 2
	_, _ = a, b
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	a := g()
	b := 2
	_, _ = a, b
}
`,
	)
}

@(test)
split_decl_separate_keeps_a_later_outer_name :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Split into separate declarations",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	b := 1
	{
		a{*}, b := b, 2
		_, _ = a, b
	}
	_ = b
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	b := 1
	{
		a := b
		b := 2
		_, _ = a, b
	}
	_ = b
}
`,
	)
}

@(test)
split_decl_separate_keeps_a_field_named_like_an_earlier_name :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Split into separate declarations",
		`package test

Foo :: struct {
	a: int,
}

main :: proc() {
	a{*}, b := 1, Foo{a = 1}
	_, _ = a, b
}
`,
		`package test

Foo :: struct {
	a: int,
}

main :: proc() {
	a := 1
	b := Foo{a = 1}
	_, _ = a, b
}
`,
	)
}

@(test)
split_decl_split_refuses_a_shadow_of_an_outer_name :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split declaration",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x := 1
	{
		x{*} := x + 1
		_ = x
	}
	_ = x
}
`,
	)
}

@(test)
split_decl_split_refuses_undefined :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split declaration",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*}: int = ---
	_ = x
}
`,
	)
}

@(test)
split_decl_split_refuses_a_static :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split declaration",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	@(static) x{*}: int = 1
	_ = x
}
`,
	)
}

@(test)
split_decl_split_refuses_a_constant :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split declaration",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*} :: 1
	_ = x
}
`,
	)
}

@(test)
split_decl_split_refuses_a_type_without_a_name :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split declaration",
		`package test

main :: proc() {
	x{*} := struct {
		a: int,
	}{1}
	_ = x
}
`,
	)
}

@(test)
split_decl_split_refuses_an_init_header :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split declaration",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	if x{*} := g(); x > 0 {
	}
}
`,
	)
}

@(test)
split_decl_split_refuses_a_second_statement_on_the_line :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split declaration",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*} := g(); y := 1
	_, _ = x, y
}
`,
	)
}

@(test)
split_decl_split_refuses_a_do_body :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split declaration",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	b := true
	if b do x{*} := g()
}
`,
	)
}

@(test)
split_decl_split_refuses_a_cursor_on_another_statement :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split declaration",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x := g()
	_ = x{*}
}
`,
	)
}

@(test)
split_decl_join_refuses_a_statement_between :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Join declaration",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*}: int
	g()
	x = g()
	_ = x
}
`,
	)
}

@(test)
split_decl_join_refuses_a_value_that_reads_the_name :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Join declaration",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*}: int
	x = x + 1
	_ = x
}
`,
	)
}

@(test)
split_decl_join_refuses_another_name :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Join declaration",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*}: int
	y: int
	y = g()
	_, _ = x, y
}
`,
	)
}

@(test)
split_decl_join_refuses_a_compound_assignment :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Join declaration",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*}: int
	x += 1
	_ = x
}
`,
	)
}

@(test)
split_decl_join_refuses_a_comment_between :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Join declaration",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*}: int
	// why
	x = 1
	_ = x
}
`,
	)
}

@(test)
split_decl_join_refuses_a_static :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Join declaration",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	@(static) x{*}: int
	x = 1
	_ = x
}
`,
	)
}

@(test)
split_decl_join_inferred_refuses_another_type :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Join declaration with inferred type",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*}: f32
	x = 1
	_ = x
}
`,
	)
}

@(test)
split_decl_join_inferred_refuses_an_unnamed_value :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Join declaration with inferred type",
		`package test

E :: enum {
	A,
}

main :: proc() {
	x{*}: E
	x = .A
	_ = x
}
`,
	)
}

@(test)
split_decl_separate_refuses_a_multi_result_call :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split into separate declarations",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	a{*}, b := f()
	_, _ = a, b
}
`,
	)
}

@(test)
split_decl_separate_refuses_an_earlier_name :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split into separate declarations",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	a := 1
	{
		a{*}, b := 2, a
		_, _ = a, b
	}
	_ = a
}
`,
	)
}

@(test)
split_decl_separate_refuses_a_call_next_to_a_call :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split into separate declarations",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	a{*}, b := g(), g()
	_, _ = a, b
}
`,
	)
}

@(test)
split_decl_separate_refuses_a_call_next_to_a_variable :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split into separate declarations",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	n := 1
	a{*}, b := n, g()
	_, _ = a, b
}
`,
	)
}

@(test)
split_decl_separate_refuses_a_blank :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split into separate declarations",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	_{*}, b := 1, 2
	_ = b
}
`,
	)
}

@(test)
split_decl_separate_refuses_a_type_spelled_twice :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split into separate declarations",
		`package test

main :: proc() {
	a{*}, b: distinct int = 1, 2
	_, _ = a, b
}
`,
	)
}

@(test)
split_decl_separate_refuses_a_comment_inside :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split into separate declarations",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	a{*}, b := 1, /* why */ 2
	_, _ = a, b
}
`,
	)
}

@(test)
split_decl_separate_refuses_constants :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split into separate declarations",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	a{*}, b :: 1, 2
	_, _ = a, b
}
`,
	)
}

@(test)
split_decl_separate_refuses_a_static :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split into separate declarations",
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	@(static) a{*}, b := 1, 2
	_, _ = a, b
}
`,
	)
}

@(test)
split_decl_split_needs_its_flag :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*}: int = g()
	_ = x
}
`,
	}
	test.expect_action_missing(t, &source, "Split declaration")
}

@(test)
split_decl_join_needs_its_flag :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*}: int
	x = g()
	_ = x
}
`,
	}
	test.expect_action_missing(t, &source, "Join declaration")
}

@(test)
split_decl_join_inferred_needs_its_flag :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*}: int
	x = g()
	_ = x
}
`,
	}
	test.expect_action_missing(t, &source, "Join declaration with inferred type")
}

@(test)
split_decl_separate_needs_its_flag :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() -> (int, bool) {
	return 1, true
}
g :: proc() -> int {
	return 1
}

main :: proc() {
	a{*}, b := 1, 2
	_, _ = a, b
}
`,
	}
	test.expect_action_missing(t, &source, "Split into separate declarations")
}

@(test)
split_decl_split_refuses_a_procedure_name :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split declaration",
		`package test

g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*} := g
	_ = x
}
`,
	)
}

@(test)
split_decl_split_refuses_a_type_name :: proc(t: ^testing.T) {
	expect_missing(t, "Split declaration", `package test

main :: proc() {
	x{*} := int
	_ = x
}
`)
}

@(test)
split_decl_split_keeps_a_constant_name :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Split declaration",
		`package test

MAX :: 5

main :: proc() {
	x{*} := MAX
	_ = x
}
`,
		`package test

MAX :: 5

main :: proc() {
	x: int
	x = MAX
	_ = x
}
`,
	)
}

@(test)
split_decl_inferred_named_constant :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Split declaration",
		`package test

MAX :: 5

main :: proc() {
	x{*} := MAX
	_ = x
}
`,
		`package test

MAX :: 5

main :: proc() {
	x: int
	x = MAX
	_ = x
}
`,
	)
}

@(test)
split_decl_inferred_named_constant_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Join declaration with inferred type",
		`package test

MAX :: 5

main :: proc() {
	x{*}: int
	x = MAX
	_ = x
}
`,
		`package test

MAX :: 5

main :: proc() {
	x := MAX
	_ = x
}
`,
	)
}

@(test)
split_decl_inferred_arithmetic_on_a_named_constant :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Split declaration",
		`package test

MAX :: 5

main :: proc() {
	x{*} := MAX + 1
	_ = x
}
`,
		`package test

MAX :: 5

main :: proc() {
	x: int
	x = MAX + 1
	_ = x
}
`,
	)
}

@(test)
split_decl_inferred_arithmetic_on_a_named_constant_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Join declaration with inferred type",
		`package test

MAX :: 5

main :: proc() {
	x{*}: int
	x = MAX + 1
	_ = x
}
`,
		`package test

MAX :: 5

main :: proc() {
	x := MAX + 1
	_ = x
}
`,
	)
}

@(test)
split_decl_inferred_comparison_of_a_call :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Split declaration",
		`package test

g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*} := g() > 0
	_ = x
}
`,
		`package test

g :: proc() -> int {
	return 1
}

main :: proc() {
	x: bool
	x = g() > 0
	_ = x
}
`,
	)
}

@(test)
split_decl_inferred_comparison_of_a_call_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Join declaration with inferred type",
		`package test

g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*}: bool
	x = g() > 0
	_ = x
}
`,
		`package test

g :: proc() -> int {
	return 1
}

main :: proc() {
	x := g() > 0
	_ = x
}
`,
	)
}

@(test)
split_decl_inferred_arithmetic_on_a_call :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Split declaration",
		`package test

g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*} := g() + 1
	_ = x
}
`,
		`package test

g :: proc() -> int {
	return 1
}

main :: proc() {
	x: int
	x = g() + 1
	_ = x
}
`,
	)
}

@(test)
split_decl_inferred_arithmetic_on_a_call_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Join declaration with inferred type",
		`package test

g :: proc() -> int {
	return 1
}

main :: proc() {
	x{*}: int
	x = g() + 1
	_ = x
}
`,
		`package test

g :: proc() -> int {
	return 1
}

main :: proc() {
	x := g() + 1
	_ = x
}
`,
	)
}

@(test)
split_decl_inferred_bool :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Split declaration",
		`package test

main :: proc() {
	x{*} := true
	_ = x
}
`,
		`package test

main :: proc() {
	x: bool
	x = true
	_ = x
}
`,
	)
}

@(test)
split_decl_inferred_bool_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Join declaration with inferred type",
		`package test

main :: proc() {
	x{*}: bool
	x = true
	_ = x
}
`,
		`package test

main :: proc() {
	x := true
	_ = x
}
`,
	)
}

@(test)
split_decl_inferred_copy_of_an_unnamed_type :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Split declaration",
		`package test

main :: proc() {
	arr := [3]int{1, 2, 3}
	x{*} := arr
	_ = x
}
`,
		`package test

main :: proc() {
	arr := [3]int{1, 2, 3}
	x: [3]int
	x = arr
	_ = x
}
`,
	)
}

@(test)
split_decl_inferred_copy_of_an_unnamed_type_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Join declaration with inferred type",
		`package test

main :: proc() {
	arr := [3]int{1, 2, 3}
	x{*}: [3]int
	x = arr
	_ = x
}
`,
		`package test

main :: proc() {
	arr := [3]int{1, 2, 3}
	x := arr
	_ = x
}
`,
	)
}

@(test)
split_decl_inferred_field_of_an_unnamed_type :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Split declaration",
		`package test

Holder :: struct {
	m: map[string]int,
}

main :: proc() {
	h: Holder
	x{*} := h.m
	_ = x
}
`,
		`package test

Holder :: struct {
	m: map[string]int,
}

main :: proc() {
	h: Holder
	x: map[string]int
	x = h.m
	_ = x
}
`,
	)
}

@(test)
split_decl_inferred_field_of_an_unnamed_type_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Join declaration with inferred type",
		`package test

Holder :: struct {
	m: map[string]int,
}

main :: proc() {
	h: Holder
	x{*}: map[string]int
	x = h.m
	_ = x
}
`,
		`package test

Holder :: struct {
	m: map[string]int,
}

main :: proc() {
	h: Holder
	x := h.m
	_ = x
}
`,
	)
}

@(test)
split_decl_split_refuses_a_typed_inferred_length :: proc(t: ^testing.T) {
	expect_missing(t, "Split declaration", `package test

main :: proc() {
	x{*}: [?]int = {1, 2}
	_ = x
}
`)
}

@(test)
split_decl_split_refuses_an_inferred_length :: proc(t: ^testing.T) {
	expect_missing(t, "Split declaration", `package test

main :: proc() {
	x{*} := [?]int{1, 2}
	_ = x
}
`)
}

@(test)
split_decl_split_refuses_a_copy_with_a_poly_parameter :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split declaration",
		`package test

gen :: proc(v: $T) {
	x{*} := v
	_ = x
}

main :: proc() {
	gen(1)
}
`,
	)
}

@(test)
split_decl_split_refuses_mixed_untyped_kinds :: proc(t: ^testing.T) {
	expect_missing(t, "Split declaration", `package test

main :: proc() {
	x{*} := 'a' + 1
	_ = x
}
`)
}

@(test)
split_decl_split_refuses_mixed_untyped_kinds_in_parens :: proc(t: ^testing.T) {
	expect_missing(t, "Split declaration", `package test

main :: proc() {
	x{*} := ('a' + 1) * 2
	_ = x
}
`)
}

@(test)
split_decl_join_refuses_a_blank_line_between :: proc(t: ^testing.T) {
	expect_missing(t, "Join declaration", `package test

main :: proc() {
	x{*}: int

	x = 1
	_ = x
}
`)
}

@(private = "file")
FOREIGN_PACKAGE := []test.Package {
	{
		pkg = "other",
		source = `package other

Item :: struct {
	a: int,
}

Arr :: [3]int

N :: 4

Holder :: struct {
	buf:   [dynamic]byte,
	items: []Item,
	Arr:   [2]int,
	sized: [N]int,
	inner: Inner,
}

Inner :: struct {
	bytes: []byte,
}

table: [3]int
names: []Item
arrv: Arr
`,
	},
}

// The first line of the split, for a value that main declares in the file with the package `other` imported.
@(private = "file")
expect_foreign_split :: proc(t: ^testing.T, before, value, type: string) {
	src := fmt.tprintf(
		"package test\n\nimport \"other\"\n\nmain :: proc() {{\n%s\tx{{*}} := %s\n\t_ = x\n}}\n",
		before,
		value,
	)
	expected := fmt.tprintf(
		"package test\n\nimport \"other\"\n\nmain :: proc() {{\n%s\tx: %s\n\tx = %s\n\t_ = x\n}}\n",
		before,
		type,
		value,
	)
	source := test.Source {
		main = src,
		packages = FOREIGN_PACKAGE,
		config = {enable_code_action_split_decl = true},
	}
	test.expect_action_applied(t, &source, "Split declaration", expected)
}

@(private = "file")
expect_foreign_refusal :: proc(t: ^testing.T, before, value: string) {
	src := fmt.tprintf(
		"package test\n\nimport \"other\"\n\nmain :: proc() {{\n%s\tx{{*}} := %s\n\t_ = x\n}}\n",
		before,
		value,
	)
	source := test.Source {
		main = src,
		packages = FOREIGN_PACKAGE,
		config = {enable_code_action_split_decl = true},
	}
	test.expect_action_missing(t, &source, "Split declaration")
}

// A value that main reads from `box`, with Box declared as fields.
@(private = "file")
expect_field_split :: proc(t: ^testing.T, decls, before, value, type: string) {
	src := fmt.tprintf("package test\n\n%s\nmain :: proc() {{\n%s\tx{{*}} := %s\n\t_ = x\n}}\n", decls, before, value)
	expected := fmt.tprintf(
		"package test\n\n%s\nmain :: proc() {{\n%s\tx: %s\n\tx = %s\n\t_ = x\n}}\n",
		decls,
		before,
		type,
		value,
	)
	expect_applied(t, "Split declaration", src, expected)
}

@(test)
split_decl_field_named_like_a_builtin :: proc(t: ^testing.T) {
	expect_field_split(t, "Box :: struct {\n\tmin, max: [3]f32,\n}\n", "\tbox: Box\n", "box.min", "[3]f32")
}

@(test)
split_decl_field_named_like_a_builtin_through_a_pointer :: proc(t: ^testing.T) {
	expect_field_split(t, "Box :: struct {\n\tmin, max: [3]f32,\n}\n", "\tbox: ^Box\n", "box.max", "[3]f32")
}

@(test)
split_decl_copy_of_a_field_named_like_a_builtin :: proc(t: ^testing.T) {
	expect_field_split(t, "Box :: struct {\n\tmin, max: [3]f32,\n}\n", "\tbox: Box\n\ty := box.min\n", "y", "[3]f32")
}

@(test)
split_decl_copy_of_a_copy_of_a_field_named_like_a_builtin :: proc(t: ^testing.T) {
	expect_field_split(
		t,
		"Box :: struct {\n\tmin, max: [3]f32,\n}\n",
		"\tbox: Box\n\ty := box.min\n\tz := y\n",
		"z",
		"[3]f32",
	)
}

@(test)
split_decl_field_named_like_a_procedure :: proc(t: ^testing.T) {
	expect_field_split(
		t,
		"helper :: proc() {}\n\nBox :: struct {\n\thelper: []int,\n}\n",
		"\tbox: Box\n",
		"box.helper",
		"[]int",
	)
}

@(test)
split_decl_field_named_like_a_type :: proc(t: ^testing.T) {
	expect_field_split(
		t,
		"Foo :: struct {\n\ta: int,\n}\n\nBox :: struct {\n\tFoo: []int,\n}\n",
		"\tbox: Box\n",
		"box.Foo",
		"[]int",
	)
}

@(test)
split_decl_field_named_like_a_type_of_the_same_kind :: proc(t: ^testing.T) {
	expect_field_split(t, "Sl :: []string\n\nBox :: struct {\n\tSl: []int,\n}\n", "\tbox: Box\n", "box.Sl", "[]int")
}

@(test)
split_decl_field_named_like_a_type_with_the_same_text :: proc(t: ^testing.T) {
	expect_field_split(
		t,
		"Sl :: distinct []int\n\nBox :: struct {\n\tSl: []int,\n}\n",
		"\tbox: Box\n",
		"box.Sl",
		"[]int",
	)
}

@(test)
split_decl_copy_of_a_field_named_like_a_type :: proc(t: ^testing.T) {
	expect_field_split(
		t,
		"Foo :: struct {\n\ta: int,\n}\n\nBox :: struct {\n\tFoo: []int,\n}\n",
		"\tbox: Box\n\ty := box.Foo\n",
		"y",
		"[]int",
	)
}

@(test)
split_decl_field_named_like_a_builtin_type :: proc(t: ^testing.T) {
	expect_field_split(t, "Box :: struct {\n\tint: []u8,\n}\n", "\tbox: Box\n", "box.int", "[]u8")
}

@(test)
split_decl_pointer_field_of_an_unnamed_type :: proc(t: ^testing.T) {
	expect_field_split(t, "Box :: struct {\n\tmin: ^[3]f32,\n}\n", "\tbox: Box\n", "box.min", "^[3]f32")
}

@(test)
split_decl_field_of_a_named_type_keeps_the_name :: proc(t: ^testing.T) {
	expect_field_split(t, "Arr :: [3]int\n\nBox :: struct {\n\ta: Arr,\n}\n", "\tbox: Box\n", "box.a", "Arr")
}

@(test)
split_decl_refuses_an_inline_distinct_field :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split declaration",
		`package test

Box :: struct {
	d: distinct [3]int,
}

main :: proc() {
	box: Box
	x{*} := box.d
	_ = x
}
`,
	)
}

@(test)
split_decl_refuses_a_type_a_local_shadows :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split declaration",
		`package test

Foo :: struct {
	a: int,
}

main :: proc() {
	v: Foo
	Foo := 1
	_ = Foo
	x{*} := v
	_ = x
}
`,
	)
}

@(test)
split_decl_refuses_an_element_type_a_local_shadows :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split declaration",
		`package test

Item :: struct {
	a: int,
}

Box :: struct {
	items: []Item,
}

main :: proc() {
	box: Box
	Item := 1
	_ = Item
	x{*} := box.items
	_ = x
}
`,
	)
}

@(test)
split_decl_field_named_like_a_builtin_back :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Join declaration with inferred type",
		`package test

Box :: struct {
	min, max: [3]f32,
}

main :: proc() {
	box: Box
	x{*}: [3]f32
	x = box.min
	_ = x
}
`,
		`package test

Box :: struct {
	min, max: [3]f32,
}

main :: proc() {
	box: Box
	x := box.min
	_ = x
}
`,
	)
}

@(test)
split_decl_foreign_field_of_an_unnamed_type :: proc(t: ^testing.T) {
	expect_foreign_split(t, "\th: other.Holder\n", "h.buf", "[dynamic]byte")
}

@(test)
split_decl_copy_of_a_foreign_field_of_an_unnamed_type :: proc(t: ^testing.T) {
	expect_foreign_split(t, "\th: other.Holder\n\ty := h.buf\n", "y", "[dynamic]byte")
}

@(test)
split_decl_foreign_field_named_like_a_foreign_type :: proc(t: ^testing.T) {
	expect_foreign_split(t, "\th: other.Holder\n", "h.Arr", "[2]int")
}

@(test)
split_decl_foreign_nested_field :: proc(t: ^testing.T) {
	expect_foreign_split(t, "\th: other.Holder\n", "h.inner.bytes", "[]byte")
}

@(test)
split_decl_foreign_field_of_a_named_type_keeps_the_name :: proc(t: ^testing.T) {
	expect_foreign_split(t, "\th: other.Holder\n", "h.inner", "other.Inner")
}

@(test)
split_decl_foreign_variable_of_a_named_type_keeps_the_name :: proc(t: ^testing.T) {
	expect_foreign_split(t, "", "other.arrv", "other.Arr")
}

@(test)
split_decl_refuses_a_foreign_element_type :: proc(t: ^testing.T) {
	expect_foreign_refusal(t, "\th: other.Holder\n", "h.items")
}

@(test)
split_decl_refuses_a_foreign_element_type_with_a_local_namesake :: proc(t: ^testing.T) {
	expect_foreign_refusal(t, "\tItem :: struct {}\n\th: other.Holder\n", "h.items")
}

@(test)
split_decl_refuses_a_foreign_array_length_name :: proc(t: ^testing.T) {
	expect_foreign_refusal(t, "\th: other.Holder\n", "h.sized")
}

@(test)
split_decl_refuses_a_foreign_variable_with_a_foreign_element_type :: proc(t: ^testing.T) {
	expect_foreign_refusal(t, "", "other.names")
}

@(test)
split_decl_refuses_a_foreign_alias_under_a_builtin_name :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "other"

main :: proc() {
	h: other.Holder
	x{*} := h.pair
	_ = x
}
`,
		packages = {
			{pkg = "other", source = "package other\n\nint :: i32\n\nHolder :: struct {\n\tpair: [2]int,\n}\n"},
		},
		config = {enable_code_action_split_decl = true},
	}
	test.expect_action_missing(t, &source, "Split declaration")
}

@(test)
split_decl_refuses_a_soa_field :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split declaration",
		`package test

Foo :: struct {
	a: int,
}

Box :: struct {
	items: #soa[]Foo,
}

main :: proc() {
	box: Box
	x{*} := box.items
	_ = x
}
`,
	)
}

@(test)
split_decl_refuses_a_builtin_type_a_local_shadows :: proc(t: ^testing.T) {
	expect_missing(t, "Split declaration", `package test

main :: proc() {
	int := 5
	_ = int
	x{*} := 1
	_ = x
}
`)
}

@(test)
split_decl_refuses_a_builtin_type_a_global_shadows :: proc(t: ^testing.T) {
	expect_missing(t, "Split declaration", `package test

int :: i32

main :: proc() {
	x{*} := 1
	_ = x
}
`)
}

@(test)
split_decl_refuses_an_element_type_a_local_shadows_as_a_builtin :: proc(t: ^testing.T) {
	expect_foreign_refusal(t, "\tbyte := 5\n\t_ = byte\n\th: other.Holder\n", "h.buf")
}

@(test)
split_decl_keeps_a_builtin_type_a_later_local_shadows :: proc(t: ^testing.T) {
	expect_applied(
		t,
		"Split declaration",
		`package test

main :: proc() {
	n: int
	x{*} := n
	_ = x
	int := 5
	_ = int
}
`,
		`package test

main :: proc() {
	n: int
	x: int
	x = n
	_ = x
	int := 5
	_ = int
}
`,
	)
}

@(test)
split_decl_refuses_an_element_type_a_local_of_a_struct_shadows :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split declaration",
		`package test

Item :: struct {
	a: int,
}

Foo :: struct {
	a: int,
}

Box :: struct {
	items: []Item,
}

main :: proc() {
	box: Box
	Item := Foo{}
	_ = Item
	x{*} := box.items
	_ = x
}
`,
	)
}

@(test)
split_decl_refuses_an_element_type_a_local_procedure_shadows :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split declaration",
		`package test

Item :: struct {
	a: int,
}

Box :: struct {
	items: []Item,
}

main :: proc() {
	box: Box
	Item :: proc() {}
	x{*} := box.items
	_ = x
}
`,
	)
}

@(test)
split_decl_refuses_a_package_a_local_type_shadows :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "other"

Box :: struct {
	items: []other.Item,
}

main :: proc() {
	box: Box
	other :: struct {
		a: int,
	}
	x{*} := box.items
	_ = x
}
`,
		packages = FOREIGN_PACKAGE,
		config = {enable_code_action_split_decl = true},
	}
	test.expect_action_missing(t, &source, "Split declaration")
}

@(test)
split_decl_keeps_a_qualified_element_type :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "other"

Box :: struct {
	items: []other.Item,
}

main :: proc() {
	box: Box
	x{*} := box.items
	_ = x
}
`,
		packages = FOREIGN_PACKAGE,
		config = {enable_code_action_split_decl = true},
	}
	test.expect_action_applied(
		t,
		&source,
		"Split declaration",
		`package test

import "other"

Box :: struct {
	items: []other.Item,
}

main :: proc() {
	box: Box
	x: []other.Item
	x = box.items
	_ = x
}
`,
	)
}

@(test)
split_decl_refuses_a_copy_of_a_type_under_the_type_name :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split declaration",
		`package test

Foo :: struct {
	a: int,
}

main :: proc() {
	Foo := Foo{}
	x{*} := Foo
	_ = x
}
`,
	)
}

@(test)
split_decl_refuses_an_element_type_a_parameter_shadows :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split declaration",
		`package test

Item :: struct {
	a: int,
}

Foo :: struct {
	a: int,
}

Box :: struct {
	items: []Item,
}

f :: proc(box: Box, Item: Foo) {
	x{*} := box.items
	_ = x
}
`,
	)
}

@(test)
split_decl_refuses_a_parameter_under_the_type_name :: proc(t: ^testing.T) {
	expect_missing(
		t,
		"Split declaration",
		`package test

Foo :: struct {
	a: int,
}

f :: proc(Foo: Foo) {
	x{*} := Foo
	_ = x
}
`,
	)
}

@(test)
split_decl_copy_of_a_foreign_variable_of_an_unnamed_type :: proc(t: ^testing.T) {
	expect_foreign_split(t, "\ty := other.table\n", "y", "[3]int")
}

@(test)
split_decl_refuses_a_copy_of_a_foreign_variable_with_a_foreign_element_type :: proc(t: ^testing.T) {
	expect_foreign_refusal(t, "\ty := other.names\n", "y")
}
