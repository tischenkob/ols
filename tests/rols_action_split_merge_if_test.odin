package tests

import "core:strings"
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

	test.expect_action_applied(
		t,
		&source,
		SPLIT_IF_ACTION,
		`package test

main :: proc() {
	a, b := true, false
	if a {
		if b {
			foo()
		}
	}
}
`,
	)
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

	test.expect_action_applied(
		t,
		&source,
		SPLIT_IF_ACTION,
		`package test

main :: proc() {
	b := true
	if x := foo(); x > 0 {
		if b {
			bar(x)
		}
	}
}
`,
	)
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

	test.expect_action_applied(
		t,
		&source,
		SPLIT_IF_ACTION,
		`package test

main :: proc() {
	a, b, c := true, false, true
	if a {
		if b || c {
			foo()
		}
	}
}
`,
	)
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

	test.expect_action_applied(
		t,
		&source,
		SPLIT_IF_ACTION,
		`package test

main :: proc() {
	a, b, c := true, false, true
	if a && b {
		if c {
			foo()
		}
	}
}
`,
	)
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

	test.expect_action_applied(
		t,
		&source,
		MERGE_IF_ACTION,
		`package test

main :: proc() {
	a, b := true, false
	if a && b {
		// keep me
		foo()

		bar()
	}
}
`,
	)
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

	test.expect_action_applied(
		t,
		&source,
		MERGE_IF_ACTION,
		`package test

main :: proc() {
	a, b, c := true, false, true
	if x := foo(); a && (b || c) {
		bar(x)
	}
}
`,
	)
}

// Odin rejects an unparenthesised `or_return` operand of a binary expression.
@(test)
action_merge_if_wraps_or_return :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() -> (bool, bool) {
	return true, false
}

g :: proc(a: bool) -> (err: bool) {
	{*}if a {
		if f() or_return {
			return
		}
	}
	return
}
`,
		packages = {},
		config = {enable_code_action_split_merge_if = true},
	}

	test.expect_action_applied(
		t,
		&source,
		MERGE_IF_ACTION,
		`package test

f :: proc() -> (bool, bool) {
	return true, false
}

g :: proc(a: bool) -> (err: bool) {
	if a && (f() or_return) {
		return
	}
	return
}
`,
	)
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

	test.expect_action_chain(
		t,
		&source,
		{SPLIT_IF_ACTION, SPLIT_IF_ACTION},
		`package test

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
`,
	)
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

	test.expect_action_chain(
		t,
		&source,
		{MERGE_IF_ACTION, MERGE_IF_ACTION},
		`package test

main :: proc() {
	a, b, c := true, false, true
	if a && b && c {
		foo()
	}
}
`,
	)
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
		main = LABELLED_IF,
		config = {enable_code_action_split_merge_if = true},
	}
	test.expect_action_missing(t, &source, SPLIT_IF_ACTION)

	source2 := test.Source {
		main = LABELLED_IF,
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

SPLIT_OR_ELSE_IF :: "Split || into else-if"
SPLIT_OR_SEPARATE :: "Split || into separate ifs"

// The statements go inside a procedure body, so each test shows only the code that matters.
split_or_source :: proc(stmts: string, enabled := true) -> test.Source {
	return test.Source {
		main = strings.concatenate({"package test\n\nmain :: proc() {\n", stmts, "}\n"}, context.temp_allocator),
		packages = {},
		config = {enable_code_action_split_merge_if = enabled},
	}
}

expect_split_or :: proc(t: ^testing.T, title, stmts, expected: string) {
	source := split_or_source(stmts)
	want := strings.concatenate({"package test\n\nmain :: proc() {\n", expected, "}\n"}, context.temp_allocator)
	test.expect_action_applied(t, &source, title, want)
}

expect_no_split_or :: proc(t: ^testing.T, title, stmts: string, enabled := true) {
	source := split_or_source(stmts, enabled)
	test.expect_action_missing(t, &source, title)
}

@(test)
action_split_or_else_if_basic :: proc(t: ^testing.T) {
	expect_split_or(t, SPLIT_OR_ELSE_IF, `	{*}if a || b {
		foo()
	}
