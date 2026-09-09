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
