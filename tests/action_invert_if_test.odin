package tests

// rols: import for the fork assertions
import "core:strings"
import "core:testing"

import test "src:testing"

INVERT_IF_ACTION :: "Invert if"
// rols: the early-exit variant
EARLY_RETURN_ACTION :: "Invert if (early return)"

@(test)
action_invert_if_simple :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x := 5
	if x{*} >= 0 {
		foo()
	}
}
`,
		packages = {},
		config = {enable_code_action_invert_if = true},
	}

	test.expect_action(t, &source, {INVERT_IF_ACTION})
}

@(test)
action_invert_if_simple_edit :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

main :: proc() {
	x := 5
	if x{*} >= 0 {
		foo()
	}
}
`,
		packages = {},
		config = {enable_code_action_invert_if = true},
	}

	expected := `if x < 0 {
	} else {
		foo()
	}`

	test.expect_action_with_edit(t, &source, INVERT_IF_ACTION, expected)
}

@(test)
action_invert_if_with_else :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

main :: proc() {
	x := 5
	if x{*} == 0 {
		foo()
	} else {
		bar()
	}
}
`,
		packages = {},
		config = {enable_code_action_invert_if = true},
	}

	test.expect_action(t, &source, {INVERT_IF_ACTION})
}

@(test)
action_invert_if_with_else_edit :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

main :: proc() {
	x := 5
	if x{*} == 0 {
		foo()
	} else {
		bar()
	}
}
`,
		packages = {},
		config = {enable_code_action_invert_if = true},
	}

	expected := `if x != 0 {
		bar()
	} else {
		foo()
	}`

	test.expect_action_with_edit(t, &source, INVERT_IF_ACTION, expected)
}

@(test)
action_invert_if_with_init :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

main :: proc() {
	if x{*} := foo(); x < 0 {
		bar()
	}
}
`,
		packages = {},
		config = {enable_code_action_invert_if = true},
	}

	test.expect_action(t, &source, {INVERT_IF_ACTION})
}

@(test)
action_invert_if_with_init_edit :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

main :: proc() {
	if x{*} := foo(); x < 0 {
		bar()
	}
}
`,
		packages = {},
		config = {enable_code_action_invert_if = true},
	}

	expected := `if x := foo(); x >= 0 {
	} else {
		bar()
	}`

	test.expect_action_with_edit(t, &source, INVERT_IF_ACTION, expected)
}

@(test)
action_invert_if_not_on_if :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

main :: proc() {
	x :={*} 5
}
`,
		packages = {},
		config = {enable_code_action_invert_if = true},
	}

	// Should not have the invert action when not on an if statement
	test.expect_action(t, &source, {})
}


@(test)
action_invert_if_inside_of_statement :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

main :: proc() {
	if x != 0 {
		foo{*}()
	}
}
`,
		packages = {},
		config = {enable_code_action_invert_if = true},
	}

	test.expect_action(t, &source, {})
}

@(test)
action_invert_if_not_eq :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

main :: proc() {
	if x{*} != 0 {
		foo()
	}
}
`,
		packages = {},
		config = {enable_code_action_invert_if = true},
	}

	expected := `if x == 0 {
	} else {
		foo()
	}`

	test.expect_action_with_edit(t, &source, INVERT_IF_ACTION, expected)
}

@(test)
action_invert_if_lt :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

main :: proc() {
	if x{*} < 5 {
		foo()
	}
}
`,
		packages = {},
		config = {enable_code_action_invert_if = true},
	}

	expected := `if x >= 5 {
	} else {
		foo()
	}`

	test.expect_action_with_edit(t, &source, INVERT_IF_ACTION, expected)
}

@(test)
action_invert_if_gt :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

main :: proc() {
	if x{*} > 5 {
		foo()
	}
}
`,
		packages = {},
		config = {enable_code_action_invert_if = true},
	}

	expected := `if x <= 5 {
	} else {
		foo()
	}`

	test.expect_action_with_edit(t, &source, INVERT_IF_ACTION, expected)
}

@(test)
action_invert_if_le :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

main :: proc() {
	if x{*} <= 5 {
		foo()
	}
}
`,
		packages = {},
		config = {enable_code_action_invert_if = true},
	}

	expected := `if x > 5 {
	} else {
		foo()
	}`

	test.expect_action_with_edit(t, &source, INVERT_IF_ACTION, expected)
}

@(test)
action_invert_if_negated :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

