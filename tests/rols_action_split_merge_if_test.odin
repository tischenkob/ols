package tests

import "core:testing"

import test "src:testing"

SPLIT_IF_ACTION :: "Split if"
MERGE_IF_ACTION :: "Merge nested if"

@(test)
action_split_if_basic :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := true, false
	{*}if a && b {
		foo()
	}
}
`,
		packages = {},
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_applied(t, &source, SPLIT_IF_ACTION, `package test

main :: proc() {
	a, b := true, false
	if a {
		if b {
			foo()
		}
	}
}
`)
}

@(test)
action_split_if_with_init :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	b := true
	{*}if x := foo(); x > 0 && b {
		bar(x)
	}
}
`,
		packages = {},
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_applied(t, &source, SPLIT_IF_ACTION, `package test

main :: proc() {
	b := true
	if x := foo(); x > 0 {
		if b {
			bar(x)
		}
	}
}
`)
}

@(test)
action_split_if_parenthesised_operands :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b, c := true, false, true
	{*}if (a) && (b || c) {
		foo()
	}
}
`,
		packages = {},
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_applied(t, &source, SPLIT_IF_ACTION, `package test

main :: proc() {
	a, b, c := true, false, true
	if a {
		if b || c {
			foo()
		}
	}
}
`)
}

@(test)
action_split_if_three_operands :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b, c := true, false, true
	{*}if a && b && c {
		foo()
	}
}
`,
		packages = {},
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_applied(t, &source, SPLIT_IF_ACTION, `package test

main :: proc() {
	a, b, c := true, false, true
	if a && b {
		if c {
			foo()
		}
	}
}
`)
}

@(test)
action_split_if_refused_with_else :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := true, false
	{*}if a && b {
		foo()
	} else {
		bar()
	}
}
`,
		packages = {},
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_missing(t, &source, SPLIT_IF_ACTION)
}

@(test)
action_split_if_refused_with_or :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := true, false
	{*}if a || b {
		foo()
	}
}
`,
		packages = {},
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_missing(t, &source, SPLIT_IF_ACTION)
}

@(test)
action_merge_if_basic :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := true, false
	{*}if a {
		if b {
			// keep me
			foo()

			bar()
		}
	}
}
`,
		packages = {},
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_applied(t, &source, MERGE_IF_ACTION, `package test

main :: proc() {
	a, b := true, false
	if a && b {
		// keep me
		foo()

		bar()
	}
}
`)
}

@(test)
action_merge_if_wraps_or :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b, c := true, false, true
	{*}if x := foo(); a {
		if b || c {
			bar(x)
		}
	}
}
`,
		packages = {},
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_applied(t, &source, MERGE_IF_ACTION, `package test

main :: proc() {
	a, b, c := true, false, true
	if x := foo(); a && (b || c) {
		bar(x)
	}
}
`)
}

@(test)
action_split_merge_if_both_offered :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b, c := true, false, true
	{*}if a && b {
		if c {
			foo()
		}
	}
}
`,
		packages = {},
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action(t, &source, {SPLIT_IF_ACTION, MERGE_IF_ACTION})
}

@(test)
action_merge_if_refused_two_statements :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := true, false
	{*}if a {
		if b {
			foo()
		}
		bar()
	}
}
`,
		packages = {},
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_missing(t, &source, MERGE_IF_ACTION)
}

@(test)
action_merge_if_refused_inner_else :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := true, false
	{*}if a {
		if b {
			foo()
		} else {
			bar()
		}
	}
}
`,
		packages = {},
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_missing(t, &source, MERGE_IF_ACTION)
}

@(test)
action_merge_if_refused_inner_init :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a := true
	{*}if a {
		if x := foo(); x > 0 {
			bar(x)
		}
	}
}
`,
		packages = {},
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_missing(t, &source, MERGE_IF_ACTION)
}

@(test)
action_merge_if_refused_comment_between_braces :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := true, false
	{*}if a {
		// why b matters
		if b {
			foo()
		}
	}
}
`,
		packages = {},
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_missing(t, &source, MERGE_IF_ACTION)
}

@(test)
action_split_merge_if_disabled :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := true, false
	{*}if a && b {
		if b {
			foo()
		}
	}
}
`,
		packages = {},
		config = {enable_code_action_split_merge_if = false},
	}

	test.expect_action_missing(t, &source, SPLIT_IF_ACTION)

	source2 := test.Source {
		main = `package test

main :: proc() {
	a, b := true, false
	{*}if a && b {
		if b {
			foo()
		}
	}
}
`,
		packages = {},
		config = {enable_code_action_split_merge_if = false},
	}

	test.expect_action_missing(t, &source2, MERGE_IF_ACTION)
}
