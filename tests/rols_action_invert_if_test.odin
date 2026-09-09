package tests

import "core:strings"
import "core:testing"

import test "src:testing"

// `if <cond> { foo() }` with the cursor before the condition.
invert_if_input :: proc(cond: string, marker := "{*}") -> string {
	return strings.concatenate(
		{"package test\n\nmain :: proc() {\n\tif ", marker, cond, " {\n\t\tfoo()\n\t}\n}\n"},
		context.temp_allocator,
	)
}

// The same if after one inversion: an empty then block and the old body in the else.
invert_if_output :: proc(cond: string) -> string {
	return strings.concatenate(
		{"package test\n\nmain :: proc() {\n\tif ", cond, " {\n\t} else {\n\t\tfoo()\n\t}\n}\n"},
		context.temp_allocator,
	)
}

expect_invert_round_trip_4 :: proc(t: ^testing.T, main: string) {
	source := test.Source {
		main = main,
		config = {enable_code_action_invert_if = true},
	}
	test.expect_action_round_trip(t, &source, {INVERT_IF_ACTION, INVERT_IF_ACTION, INVERT_IF_ACTION, INVERT_IF_ACTION})
}

@(test)
invert_if_negation_forms :: proc(t: ^testing.T) {
	forms := [][2]string {
		{"!(a || b)", "a || b"},
		{"!f(x)", "f(x)"},
		{"!p.q[i]", "p.q[i]"},
		{"a == b && c", "!(a == b && c)"},
		{"x not_in set", "x in set"},
	}
	for form in forms {
		expect_inverted(t, invert_if_input(form[0]), invert_if_output(form[1]))
	}
}

@(test)
invert_if_parenthesised_forms :: proc(t: ^testing.T) {
	forms := [][2]string{{"((a))", "((!a))"}, {"(a < b)", "(a >= b)"}, {"(a < b) && c", "!((a < b) && c)"}}
	for form in forms {
		expect_inverted(t, invert_if_input(form[0]), invert_if_output(form[1]))
	}
}

@(test)
invert_if_comparison_operand_forms :: proc(t: ^testing.T) {
	forms := [][2]string{{"-x < 0", "-x >= 0"}, {"f(x).y[i] == nil", "f(x).y[i] != nil"}}
	for form in forms {
		expect_inverted(t, invert_if_input(form[0]), invert_if_output(form[1]))
	}
}

@(test)
invert_if_double_negation_normalises_to_one :: proc(t: ^testing.T) {
	source := test.Source {
		main = invert_if_input("!!x"),
		config = {enable_code_action_invert_if = true},
	}
	test.expect_action_applied(t, &source, INVERT_IF_ACTION, invert_if_output("!x"))
	expect_invert_round_trip(t, invert_if_input("!!x"), invert_if_input("x", ""))
}

@(test)
invert_if_ternary_round_trip_adds_parens :: proc(t: ^testing.T) {
	source := test.Source {
		main = invert_if_input("a ? b : c"),
		config = {enable_code_action_invert_if = true},
	}
	test.expect_action_applied(t, &source, INVERT_IF_ACTION, invert_if_output("!(a ? b : c)"))
	expect_invert_round_trip(t, invert_if_input("a ? b : c"), invert_if_input("(a ? b : c)", ""))
}

@(test)
invert_if_or_else_round_trip_adds_parens :: proc(t: ^testing.T) {
	source := test.Source {
		main = invert_if_input("a or_else false"),
		config = {enable_code_action_invert_if = true},
	}
	test.expect_action_applied(t, &source, INVERT_IF_ACTION, invert_if_output("!(a or_else false)"))
	expect_invert_round_trip(t, invert_if_input("a or_else false"), invert_if_input("(a or_else false)", ""))
}

@(test)
invert_if_init_call :: proc(t: ^testing.T) {
	expect_inverted(
		t,
		`package test

main :: proc() {
	if ok := f(); {*}ok {
		foo()
	}
}
`,
		`package test

main :: proc() {
	if ok := f(); !ok {
	} else {
		foo()
	}
}
`,
	)
}

@(test)
invert_if_four_inversions_are_identity :: proc(t: ^testing.T) {
	for cond in ([]string{"!(a && b)", "x in set", "a < b"}) {
		expect_invert_round_trip_4(t, invert_if_input(cond))
	}
	expect_invert_round_trip_4(t, `package test

main :: proc() {
	if ok := f(); {*}ok {
		foo()
	}
}
`)
}

@(test)
invert_if_three_inversions_equal_one :: proc(t: ^testing.T) {
	source := test.Source {
		main = invert_if_input("a < b"),
		config = {enable_code_action_invert_if = true},
	}
	test.expect_action_chain(
		t,
		&source,
		{INVERT_IF_ACTION, INVERT_IF_ACTION, INVERT_IF_ACTION},
		invert_if_output("a >= b"),
	)
}

@(test)
invert_if_comment_before_nested_if_blocks_folding :: proc(t: ^testing.T) {
	expect_inverted(
		t,
		`package test

main :: proc() {
	if {*}x > 0 {
		// note
		if y > 0 {
			foo()
		}
	} else {
		bar()
	}
}
`,
		`package test

main :: proc() {
	if x <= 0 {
		bar()
	} else {
		// note
		if y > 0 {
			foo()
		}
	}
}
`,
	)
}

