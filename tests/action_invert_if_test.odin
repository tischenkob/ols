package tests

import "core:testing"

import test "src:testing"

INVERT_IF_ACTION :: "Invert if"
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