main :: proc() {
	if !x{*} {
		foo()
	}
}
`,
		packages = {},
		config = {enable_code_action_invert_if = true},
	}

	expected := `if x {
	} else {
		foo()
	}`

	test.expect_action_with_edit(t, &source, INVERT_IF_ACTION, expected)
}

@(test)
action_invert_if_boolean :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

main :: proc() {
	if x{*} {
		foo()
	}
}
`,
		packages = {},
		config = {enable_code_action_invert_if = true},
	}

	expected := `if !x {
	} else {
		foo()
	}`

	test.expect_action_with_edit(t, &source, INVERT_IF_ACTION, expected)
}

@(test)
action_invert_if_else_if_chain :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

main :: proc() {
	x := something()
	if x{*} > 0 {
		statement1()
	} else if x < 0 {
		statement2()
	} else {
		statement3()
	}
}
`,
		packages = {},
		config = {enable_code_action_invert_if = true},
	}

	// rols: the rewrite keeps the nested block at its own depth
	expected := `if x <= 0 {
		if x < 0 {
			statement2()
		} else {
			statement3()
		}
	} else {
		statement1()
	}`

	test.expect_action_with_edit(t, &source, INVERT_IF_ACTION, expected)
}

@(test)
action_invert_if_not_on_else_if :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

main :: proc() {
	x := something()
	if x > 0 {
		statement1()
	} else if x{*} < 0 {
		statement2()
	} else {
		statement3()
	}
}
`,
		packages = {},
		config = {enable_code_action_invert_if = true},
	}

	// Should not have the invert action when on an else-if statement
	test.expect_action(t, &source, {})
}

@(test)
action_invert_if_not_on_else :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

main :: proc() {
	x := something()
	if x > 0 {
		statement1()
	} else {
		statement3(){*}
	}
}
`,
		packages = {},
		config = {enable_code_action_invert_if = true},
	}

	// Should not have the invert action when in the else block (not on an if)
	test.expect_action(t, &source, {})
}

@(test)
action_invert_if_nested_in_else_if_body :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

main :: proc() {
	x := something()
	if x > 0 {
		statement1()
	} else if x < 0 {
		if y{*} > 0 {
			statement2()
		}
	} else {
		statement3()
	}
}
`,
		packages = {},
		config = {enable_code_action_invert_if = true},
	}

	// Should have the invert action for an if statement nested inside an else-if body
	test.expect_action(t, &source, {INVERT_IF_ACTION})
}

// rols: tests for the fork behaviour
@(test)
action_invert_if_selection :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x := 5
	{[if x >= 0 {
		foo()
	}]}
}
`,
		config = {enable_code_action_invert_if = true},
	}

	test.expect_action(t, &source, {INVERT_IF_ACTION})
}

@(test)
action_invert_if_missing_outside_if :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x{*} := 5
	if x >= 0 {
		foo()
	}
}
`,
		config = {enable_code_action_invert_if = true},
	}

	test.expect_action_missing(t, &source, INVERT_IF_ACTION)
}

@(test)
invert_if_early_return_last_statement :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x := 5
	if x{*} > 0 {
		foo()
		bar()
	}
}
`,
		config = {enable_code_action_invert_if = true},
	}

	expected := `package test

main :: proc() {
	x := 5
	if x <= 0 {
		return
	}
	foo()
	bar()
}
`

	test.expect_action_applied(t, &source, EARLY_RETURN_ACTION, expected)
}

@(test)
invert_if_early_return_with_following_statements :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	if x{*} > 0 {
		foo() // keep me
		return
	}
	bar()

	// between
	baz()
}
`,
		config = {enable_code_action_invert_if = true},
	}

	expected := `package test

main :: proc() {
	if x <= 0 {
		bar()

		// between
		baz()
		return
	}
	foo() // keep me
}
`

	test.expect_action_applied(t, &source, EARLY_RETURN_ACTION, expected)
}

@(test)
invert_if_early_return_following_ends_with_return :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	if x{*} > 0 {
		foo()
		return
	}
	bar()
	return
}
`,
		config = {enable_code_action_invert_if = true},
	}

	expected := `package test

main :: proc() {
	if x <= 0 {
		bar()
		return
	}
	foo()
}
`

	test.expect_action_applied(t, &source, EARLY_RETURN_ACTION, expected)
}

@(test)
invert_if_early_return_not_offered :: proc(t: ^testing.T) {
	only_plain_invert :: proc(t: ^testing.T, main: string) {
		missing := test.Source{main = main, config = {enable_code_action_invert_if = true}}
		test.expect_action_missing(t, &missing, EARLY_RETURN_ACTION)
		plain := test.Source{main = main, config = {enable_code_action_invert_if = true}}
		test.expect_action(t, &plain, {INVERT_IF_ACTION})
	}

	// Inside a loop.
	only_plain_invert(t, `package test

