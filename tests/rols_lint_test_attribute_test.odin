#+feature dynamic-literals
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
	setup(t)
}

setup :: proc(t: ^testing.T) {
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
lint_missing_test_attribute_other_package :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import testing "other"

f :: proc(t: ^testing.T) {
}
`,
		packages = {{pkg = "other", source = `package other

T :: struct {}
`}},
		config = {enable_lint_test_attribute = true},
	}

	test.expect_lint_diagnostics(t, &source, {})
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
			"an aliased testing import",
			`package test

import t "core:testing"

forgot :: proc(x: ^t.T) {
}
`,
			{{4, "missing-test-attribute"}},
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
lint_fix_missing_test_attribute_aliased_import :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import tt "core:testing"

for{*}got :: proc(t: ^tt.T) {
}
`,
		config = {enable_lint_test_attribute = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Add @(test)",
		`package test

import tt "core:testing"

@(test)
forgot :: proc(t: ^tt.T) {
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

// The message spells the type the way this file names core:testing.
@(test)
lint_test_signature_message_names_core_testing :: proc(t: ^testing.T) {
	cases := [?]struct {
		source, message: string,
	} {
		{
			`package test

import "core:testing"

@(test)
bad :: proc() {
}
`,
			"@(test) procedures must be proc(t: ^testing.T)",
		},
		{
			`package test

import tt "core:testing"

@(test)
bad :: proc() {
}
`,
			"@(test) procedures must be proc(t: ^tt.T)",
		},
	}
	for c in cases {
		source := test.Source {
			main = c.source,
			config = {enable_lint_test_attribute = true},
		}
		test.expect_lint_diagnostics(t, &source, {{5, "test-signature"}}, {c.message})
	}
}

// Only `odin test` checks a @(test) signature, against core:testing. A file without that import may serve
// another runner, even one whose package is named `testing`.
@(test)
lint_test_signature_needs_core_testing_import :: proc(t: ^testing.T) {
	sources := [?]string {
		`package test

import testing "framework:test"

@(test)
bad :: proc(t: ^testing.T) {
}
`,
		`package test

import "framework:testing"

@(test)
bad :: proc(t: ^testing.T) {
}
`,
		`package test

@(test)
bad :: proc() -> bool {
	return true
}
`,
	}
	for main in sources {
		source := test.Source {
			main = main,
			config = {enable_lint_test_attribute = true},
		}
		test.expect_lint_diagnostics(t, &source, {})
	}
}

// Corpus: mirage examples/nebula/nebula_test.odin runs its tests with framework:playtest.
@(test)
lint_test_signature_allows_another_runner_t :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "framework:playtest"

@(test)
nebula_starts :: proc(t: ^playtest.T) {
}
`,
		packages = {{pkg = "playtest", source = `package playtest
T :: struct {
	failed: bool,
}
`}},
		collections = {"framework" = "test"},
		config = {enable_lint_test_attribute = true},
	}
	test.expect_lint_diagnostics(t, &source, {})
}