`, `	if a {
		foo()
	} else if b {
		foo()
	}
`)
}

@(test)
action_split_or_separate_basic :: proc(t: ^testing.T) {
	expect_split_or(t, SPLIT_OR_SEPARATE, `	{*}if a || b {
		foo()
	}
`, `	if a {
		foo()
	}
	if b {
		foo()
	}
`)
}

@(test)
action_split_or_disabled :: proc(t: ^testing.T) {
	stmts := "\t{*}if a || b {\n\t\tfoo()\n\t}\n"
	expect_no_split_or(t, SPLIT_OR_ELSE_IF, stmts, false)
	expect_no_split_or(t, SPLIT_OR_SEPARATE, stmts, false)
}

@(test)
action_split_or_at_first_operator :: proc(t: ^testing.T) {
	expect_split_or(
		t,
		SPLIT_OR_ELSE_IF,
		`	if a {*}|| b || c {
		foo()
	}
`,
		`	if a {
		foo()
	} else if b || c {
		foo()
	}
`,
	)
}

@(test)
action_split_or_at_second_operator :: proc(t: ^testing.T) {
	expect_split_or(
		t,
		SPLIT_OR_SEPARATE,
		`	if a || b {*}|| c {
		foo()
	}
`,
		`	if a || b {
		foo()
	}
	if c {
		foo()
	}
`,
	)
}

@(test)
action_split_or_off_operator_uses_last :: proc(t: ^testing.T) {
	expect_split_or(
		t,
		SPLIT_OR_ELSE_IF,
		`	if {*}a || b || c {
		foo()
	}
`,
		`	if a || b {
		foo()
	} else if c {
		foo()
	}
`,
	)
}

@(test)
action_split_or_keeps_else :: proc(t: ^testing.T) {
	stmts := `	{*}if a || b {
		foo()
	} else {
		bar()
	}
`
	expect_split_or(t, SPLIT_OR_ELSE_IF, stmts, `	if a {
		foo()
	} else if b {
		foo()
	} else {
		bar()
	}
`)
	expect_no_split_or(t, SPLIT_OR_SEPARATE, stmts)
}

@(test)
action_split_or_init_stays_on_first :: proc(t: ^testing.T) {
	stmts := `	{*}if x := f(); x || b {
		foo()
	}
`
	expect_split_or(t, SPLIT_OR_ELSE_IF, stmts, `	if x := f(); x {
		foo()
	} else if b {
		foo()
	}
`)
	expect_no_split_or(t, SPLIT_OR_SEPARATE, stmts)
}

@(test)
action_split_or_label_stays :: proc(t: ^testing.T) {
	stmts := `	l: {*}if a || b {
		break l
	}
`
	expect_split_or(t, SPLIT_OR_ELSE_IF, stmts, `	l: if a {
		break l
	} else if b {
		break l
	}
`)
	expect_no_split_or(t, SPLIT_OR_SEPARATE, stmts)
}

@(test)
action_split_or_repeats_from_else_if :: proc(t: ^testing.T) {
	stmts := `	if a {
		foo()
	} else if {*}b || c {
		foo()
	} else {
		bar()
	}
`
	expect_split_or(
		t,
		SPLIT_OR_ELSE_IF,
		stmts,
		`	if a {
		foo()
	} else if b {
		foo()
	} else if c {
		foo()
	} else {
		bar()
	}
`,
	)
	expect_no_split_or(t, SPLIT_OR_SEPARATE, stmts)
}

@(test)
action_split_or_nested_if_in_body :: proc(t: ^testing.T) {
	expect_split_or(
		t,
		SPLIT_OR_SEPARATE,
		`	if x || y {
		{*}if a || b {
			foo()
		}
	}
`,
		`	if x || y {
		if a {
			foo()
		}
		if b {
			foo()
		}
	}
`,
	)
}

@(test)
action_split_or_do_body_becomes_block :: proc(t: ^testing.T) {
	expect_split_or(t, SPLIT_OR_ELSE_IF, `	{*}if a || b do foo()
`, `	if a {
		foo()
	} else if b {
		foo()
	}
