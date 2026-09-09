package tests

import "core:testing"

import test "src:testing"

@(test)
lint_identical_operands :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a, b: int, c, d: bool, x: f32, xs: []int) -> bool {
	r := a == a
	r = a != a
	r = a < a
	r = a - a > 0
	r = c && c
	r = c || d || c
	r = x == x
	r = 1 - 1 > 0
	r = a == b
	r = c && d
	r = xs[0] == xs[1]
	r = xs[a] == xs[a]
	return r
}
`,
		config = {enable_lint_bool_logic = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{
			{3, "identical-operands"},
			{4, "identical-operands"},
			{5, "identical-operands"},
			{6, "identical-operands"},
			{7, "identical-operands"},
			{8, "identical-operands"},
			{14, "identical-operands"},
		},
	)
}

@(test)
lint_bool_tautology :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: int, c: bool) -> bool {
	r := a != 1 || a != 2
	r = a == 1 && a == 2
	r = c || !c
	r = c && !c
	r = a == 1 || a == 2
	r = a != 1 && a != 2
	r = c || !r
	return r
}
`,
		config = {enable_lint_bool_logic = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{{3, "bool-tautology"}, {4, "bool-tautology"}, {5, "bool-tautology"}, {6, "bool-tautology"}},
	)
}

@(test)
lint_duplicate_condition :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Color :: enum {
	Red,
	Green,
}

f :: proc(a, b: int, col: Color) -> int {
	if a == 1 {
		return 1
	} else if a == 2 {
		return 2
	} else if a == 1 {
		return 3
	}
	if a == 1 {
		return 4
	}
	switch col {
	case .Red:
		return 5
	case .Green:
		return 6
	}
	switch a {
	case b:
		return 7
	case b:
		return 8
	}
	return 0
}
`,
		config = {enable_lint_bool_logic = true},
	}

	test.expect_lint_diagnostics(t, &source, {{12, "duplicate-condition"}, {27, "duplicate-condition"}})
}

@(test)
lint_bool_logic_forms :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	b: bool,
}

h :: proc() -> bool {
	return true
}

f :: proc(a: bool, x: int, s: S) -> bool {
	r := x < 5 && x > 10
	r = a && (a)
	r = h() && h()
	r = s.b && s.b
	r = !a || a
	return r
}
`,
		config = {enable_lint_bool_logic = true},
	}

	// `x < 5 && x > 10` needs range reasoning the lint does not do, and two calls may differ.
	test.expect_lint_diagnostics(
		t,
		&source,
		{{12, "identical-operands"}, {14, "identical-operands"}, {15, "bool-tautology"}},
	)
}
