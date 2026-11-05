package tests

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
