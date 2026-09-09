package tests

import "core:strings"
import "core:testing"

import test "src:testing"

FLIP_ACTION :: "Flip comparison"
DE_MORGAN_ACTION :: "Apply De Morgan's law"
COMPOUND_ACTION :: "Use compound assignment"
EXPAND_ACTION :: "Expand compound assignment"

@(test)
action_flip_comparison_lt :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := 1, 2
	if a {*}< b {
		foo()
	}
}
`,
		packages = {},
		config = {enable_code_action_rewrite_expression = true},
	}

	test.expect_action_applied(t, &source, FLIP_ACTION, `package test

main :: proc() {
	a, b := 1, 2
	if b > a {
		foo()
	}
}
`)
}

@(test)
action_flip_comparison_eq :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x := 1
	ok := x =={*} 1
}
`,
		packages = {},
		config = {enable_code_action_rewrite_expression = true},
	}

	test.expect_action_applied(t, &source, FLIP_ACTION, `package test

main :: proc() {
	x := 1
	ok := 1 == x
}
`)
}

@(test)
action_flip_comparison_innermost :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b, c, d := 1, 2, 3, 4
	ok := (a {*}< b) == (c > d)
}
`,
		packages = {},
		config = {enable_code_action_rewrite_expression = true},
	}

	test.expect_action_applied(t, &source, FLIP_ACTION, `package test

main :: proc() {
	a, b, c, d := 1, 2, 3, 4
	ok := (b > a) == (c > d)
}
`)
}

@(test)
action_de_morgan_distribute_and :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := true, false
	if !(a {*}&& b) {
		foo()
	}
}
`,
		packages = {},
		config = {enable_code_action_rewrite_expression = true},
	}

	test.expect_action_applied(t, &source, DE_MORGAN_ACTION, `package test

main :: proc() {
	a, b := true, false
	if !a || !b {
		foo()
	}
}
`)
}

@(test)
action_de_morgan_distribute_or_with_comparison :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x, y := 1, true
	if {*}!(x == 1 || y) {
		foo()
	}
}
`,
		packages = {},
		config = {enable_code_action_rewrite_expression = true},
	}

	test.expect_action_applied(t, &source, DE_MORGAN_ACTION, `package test

main :: proc() {
	x, y := 1, true
	if x != 1 && !y {
		foo()
	}
}
`)
}

@(test)
action_de_morgan_distribute_chain :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b, c := true, false, true
	ok := !(a && b {*}&& c)
}
`,
		packages = {},
		config = {enable_code_action_rewrite_expression = true},
	}

	test.expect_action_applied(t, &source, DE_MORGAN_ACTION, `package test

main :: proc() {
	a, b, c := true, false, true
	ok := !a || !b || !c
}
`)
}

@(test)
action_de_morgan_distribute_nested_gets_parens :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b, c := true, false, true
	ok := c && !(a {*}&& b)
}
`,
		packages = {},
		config = {enable_code_action_rewrite_expression = true},
	}

	test.expect_action_applied(t, &source, DE_MORGAN_ACTION, `package test

main :: proc() {
	a, b, c := true, false, true
	ok := c && (!a || !b)
}
`)
}

@(test)
action_de_morgan_factor :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := true, false
	if !a {*}&& !b {
		foo()
	}
}
`,
		packages = {},
		config = {enable_code_action_rewrite_expression = true},
	}

	test.expect_action_applied(t, &source, DE_MORGAN_ACTION, `package test

main :: proc() {
	a, b := true, false
	if !(a || b) {
		foo()
	}
}
`)
}

@(test)
action_de_morgan_factor_refused_for_comparison_leaf :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := 1, false
	if a < 1 {*}&& !b {
		foo()
	}
}
`,
		packages = {},
		config = {enable_code_action_rewrite_expression = true},
	}

	test.expect_action_missing(t, &source, DE_MORGAN_ACTION)
}

@(test)
action_compound_assignment_add :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x := 1
	x = x {*}+ 1
}
`,
		packages = {},
		config = {enable_code_action_rewrite_expression = true},
	}

	test.expect_action_applied(t, &source, COMPOUND_ACTION, `package test

main :: proc() {
	x := 1
	x += 1
}
`)
}

@(test)
action_compound_assignment_index :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	v := []int{1, 2}
	i := 0
	{*}v[i] = v[i] * 2
}
`,
		packages = {},
		config = {enable_code_action_rewrite_expression = true},
	}

	test.expect_action_applied(t, &source, COMPOUND_ACTION, `package test

main :: proc() {
	v := []int{1, 2}
	i := 0
	v[i] *= 2
}
`)
}

@(test)
action_compound_assignment_call_in_rhs :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

P :: struct {
	x: int,
}

f :: proc() -> int {
	return 1
}

main :: proc() {
	p: P
	p.x = p.x {*}+ f()
}
`,
		packages = {},
		config = {enable_code_action_rewrite_expression = true},
	}

	test.expect_action_applied(t, &source, COMPOUND_ACTION, `package test

P :: struct {
	x: int,
}

f :: proc() -> int {
	return 1
}

main :: proc() {
	p: P
	p.x += f()
}
`)
}