main :: proc() {
	for {
		if x{*} > 0 {
			foo()
		}
	}
}
`)

	// With else.
	only_plain_invert(t, `package test

main :: proc() {
	if x{*} > 0 {
		foo()
	} else {
		bar()
	}
}
`)

	// With init.
	only_plain_invert(t, `package test

main :: proc() {
	if ok{*} := f(); ok {
		foo()
	}
}
`)

	// Proc with a result.
	only_plain_invert(t, `package test

main :: proc() -> int {
	if x{*} > 0 {
		foo()
	}
	return 1
}
`)

	// Not last and the body does not end with return.
	only_plain_invert(t, `package test

main :: proc() {
	if x{*} > 0 {
		foo()
	}
	bar()
}
`)

	// A following defer would run before the moved statements.
	only_plain_invert(t, `package test

main :: proc() {
	if x{*} > 0 {
		foo()
		return
	}
	defer bar()
	baz()
}
`)
}

// Inverting twice gives the input back, or expected when a normalisation applies.
expect_invert_round_trip :: proc(t: ^testing.T, main: string, expected := "") {
	source := test.Source{main = main, config = {enable_code_action_invert_if = true}}
	if expected == "" {
		test.expect_action_round_trip(t, &source, {INVERT_IF_ACTION, INVERT_IF_ACTION})
	} else {
		test.expect_action_chain(t, &source, {INVERT_IF_ACTION, INVERT_IF_ACTION}, expected)
	}
}

expect_inverted :: proc(t: ^testing.T, main, expected: string) {
	source := test.Source{main = main, config = {enable_code_action_invert_if = true}}
	test.expect_action_applied(t, &source, INVERT_IF_ACTION, expected)
	expect_invert_round_trip(t, main)
}

@(test)
invert_if_keeps_comments :: proc(t: ^testing.T) {
	expect_inverted(t, `package test

main :: proc() {
	if {*}x > 0 {
		// leading
		foo() // trailing
		bar()
		// end of block
	} else {
		// only a comment
	}
}
`, `package test

main :: proc() {
	if x <= 0 {
		// only a comment
	} else {
		// leading
		foo() // trailing
		bar()
		// end of block
	}
}
`)
}

@(test)
invert_if_do_body :: proc(t: ^testing.T) {
	main := `package test

main :: proc() {
	if {*}x > 0 do foo()
}
`
	source := test.Source{main = main, config = {enable_code_action_invert_if = true}}
	test.expect_action_applied(t, &source, INVERT_IF_ACTION, `package test

main :: proc() {
	if x <= 0 {
	} else {
		foo()
	}
}
`)
	expect_invert_round_trip(t, main, `package test

main :: proc() {
	if x > 0 {
		foo()
	}
}
`)
}

@(test)
invert_if_else_do :: proc(t: ^testing.T) {
	main := `package test

main :: proc() {
	if {*}x > 0 {
		foo()
	} else do bar()
}
`
	source := test.Source{main = main, config = {enable_code_action_invert_if = true}}
	test.expect_action_applied(t, &source, INVERT_IF_ACTION, `package test

main :: proc() {
	if x <= 0 {
		bar()
	} else {
		foo()
	}
}
`)
	expect_invert_round_trip(t, main, `package test

main :: proc() {
	if x > 0 {
		foo()
	} else {
		bar()
	}
}
`)
}

@(test)
invert_if_space_indentation :: proc(t: ^testing.T) {
	expect_inverted(t, `package test

main :: proc() {
    if {*}x > 0 {
        foo()
    }
}
`, `package test

main :: proc() {
    if x <= 0 {
    } else {
        foo()
    }
}
`)
}

@(test)
invert_if_chain_round_trip :: proc(t: ^testing.T) {
	expect_inverted(t, `package test

main :: proc() {
	if {*}x > 0 {
		foo()
	} else if x < 0 {
		bar()
	} else {
		baz()
	}
}
`, `package test

main :: proc() {
	if x <= 0 {
		if x < 0 {
			bar()
		} else {
			baz()
		}
	} else {
		foo()
	}
}
`)
	expect_invert_round_trip(t, `package test

main :: proc() {
	if {*}x > 0 {
		foo()
	} else if x < 0 {
		bar()
	}
}
`)
}

@(test)
invert_if_init_and_label :: proc(t: ^testing.T) {
	expect_inverted(t, `package test

