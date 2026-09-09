package tests

import "core:testing"

import test "src:testing"

MERGE_CASES_ACTION :: "Merge with next case"
SPLIT_CASE_ACTION :: "Split case"

@(test)
action_merge_cases :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Color :: enum {
	Red,
	Green,
	Blue,
}

main :: proc() {
	c := Color.Red
	switch c {
	{*}case .Red:
		foo()
	case .Green:
		foo()
	case .Blue:
		bar()
	}
}
`,
		packages = {},
		config = {enable_code_action_merge_cases = true},
	}

	test.expect_action_applied(
		t,
		&source,
		MERGE_CASES_ACTION,
		`package test

Color :: enum {
	Red,
	Green,
	Blue,
}

main :: proc() {
	c := Color.Red
	switch c {
	case .Red, .Green:
		foo()
	case .Blue:
		bar()
	}
}
`,
	)

	differing := test.Source {
		main = `package test

Color :: enum {
	Red,
	Green,
	Blue,
}

main :: proc() {
	c := Color.Red
	switch c {
	{*}case .Red:
		foo()
	case .Green:
		bar()
	case .Blue:
		bar()
	}
}
`,
		packages = {},
		config = {enable_code_action_merge_cases = true},
	}

	test.expect_action_missing(t, &differing, MERGE_CASES_ACTION)
}

@(test)
action_split_case :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Color :: enum {
	Red,
	Green,
	Blue,
}

main :: proc() {
	c := Color.Red
	switch c {
	{*}case .Red, .Green:
		foo()
	case .Blue:
		bar()
	}
}
`,
		packages = {},
		config = {enable_code_action_merge_cases = true},
	}

	test.expect_action_applied(
		t,
		&source,
		SPLIT_CASE_ACTION,
		`package test

Color :: enum {
	Red,
	Green,
	Blue,
}

main :: proc() {
	c := Color.Red
	switch c {
	case .Red:
		foo()
	case .Green:
		foo()
	case .Blue:
		bar()
	}
}
`,
	)
}

@(private = "file")
cases_source :: proc(main: string) -> test.Source {
	return test.Source{main = main, config = {enable_code_action_merge_cases = true}}
}

@(test)
action_merge_cases_round_trip :: proc(t: ^testing.T) {
	three := cases_source(`package test

Color :: enum {
	Red,
	Green,
	Blue,
}

main :: proc() {
	c := Color.Red
	switch c {
	{*}case .Red, .Green, .Blue:
		foo()
	}
}
`)

	test.expect_action_round_trip(t, &three, {SPLIT_CASE_ACTION, MERGE_CASES_ACTION, MERGE_CASES_ACTION})

	ranges := cases_source(`package test

Color :: enum {
	Red,
	Green,
	Blue,
	Alpha,
	Beta,
}

main :: proc() {
	c := Color.Red
	#partial switch c {
	{*}case .Red ..= .Blue, .Beta:
		foo()
	}
}
`)

	test.expect_action_round_trip(t, &ranges, {SPLIT_CASE_ACTION, MERGE_CASES_ACTION})
}

@(test)
action_merge_cases_body_matching :: proc(t: ^testing.T) {
	// Bodies are compared with whitespace dropped, and the first body is the one kept.
	indentation := cases_source(`package test

Color :: enum {
	Red,
	Green,
}

main :: proc() {
	c := Color.Red
	switch c {
	{*}case .Red:
		foo()
	case .Green:
			foo()
	}
}
`)

	test.expect_action_applied(t, &indentation, MERGE_CASES_ACTION, `package test

Color :: enum {
	Red,
	Green,
}

main :: proc() {
	c := Color.Red
	switch c {
	case .Red, .Green:
		foo()
	}
}
`)

	// A comment is not part of a statement, so it neither blocks the merge nor survives it.
	commented := cases_source(`package test

Color :: enum {
	Red,
	Green,
}

main :: proc() {
	c := Color.Red
	switch c {
	{*}case .Red:
		foo()
	case .Green:
		foo() // green
	}
}
`)

	test.expect_action_applied(t, &commented, MERGE_CASES_ACTION, `package test

Color :: enum {
	Red,
	Green,
}

main :: proc() {
	c := Color.Red
	switch c {
	case .Red, .Green:
		foo()
	}
}
`)
}

@(test)
action_merge_cases_refusals :: proc(t: ^testing.T) {
	next_is_default := cases_source(`package test

main :: proc() {
	x := 1
	switch x {
	{*}case 1:
		foo()
	case:
		foo()
	}
}
`)

	test.expect_action_missing(t, &next_is_default, MERGE_CASES_ACTION)

	last_clause := cases_source(`package test

main :: proc() {
	x := 1
	switch x {
	case 1:
		foo()
	{*}case 2:
		foo()
	}
}
`)

	test.expect_action_missing(t, &last_clause, MERGE_CASES_ACTION)

	single_value := cases_source(`package test

main :: proc() {
	x := 1
	switch x {
	{*}case 1:
		foo()
	}
}
`)

	test.expect_action_missing(t, &single_value, SPLIT_CASE_ACTION)

	default_clause := cases_source(`package test

main :: proc() {
	x := 1
	switch x {
	case 1:
		foo()
	{*}case:
		bar()
	}
}
`)

	test.expect_action_missing(t, &default_clause, SPLIT_CASE_ACTION)

	// Type switches are not handled.
	type_switch := cases_source(`package test

main :: proc() {
	v: any
	switch t in v {
	{*}case int, string:
		foo()
	}
}
`)

	test.expect_action_missing(t, &type_switch, SPLIT_CASE_ACTION)
}

@(test)
action_merge_cases_refuses_fallthrough :: proc(t: ^testing.T) {
	// Merging would drop one run of the shared body for the first value.
	merge := cases_source(`package test

Color :: enum {
	Red,
	Green,
	Blue,
}

main :: proc() {
	c := Color.Red
	switch c {
	{*}case .Red:
		foo()
		fallthrough
	case .Green:
		foo()
		fallthrough
	case .Blue:
		bar()
	}
}
`)

	test.expect_action_missing(t, &merge, MERGE_CASES_ACTION)

	// Splitting would make the first value fall into its own copy of the body.
	split := cases_source(`package test

Color :: enum {
	Red,
	Green,
	Blue,
}

main :: proc() {
	c := Color.Red
	switch c {
	{*}case .Red, .Green:
		foo()
		fallthrough
	case .Blue:
		bar()
	}
}
`)

	test.expect_action_missing(t, &split, SPLIT_CASE_ACTION)
}
