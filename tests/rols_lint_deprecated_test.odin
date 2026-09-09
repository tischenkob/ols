package tests

import "core:testing"

import test "src:testing"

@(test)
lint_deprecated :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

@(deprecated="use g")
f :: proc() {}

g :: proc() {}

main :: proc() {
	g()
	f()
}
`,
		config = {enable_lint_deprecated = true},
	}

	test.expect_lint_diagnostics(t, &src, {{9, "deprecated"}})
}

@(test)
lint_deprecated_selector :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

import "old"

main :: proc() {
	old.keep()
	old.gone()
}
`,
		packages = {
			{pkg = "old", source = `package old
keep :: proc() {}
@(deprecated="use keep")
gone :: proc() {}
`},
		},
		config = {enable_lint_deprecated = true},
	}

	test.expect_lint_diagnostics(t, &src, {{6, "deprecated"}})
}
