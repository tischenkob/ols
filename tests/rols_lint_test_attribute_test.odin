package tests

import "core:testing"

import test "src:testing"

@(test)
lint_missing_test_attribute :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "core:testing"

forgot :: proc(t: ^testing.T) {
}

@(test)
kept :: proc(t: ^testing.T) {
}

helper :: proc(t: ^testing.T, name: string) {
}

main :: proc() {
	inner :: proc(t: ^testing.T) {
	}
}
`,
		config = {enable_lint_test_attribute = true},
	}

	test.expect_lint_diagnostics(t, &source, {{4, "missing-test-attribute"}})
}

@(test)
lint_test_signature :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "core:testing"

@(test)
no_param :: proc() {
}

@(test)
returns :: proc(t: ^testing.T) -> bool {
	return true
}

@(test)
fine :: proc(t: ^testing.T) {
}
`,
		config = {enable_lint_test_attribute = true},
	}

	test.expect_lint_diagnostics(t, &source, {{5, "test-signature"}, {9, "test-signature"}})
}

@(test)
lint_fix_missing_test_attribute :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "core:testing"

for{*}got :: proc(t: ^testing.T) {
}
`,
		config = {enable_lint_test_attribute = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Add @(test)",
		`package test

import "core:testing"

@(test)
forgot :: proc(t: ^testing.T) {
}
`,
	)
}

@(test)
lint_test_attribute_cases :: proc(t: ^testing.T) {
	cases := []Lint_Case {
		{
			"the parameter name does not matter",
			`package test

import "core:testing"

@(test)
named :: proc(tt: ^testing.T) {
}
`,
			{},
		},
		{
			"an extra parameter",
			`package test

import "core:testing"

@(test)
extra :: proc(t: ^testing.T, n: int) {
}
`,
			{{5, "test-signature"}},
		},
		{
			"test and private in one attribute",
			`package test

import "core:testing"

@(test, private)
fine :: proc(t: ^testing.T) {
}
`,
			{},
		},
		{
			"an aliased testing import is not recognised",
			`package test

import t "core:testing"

forgot :: proc(x: ^t.T) {
}
`,
			{},
		},
	}

	expect_lint_cases(t, cases, {enable_lint_test_attribute = true})
}

@(test)
lint_fix_missing_test_attribute_private :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "core:testing"

@(private)
for{*}got :: proc(t: ^testing.T) {
}
`,
		config = {enable_lint_test_attribute = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Add @(test)",
		`package test

import "core:testing"

@(private)
@(test)
forgot :: proc(t: ^testing.T) {
}
`,
	)
}

@(test)
lint_fix_missing_test_attribute_twice :: proc(t: ^testing.T) {
	cases := []Fix_Twice {
		{
			"missing-test-attribute",
			"Add @(test)",
			`package test

import "core:testing"

for{*}got :: proc(t: ^testing.T) {
}
`,
			"@(test)",
		},
	}

	expect_fix_twice(t, cases, {enable_lint_test_attribute = true})
}