@(test)
action_compound_assignment_refused_call_in_lhs :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

P :: struct {
	x: int,
}

get :: proc(p: ^P) -> ^P {
	return p
}

main :: proc() {
	p: P
	get(&p).x = get(&p).x {*}+ 1
}
`,
		packages = {},
		config = {enable_code_action_rewrite_expression = true},
	}

	test.expect_action_missing(t, &source, COMPOUND_ACTION)
}

@(test)
action_expand_compound_assignment :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x := 1
	x {*}+= 1
}
`,
		packages = {},
		config = {enable_code_action_rewrite_expression = true},
	}

	test.expect_action_applied(t, &source, EXPAND_ACTION, `package test

main :: proc() {
	x := 1
	x = x + 1
}
`)
}

@(test)
action_expand_compound_assignment_wraps_rhs :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x, a, b := 1, 2, 3
	x *= a {*}+ b
}
`,
		packages = {},
		config = {enable_code_action_rewrite_expression = true},
	}

	test.expect_action_applied(t, &source, EXPAND_ACTION, `package test

main :: proc() {
	x, a, b := 1, 2, 3
	x = x * (a + b)
}
`)
}

@(test)
action_rewrite_expression_disabled :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := 1, 2
	if a {*}< b {
		foo()
	}
}
`,
		packages = {},
		config = {enable_code_action_rewrite_expression = false},
	}

	test.expect_action_missing(t, &source, FLIP_ACTION)
}

// `if <cond> { foo() }` in a proc; `cond` carries the `{*}` marker.
rewrite_if_source :: proc(cond: string) -> string {
	return strings.concatenate(
		{"package test\n\nmain :: proc() {\n\tif ", cond, " {\n\t\tfoo()\n\t}\n}\n"},
		context.temp_allocator,
	)
}

expect_de_morgan_round_trip :: proc(t: ^testing.T, cond: string) {
	source := test.Source {
		main = rewrite_if_source(cond),
		config = {enable_code_action_rewrite_expression = true},
	}
	test.expect_action_round_trip(t, &source, {DE_MORGAN_ACTION, DE_MORGAN_ACTION})
}

expect_de_morgan_applied :: proc(t: ^testing.T, cond, expected: string) {
	source := test.Source {
		main = rewrite_if_source(cond),
		config = {enable_code_action_rewrite_expression = true},
	}
	test.expect_action_applied(t, &source, DE_MORGAN_ACTION, rewrite_if_source(expected))
}

@(test)
de_morgan_distribute_then_factor_round_trip :: proc(t: ^testing.T) {
	expect_de_morgan_round_trip(t, "!(a {*}&& b)")
}

@(test)
de_morgan_or_chain_round_trip :: proc(t: ^testing.T) {
	// The cursor sits outside the left sub-chain, so the whole chain is factored back.
	expect_de_morgan_round_trip(t, "!(a || b {*}|| c)")
}

@(test)
de_morgan_factor_then_distribute_round_trip :: proc(t: ^testing.T) {
	expect_de_morgan_round_trip(t, "!a {*}&& !b")
}

@(test)
de_morgan_inside_parens_round_trip :: proc(t: ^testing.T) {
	expect_de_morgan_round_trip(t, "(!(a {*}&& b))")
}

@(test)
de_morgan_as_operand_round_trip_adds_parens :: proc(t: ^testing.T) {
	source := test.Source {
		main = rewrite_if_source("x && !(a {*}|| b)"),
		config = {enable_code_action_rewrite_expression = true},
	}
	test.expect_action_chain(t, &source, {DE_MORGAN_ACTION, DE_MORGAN_ACTION}, rewrite_if_source("x && (!(a || b))"))
}

@(test)
de_morgan_comparison_leaves_are_not_negated_twice :: proc(t: ^testing.T) {
	expect_de_morgan_applied(t, "!(a < b {*}&& c >= d)", "a >= b || c < d")
}

@(test)
de_morgan_membership_and_negated_leaf :: proc(t: ^testing.T) {
	expect_de_morgan_applied(t, "!(x in s {*}&& !y)", "x not_in s || y")
}

@(test)
de_morgan_four_leaf_chain :: proc(t: ^testing.T) {
	expect_de_morgan_applied(t, "!(a && b {*}&& c && d)", "!a || !b || !c || !d")
}

@(test)
de_morgan_call_leaf :: proc(t: ^testing.T) {
	expect_de_morgan_applied(t, "!(!f(x) {*}|| g(y))", "f(x) && !g(y)")
}

