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
action_split_merge_if_round_trip :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := true, false
	if {*}a && b {
		foo()
	}
}
`,
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_round_trip(t, &source, {SPLIT_IF_ACTION, MERGE_IF_ACTION})
}

@(test)
action_split_merge_if_round_trip_space_indent :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
    a, b := true, false
    if {*}a && b {
        foo()
    }
}
`,
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_round_trip(t, &source, {SPLIT_IF_ACTION, MERGE_IF_ACTION})
}

@(test)
action_split_merge_if_round_trip_empty_body :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := true, false
	if {*}a && b {
	}
}
`,
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_round_trip(t, &source, {SPLIT_IF_ACTION, MERGE_IF_ACTION})
}

@(test)
action_split_merge_if_round_trip_with_init :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	b := true
	if {*}x := foo(); x > 0 && b {
		bar(x)
	}
}
`,
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_round_trip(t, &source, {SPLIT_IF_ACTION, MERGE_IF_ACTION})
}

@(test)
action_split_merge_if_round_trip_or_operand :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b, c := true, false, true
	if {*}(a || b) && c {
		foo()
	}
}
`,
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_round_trip(t, &source, {SPLIT_IF_ACTION, MERGE_IF_ACTION})
}

@(test)
action_split_merge_if_round_trip_ternary_operand :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b, c, d := true, false, true, false
	if {*}a && (b ? c : d) {
		foo()
	}
}
`,
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_round_trip(t, &source, {SPLIT_IF_ACTION, MERGE_IF_ACTION})
}

@(test)
action_split_merge_if_round_trip_three_operands :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b, c := true, false, true
	if {*}a && b && c {
		foo()
	}
}
`,
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_round_trip(t, &source, {SPLIT_IF_ACTION, SPLIT_IF_ACTION, MERGE_IF_ACTION, MERGE_IF_ACTION})
}

@(test)
action_split_if_three_operands_twice :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b, c := true, false, true
	if {*}a && b && c {
		foo()
	}
}
`,
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_chain(t, &source, {SPLIT_IF_ACTION, SPLIT_IF_ACTION}, `package test

main :: proc() {
	a, b, c := true, false, true
	if a {
		if b {
			if c {
				foo()
			}
		}
	}
}
`)
}

@(test)
action_merge_if_three_deep_twice :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b, c := true, false, true
	if {*}a {
		if b {
			if c {
				foo()
			}
		}
	}
}
`,
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_chain(t, &source, {MERGE_IF_ACTION, MERGE_IF_ACTION}, `package test

main :: proc() {
	a, b, c := true, false, true
	if a && b && c {
		foo()
	}
}
`)
}

@(test)
action_merge_split_if_round_trip_inner_or :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b, c := true, false, true
	if {*}a {
		if b || c {
			foo()
		}
	}
}
`,
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_round_trip(t, &source, {MERGE_IF_ACTION, SPLIT_IF_ACTION})
}

@(test)
action_merge_split_if_round_trip_outer_or :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b, c := true, false, true
	if {*}a || b {
		if c {
			foo()
		}
	}
}
`,
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_round_trip(t, &source, {MERGE_IF_ACTION, SPLIT_IF_ACTION})
}

@(test)
action_split_if_refused_or_at_top_level :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b, c := true, false, true
	{*}if a && b || c {
		foo()
	}
}
`,
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_missing(t, &source, SPLIT_IF_ACTION)
}

@(test)
action_merge_if_refused_outer_else :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := true, false
	{*}if a {
		if b {
			foo()
		}
	} else {
		bar()
	}
}
`,
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_missing(t, &source, MERGE_IF_ACTION)
}

LABELLED_IF :: `package test

main :: proc() {
	a, b := true, false
	loop: {*}if a && b {
		if b {
			break loop
		}
	}
}
`

@(test)
action_split_merge_if_refused_label :: proc(t: ^testing.T) {
	source := test.Source {
		main   = LABELLED_IF,
		config = {enable_code_action_split_merge_if = true},
	}
	test.expect_action_missing(t, &source, SPLIT_IF_ACTION)

	source2 := test.Source {
		main   = LABELLED_IF,
		config = {enable_code_action_split_merge_if = true},
	}
	test.expect_action_missing(t, &source2, MERGE_IF_ACTION)
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

@(test)
action_split_if_refused_do_body :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := true, false
	{*}if a && b do foo()
}
`,
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_missing(t, &source, SPLIT_IF_ACTION)
}

@(test)
action_merge_if_refused_do_outer_body :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := true, false
	{*}if a do if b {
		foo()
	}
}
`,
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_missing(t, &source, MERGE_IF_ACTION)
}

@(test)
action_merge_if_refused_do_inner_body :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := true, false
	{*}if a {
		if b do foo()
	}
}
`,
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_missing(t, &source, MERGE_IF_ACTION)
}
