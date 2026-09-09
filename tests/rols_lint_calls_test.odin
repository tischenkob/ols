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

@(test)
lint_call_arity_cases :: proc(t: ^testing.T) {
	cases := []Lint_Case {
		{
			"a procedure value is not checked",
			`package test

f :: proc(a: int, b: int) {}

main :: proc() {
	p := f
	p(1)
}
`,
			{},
		},
		{
			"a spread argument hides the count",
			`package test

f :: proc(a: int, b: int) {}

main :: proc(s: []int) {
	f(..s)
}
`,
			{},
		},
		{
			"a c_vararg foreign procedure",
			`package test

foreign import lib "system:c"

foreign lib {
	printf :: proc(format: cstring, #c_vararg args: ..any) -> i32 ---
}

main :: proc() {
	printf("a", 1, 2)
}
`,
			{},
		},
		{
			"an overloaded group",
			`package test

add_int :: proc(a, b: int) -> int {
	return a + b
}

add_f32 :: proc(a, b: f32) -> f32 {
	return a + b
}

add :: proc {
	add_int,
	add_f32,
}

main :: proc() {
	_ = add(1)
}
`,
			{},
		},
	}

	expect_lint_cases(t, cases, {enable_lint_call_arity = true})
}