@(test)
de_morgan_ternary_leaf :: proc(t: ^testing.T) {
	expect_de_morgan_applied(t, "!((a ? b : c) {*}&& d)", "!(a ? b : c) || !d")
}

expect_flip_round_trip :: proc(t: ^testing.T, cond: string, times := 2) {
	source := test.Source {
		main = rewrite_if_source(cond),
		config = {enable_code_action_rewrite_expression = true},
	}
	titles := make([]string, times, context.temp_allocator)
	for &title in titles {
		title = FLIP_ACTION
	}
	test.expect_action_round_trip(t, &source, titles)
}

@(test)
flip_comparison_round_trip_operators :: proc(t: ^testing.T) {
	for cond in ([]string{"a {*}< b", "a {*}<= b", "a {*}== b", "f(x) {*}> g(y)"}) {
		expect_flip_round_trip(t, cond)
	}
}

@(test)
flip_comparison_four_times :: proc(t: ^testing.T) {
	expect_flip_round_trip(t, "a {*}< b", 4)
}

@(test)
flip_comparison_nested_outer_round_trip :: proc(t: ^testing.T) {
	expect_flip_round_trip(t, "(a < b) {*}== (c > d)")
}

@(test)
flip_comparison_nested_inner_round_trip :: proc(t: ^testing.T) {
	expect_flip_round_trip(t, "({*}a < b) == (c > d)")
}

@(test)
flip_comparison_string_operand :: proc(t: ^testing.T) {
	expect_flip_round_trip(t, `s {*}< "a<b"`)
}

@(test)
compound_assignment_operators_round_trip :: proc(t: ^testing.T) {
	for op in ([]string{"+", "-", "*", "/", "%", "%%", "&", "|", "~", "&~", "<<", ">>"}) {
		main := strings.concatenate(
			{"package test\n\nmain :: proc() {\n\tx, y := 1, 2\n\tx {*}= x ", op, " y\n}\n"},
			context.temp_allocator,
		)
		source := test.Source {
			main = main,
			config = {enable_code_action_rewrite_expression = true},
		}
		test.expect_action_round_trip(t, &source, {COMPOUND_ACTION, EXPAND_ACTION})
	}
}

@(test)
compound_assignment_expand_then_fold_mul :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x, a, b := 1, 2, 3
	x {*}*= a + b
}
`,
		config = {enable_code_action_rewrite_expression = true},
	}

	test.expect_action_round_trip(t, &source, {EXPAND_ACTION, COMPOUND_ACTION})
}

@(test)
compound_assignment_expand_then_fold_sub :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x, y, z := 1, 2, 3
	x {*}-= y - z
}
`,
		config = {enable_code_action_rewrite_expression = true},
	}

	test.expect_action_round_trip(t, &source, {EXPAND_ACTION, COMPOUND_ACTION})
}

@(test)
compound_assignment_missing_for_three_terms :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x, y, z := 1, 2, 3
	x {*}= x + y + z
}
`,
		config = {enable_code_action_rewrite_expression = true},
	}

	test.expect_action_missing(t, &source, COMPOUND_ACTION)
}

@(test)
compound_assignment_missing_when_target_is_right_operand :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x, y := 1, 2
	x {*}= y + x
}
`,
		config = {enable_code_action_rewrite_expression = true},
	}

	test.expect_action_missing(t, &source, COMPOUND_ACTION)
}

@(test)
compound_assignment_missing_for_parenthesised_target :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x := 1
	x {*}= (x) + 1
}
`,
		config = {enable_code_action_rewrite_expression = true},
	}

	test.expect_action_missing(t, &source, COMPOUND_ACTION)
}

@(test)
compound_assignment_selector_index_target :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a: struct {
		b: []int,
	}
	i := 0
	a.b[i] {*}= a.b[i] + 1
}
`,
		config = {enable_code_action_rewrite_expression = true},
	}

	test.expect_action_applied(t, &source, COMPOUND_ACTION, `package test

main :: proc() {
	a: struct {
		b: []int,
	}
	i := 0
	a.b[i] += 1
}
`)
}

@(test)
compound_assignment_ignores_spacing_in_target :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a: struct {
		b: []int,
	}
	i := 0
	a.b [i] {*}= a.b[i] + 1
}
`,
		config = {enable_code_action_rewrite_expression = true},
	}

	test.expect_action_applied(t, &source, COMPOUND_ACTION, `package test

main :: proc() {
	a: struct {
		b: []int,
	}
	i := 0
	a.b [i] += 1
}
`)
}

@(test)
expand_compound_assignment_ternary_rhs :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x, c := 1, true
	x {*}+= c ? 1 : 2
}
`,
		config = {enable_code_action_rewrite_expression = true},
	}

	test.expect_action_applied(t, &source, EXPAND_ACTION, `package test

main :: proc() {
	x, c := 1, true
	x = x + (c ? 1 : 2)
}
`)
}
