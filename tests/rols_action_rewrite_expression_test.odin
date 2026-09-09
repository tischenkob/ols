package tests

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
