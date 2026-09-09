package tests

import "core:testing"

import test "src:testing"

@(test)
lint_argument_count :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "other"

f :: proc(a: int, b: int) {}

g :: proc(a: int, b := 2) {}

pair :: proc(a, b: int) {}

variadic :: proc(a: int, rest: ..int) {}

poly :: proc(x: $T) {}

main :: proc() {
	f(1)
	f(1, 2)
	f(1, 2, 3)
	g()
	g(1)
	pair(1)
	variadic(1)
	poly(1)
	f(b = 2, a = 1)
	unknown(1)
	other.two(1)
	other.two(1, 2)
}
`,
		packages = {{pkg = "other", source = `package other
two :: proc(a: int, b: int) {}
`}},
		config = {enable_lint_call_arity = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{
			{15, "argument-count"},
			{17, "argument-count"},
			{18, "argument-count"},
			{20, "argument-count"},
			{25, "argument-count"},
		},
	)
}