main :: proc() {
	if {*}v, ok := m[k]; ok {
		foo(v)
	}
}
`, `package test

main :: proc() {
	if v, ok := m[k]; !ok {
	} else {
		foo(v)
	}
}
`)
	expect_inverted(t, `package test

main :: proc() {
	lbl: if {*}x > 0 {
		foo()
		break lbl
	}
}
`, `package test

main :: proc() {
	lbl: if x <= 0 {
	} else {
		foo()
		break lbl
	}
}
`)
}

@(test)
invert_if_condition_forms :: proc(t: ^testing.T) {
	forms := [][2]string {
		{"!x", "x"},
		{"a && b", "!(a && b)"},
		{"a || b", "!(a || b)"},
		{"!(a && b)", "a && b"},
		{"x in set", "x not_in set"},
		{"a < b", "a >= b"},
		{"cond()", "!cond()"},
		{"(a == b)", "(a != b)"},
		{"p == nil", "p != nil"},
		{"ok", "!ok"},
	}
	for form in forms {
		main := strings.concatenate({`package test

main :: proc() {
	if {*}`, form[0], ` {
		foo()
	}
}
`}, context.temp_allocator)
		expected := strings.concatenate({`package test

main :: proc() {
	if `, form[1], ` {
	} else {
		foo()
	}
}
`}, context.temp_allocator)
		expect_inverted(t, main, expected)
	}
}

@(test)
invert_if_round_trips_in_context :: proc(t: ^testing.T) {
	// Nested if, multi-line call, defer and continue in the body; when, for and switch around it.
	expect_invert_round_trip(t, `package test

main :: proc() {
	for x in 0 ..< 3 {
		when ODIN_OS == .Darwin {
			if {*}x > 0 {
				defer bar()
				if x > 1 {
					continue
				}
				foo(
					x,
				)
			}
		}
	}
}
`)
	expect_invert_round_trip(t, `package test

main :: proc() {
	switch x {
	case 1:
		if {*}x > 0 {
			foo()
			break
		}
		foo()
	}
}
`)
}

@(test)
invert_if_early_continue :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	for x in 0 ..< 3 {
		foo()
		if {*}x > 0 {
			bar()
		}
	}
}
`,
		config = {enable_code_action_invert_if = true},
	}
	test.expect_action_applied(t, &source, "Invert if (early continue)", `package test

main :: proc() {
	for x in 0 ..< 3 {
		foo()
		if x <= 0 {
			continue
		}
		bar()
	}
}
`)

	following := test.Source {
		main = `package test

main :: proc() {
	for {
		if {*}x > 0 {
			foo()
			continue
		}
		bar()
	}
}
`,
		config = {enable_code_action_invert_if = true},
	}
	test.expect_action_applied(t, &following, "Invert if (early continue)", `package test

main :: proc() {
	for {
		if x <= 0 {
			bar()
			continue
		}
		foo()
	}
}
`)

	only_exit := test.Source {
		main = `package test

main :: proc() {
	for h, i in hs {
		if {*}count(h) != 0 {
			continue
		}
		unordered_remove(&hs, i)
	}
}
`,
		config = {enable_code_action_invert_if = true},
	}
	test.expect_action_applied(t, &only_exit, "Invert if (early continue)", `package test

main :: proc() {
	for h, i in hs {
		if count(h) == 0 {
			unordered_remove(&hs, i)
		}
	}
}
`)
}

@(test)
invert_if_early_break :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	switch x {
	case 1:
		if {*}x > 0 {
			foo()
		}
	case:
		bar()
	}
}
`,
		config = {enable_code_action_invert_if = true},
	}
	test.expect_action_applied(t, &source, "Invert if (early break)", `package test

main :: proc() {
	switch x {
	case 1:
		if x <= 0 {
			break
		}
		foo()
	case:
		bar()
	}
}
`)
}

@(test)
invert_if_early_exit_not_offered :: proc(t: ^testing.T) {
	fallthrough_case := test.Source {
		main = `package test

main :: proc() {
	switch x {
	case 1:
		if {*}x > 0 {
			foo()
		}
		fallthrough
	case:
		bar()
	}
}
`,
		config = {enable_code_action_invert_if = true},
	}
	test.expect_action_missing(t, &fallthrough_case, "Invert if (early break)")

	not_last := test.Source {
		main = `package test

main :: proc() {
	for {
		if {*}x > 0 {
			foo()
		}
		bar()
	}
}
`,
		config = {enable_code_action_invert_if = true},
	}
	test.expect_action_missing(t, &not_last, "Invert if (early continue)")
}
