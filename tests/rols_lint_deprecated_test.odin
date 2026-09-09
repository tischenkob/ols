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

@(test)
lint_deprecated_cases :: proc(t: ^testing.T) {
	cases := []Lint_Case {
		{
			"a spaced message",
			`package test

@(deprecated = "use g")
f :: proc() {}

main :: proc() {
	f()
}
`,
			{{6, "deprecated"}},
		},
		{
			// Only a procedure of the open file carries the flag through the resolver.
			"an in-file deprecated type and constant",
			`package test

@(deprecated = "old")
Old_Type :: struct {}

@(deprecated = "old")
OLD :: 1

main :: proc() {
	x: Old_Type
	_ = x
	_ = OLD
}
`,
			{},
		},
		{
			"a deprecated type and constant from another package",
			`package test

import "old"

main :: proc() {
	x: old.Old_Type
	_ = x
	_ = old.OLD
}
`,
			{{5, "deprecated"}, {7, "deprecated"}},
		},
		{
			"taking the procedure as a value",
			`package test

@(deprecated = "use g")
f :: proc() {}

main :: proc() {
	p := f
	_ = p
}
`,
			{{6, "deprecated"}},
		},
		{
			"inside when false",
			`package test

@(deprecated = "use g")
f :: proc() {}

main :: proc() {
	when false {
		f()
	}
}
`,
			{{7, "deprecated"}},
		},
	}

	expect_lint_cases(
		t,
		cases,
		{enable_lint_deprecated = true},
		{{pkg = "old", source = `package old
@(deprecated="use Point")
Old_Type :: struct {}
@(deprecated="use LIMIT")
OLD :: 1
`}},
	)
}