`)
}

@(test)
action_split_or_brace_line_body :: proc(t: ^testing.T) {
	expect_split_or(t, SPLIT_OR_SEPARATE, `	{*}if a || b { foo() }
`, `	if a {
		foo()
	}
	if b {
		foo()
	}
`)
}

@(test)
action_split_or_empty_body :: proc(t: ^testing.T) {
	expect_split_or(t, SPLIT_OR_ELSE_IF, `	{*}if a || b {
	}
`, `	if a {
	} else if b {
	}
`)
}

@(test)
action_split_or_body_keeps_comments :: proc(t: ^testing.T) {
	expect_split_or(
		t,
		SPLIT_OR_ELSE_IF,
		`	{*}if a || b {
		// why
		foo()

		bar() // and this
	}
`,
		`	if a {
		// why
		foo()

		bar() // and this
	} else if b {
		// why
		foo()

		bar() // and this
	}
`,
	)
}

@(test)
action_split_or_crlf :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\r\n\r\nmain :: proc() {\r\n\t{*}if a || b {\r\n\t\tfoo()\r\n\t\tbar()\r\n\t}\r\n}\r\n",
		packages = {},
		config = {enable_code_action_split_merge_if = true},
	}
	test.expect_action_applied(
		t,
		&source,
		SPLIT_OR_ELSE_IF,
		"package test\r\n\r\nmain :: proc() {\r\n\tif a {\r\n\t\tfoo()\r\n\t\tbar()\r\n\t} else if b {\r\n\t\tfoo()\r\n\t\tbar()\r\n\t}\r\n}\r\n",
	)
}

@(test)
action_split_or_mixed_with_and :: proc(t: ^testing.T) {
	expect_split_or(
		t,
		SPLIT_OR_ELSE_IF,
		`	{*}if a && b || c {
		foo()
	}
`,
		`	if a && b {
		foo()
	} else if c {
		foo()
	}
`,
	)
}

@(test)
action_split_or_drops_parens :: proc(t: ^testing.T) {
	expect_split_or(
		t,
		SPLIT_OR_ELSE_IF,
		`	{*}if ((a) || (b)) {
		foo()
	}
`,
		`	if a {
		foo()
	} else if b {
		foo()
	}
`,
	)
}

@(test)
action_split_or_composite_literal_keeps_parens :: proc(t: ^testing.T) {
	expect_split_or(
		t,
		SPLIT_OR_ELSE_IF,
		`	{*}if (t == T{1}) || b {
		foo()
	}
`,
		`	if (t == T{1}) {
		foo()
	} else if b {
		foo()
	}
`,
	)
}

@(test)
action_split_or_composite_literal_gains_parens :: proc(t: ^testing.T) {
	expect_split_or(
		t,
		SPLIT_OR_ELSE_IF,
		`	{*}if (b || t == T{1}) {
		foo()
	}
`,
		`	if b {
		foo()
	} else if (t == T{1}) {
		foo()
	}
`,
	)
}

@(test)
action_split_or_separate_refused_escaping_parent :: proc(t: ^testing.T) {
	for stmts in ([]string{"\tfor x do {*}if a || b {\n\t\tfoo()\n\t}\n", "\tdefer {*}if a || b {\n\t\tfoo()\n\t}\n", "\tx = 1; {*}if a || b {\n\t\tfoo()\n\t}\n"}) {
		expect_no_split_or(t, SPLIT_OR_SEPARATE, stmts)
		source := split_or_source(stmts)
		test.expect_action(t, &source, {SPLIT_OR_ELSE_IF})
	}
}

@(test)
action_split_or_separate_in_case_clause :: proc(t: ^testing.T) {
	expect_split_or(
		t,
		SPLIT_OR_SEPARATE,
		`	switch x {
	case 1:
		{*}if a || b {
			foo()
		}
	}
`,
		`	switch x {
	case 1:
		if a {
			foo()
		}
		if b {
			foo()
		}
	}