@(test)
invert_if_comment_after_nested_if_blocks_folding :: proc(t: ^testing.T) {
	expect_inverted(
		t,
		`package test

main :: proc() {
	if {*}x > 0 {
		if y > 0 {
			foo()
		}
		// note
	} else {
		bar()
	}
}
`,
		`package test

main :: proc() {
	if x <= 0 {
		bar()
	} else {
		if y > 0 {
			foo()
		}
		// note
	}
}
`,
	)
}

@(test)
invert_if_nested_else_if_normalises_to_chain :: proc(t: ^testing.T) {
	expect_invert_round_trip(
		t,
		`package test

main :: proc() {
	if {*}x > 0 {
		foo()
	} else {
		if y > 0 {
			bar()
		}
	}
}
`,
		`package test

main :: proc() {
	if x > 0 {
		foo()
	} else if y > 0 {
		bar()
	}
}
`,
	)
}

@(test)
invert_if_empty_body_normalises_to_block :: proc(t: ^testing.T) {
	expect_invert_round_trip(
		t,
		`package test

main :: proc() {
	if {*}c {} else {
		foo()
	}
}
`,
		`package test

main :: proc() {
	if c {
	} else {
		foo()
	}
}
`,
	)
}

@(test)
invert_if_empty_else_is_dropped :: proc(t: ^testing.T) {
	expect_invert_round_trip(
		t,
		`package test

main :: proc() {
	if {*}c {
		foo()
	} else {}
}
`,
		`package test

main :: proc() {
	if c {
		foo()
	}
}
`,
	)
}

@(test)
invert_if_both_bodies_empty :: proc(t: ^testing.T) {
	expect_invert_round_trip(
		t,
		`package test

main :: proc() {
	if {*}c {} else {}
}
`,
		`package test

main :: proc() {
	if c {
	}
}
`,
	)
}

@(test)
invert_if_two_space_indentation :: proc(t: ^testing.T) {
	expect_inverted(
		t,
		`package test

main :: proc() {
  if {*}x > 0 {
    for i in 0 ..< 3 {
      foo(i)
    }
  }
}
`,
		`package test

main :: proc() {
  if x <= 0 {
  } else {
    for i in 0 ..< 3 {
      foo(i)
    }
  }
}
`,
	)
}

@(test)
invert_if_crlf_source :: proc(t: ^testing.T) {
	crlf :: proc(s: string) -> string {
		return strings.replace_all(s, "\n", "\r\n", context.temp_allocator) or_else s
	}
	expect_inverted(
		t,
		crlf(`package test

main :: proc() {
	if {*}x > 0 {
		foo()
	}
}
`),
		crlf(`package test

main :: proc() {
	if x <= 0 {
	} else {
		foo()
	}
}
`),
	)
}

@(test)
invert_if_unicode_identifiers :: proc(t: ^testing.T) {
	expect_inverted(
		t,
		`package test

main :: proc() {
	if {*}θ_värde > π {
		Ω()
	}
}
`,
		`package test

main :: proc() {
	if θ_värde <= π {
	} else {
		Ω()
	}
}
`,
	)
}

@(test)
invert_if_string_literal_with_operators :: proc(t: ^testing.T) {
	expect_inverted(
		t,
		`package test

main :: proc() {
	if {*}s == "a && !b // {}" {
		foo("} else {")
	}
}
`,
		`package test

main :: proc() {
	if s != "a && !b // {}" {
	} else {
		foo("} else {")
	}
}
`,
	)
}

@(test)
invert_if_early_return_missing_with_results :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() -> (int, bool) {
	if {*}x > 0 {
		foo()
	}
	return 0, false
}
`,
		config = {enable_code_action_invert_if = true},
	}

	test.expect_action_missing(t, &source, EARLY_RETURN_ACTION)
}

@(test)
invert_if_early_return_missing_with_named_results :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() -> (ok: bool) {
	if {*}x > 0 {
		foo()
	}
	return
}
`,
		config = {enable_code_action_invert_if = true},
	}

	test.expect_action_missing(t, &source, EARLY_RETURN_ACTION)
}

@(test)
invert_if_early_return_missing_with_else :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	if {*}x > 0 {
		foo()
	} else {
		return
	}
}
`,
		config = {enable_code_action_invert_if = true},
	}

	test.expect_action_missing(t, &source, EARLY_RETURN_ACTION)
}

@(test)
invert_if_early_continue_in_loop_inside_case :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	switch x {
	case 1:
		for i in 0 ..< 3 {
			if {*}i > 0 {
				foo()
			}
		}
	}
}
`,
		config = {enable_code_action_invert_if = true},
	}

	test.expect_action(t, &source, {INVERT_IF_ACTION, "Invert if (early continue)"})
}

@(test)
invert_if_early_break_not_offered_in_loop_inside_case :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	switch x {
	case 1:
		for i in 0 ..< 3 {
			if {*}i > 0 {
				foo()
			}
		}
	}
}
`,
		config = {enable_code_action_invert_if = true},
	}

	test.expect_action_missing(t, &source, "Invert if (early break)")
}
