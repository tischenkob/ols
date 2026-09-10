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