`,
	)
}

@(test)
action_split_or_refused :: proc(t: ^testing.T) {
	for stmts in ([]string {
			// No top-level ||.
			"\t{*}if a && b {\n\t\tfoo()\n\t}\n",
			"\t{*}if a && (b || c) {\n\t\tfoo()\n\t}\n",
			// The cursor is in the body or the else clause.
			"\tif a || b {\n\t\t{*}foo()\n\t}\n",
			"\tif a || b do {*}foo()\n",
			"\tif a || b {\n\t\tfoo()\n\t} else {\n\t\t{*}bar()\n\t}\n",
			// A rebuilt part of the head holds a comment.
			"\t{*}if /* why */ a || b {\n\t\tfoo()\n\t}\n",
			"\t{*}if a /* why */ || b {\n\t\tfoo()\n\t}\n",
			"\t{*}if a || /* why */ b {\n\t\tfoo()\n\t}\n",
			"\t{*}if a || b /* why */ {\n\t\tfoo()\n\t}\n",
			"\t{*}if x := f(); /* why */ x || b {\n\t\tfoo()\n\t}\n",
			"\t{*}if (/* why */ a) || b {\n\t\tfoo()\n\t}\n",
			"\t{*}if (a\n\t\t|| b // why\n\t\t|| c) {\n\t\tfoo()\n\t}\n",
			"\t{*}if (a || c // why\n\t) {\n\t\tfoo()\n\t}\n",
			"\t{*}if (a && b #! why\n\t\t|| c) {\n\t\tfoo()\n\t}\n",
			"\t{*}if (x && y // why\n\t) || c {\n\t\tfoo()\n\t}\n",
			"\t{*}if (a || b && c // why\n\t) {\n\t\tfoo()\n\t}\n",
			// Odin rejects a label that a procedure declares twice.
			"\t{*}if a || b {\n\t\tl: for {\n\t\t\tbreak l\n\t\t}\n\t}\n",
		}) {
		expect_no_split_or(t, SPLIT_OR_ELSE_IF, stmts)
		expect_no_split_or(t, SPLIT_OR_SEPARATE, stmts)
	}
}

@(test)
action_split_or_label_in_nested_proc_is_fine :: proc(t: ^testing.T) {
	expect_split_or(
		t,
		SPLIT_OR_ELSE_IF,
		`	{*}if a || b {
		p := proc() {
			l: for {
				break l
			}
		}
	}
`,
		`	if a {
		p := proc() {
			l: for {
				break l
			}
		}
	} else if b {
		p := proc() {
			l: for {
				break l
			}
		}
	}
`,
	)
}

@(test)
action_split_or_multi_line_head_keeps_parens :: proc(t: ^testing.T) {
	expect_split_or(
		t,
		SPLIT_OR_ELSE_IF,
		"\t{*}if (a\n\t\t|| b\n\t\t|| c) {\n\t\tfoo()\n\t}\n",
		"\tif (a\n\t\t|| b) {\n\t\tfoo()\n\t} else if c {\n\t\tfoo()\n\t}\n",
	)
	expect_split_or(
		t,
		SPLIT_OR_SEPARATE,
		"\tif (a{*}\n\t\t|| b\n\t\t|| c) {\n\t\tfoo()\n\t}\n",
		"\tif (a\n\t\t|| b) {\n\t\tfoo()\n\t}\n\tif c {\n\t\tfoo()\n\t}\n",
	)
}

@(test)
action_split_or_multi_line_right_side_keeps_parens :: proc(t: ^testing.T) {
	expect_split_or(
		t,
		SPLIT_OR_ELSE_IF,
		"\tif (a\n\t\t{*}|| b\n\t\t|| c) {\n\t\tfoo()\n\t}\n",
		"\tif a {\n\t\tfoo()\n\t} else if (b\n\t\t|| c) {\n\t\tfoo()\n\t}\n",
	)
}

@(test)
action_split_or_slashes_in_string_are_fine :: proc(t: ^testing.T) {
	expect_split_or(
		t,
		SPLIT_OR_ELSE_IF,
		`	{*}if has_prefix(u, "http://") || b {
		foo()
	}
`,
		`	if has_prefix(u, "http://") {
		foo()
	} else if b {
		foo()
	}
`,
	)
}
