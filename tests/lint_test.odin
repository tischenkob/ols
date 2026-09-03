package tests

import "core:testing"

import test "src:testing"

@(test)
lint_self_assignment :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

P :: struct {
	x: int,
}

f :: proc(y: int) -> int {
	return y
}

main :: proc() {
	x := 1
	y := 2
	p: P
	x = x
	p.x = p.x
	x = y
	x, y = y, x
	x = f(x)
	x += x
}
`,
		config = {enable_lint_self_assignment = true},
	}

	test.expect_lint_diagnostics(t, &source, {{14, "self-assignment"}, {15, "self-assignment"}})
}

@(test)
lint_identical_branches :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(c: bool) -> int {
	x := 0
	if c {
		x = 1
	} else {
		x = 1
	}
	if c {
		x = 1
	} else {
		x = 2
	}
	if c {
		x = 1
	} else if !c {
		x = 1
	}
	x = c ? 3 : 3
	x = c ? 3 : 4
	return x
}
`,
		config = {enable_lint_identical_branches = true},
	}

	test.expect_lint_diagnostics(t, &source, {{4, "identical-branches"}, {19, "identical-branches"}})
}

@(test)
lint_unreachable_code :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(c: bool) -> int {
	if c {
		return 1
	}
	for {
		if c {
			break
		}
		continue
		_ = c
	}
	switch c {
	case true:
		panic("no")
		return 2
		return 3
	}
	return 0
	return 1
}
`,
		config = {enable_lint_unreachable_code = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{{20, "unreachable-code"}, {11, "unreachable-code"}, {16, "unreachable-code"}},
	)
}

@(test)
lint_unreachable_code_range :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() -> int {
	return 0
	a := 1
	b := 2
	return a + b
}
`,
		config = {enable_lint_unreachable_code = true},
	}

	test.expect_lint_diagnostics(t, &source, {{4, "unreachable-code"}})
}

@(test)
lint_float_equality :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

P :: struct {
	x: f32,
	n: int,
}

f :: proc(a, b: f32, i, j: int, p: P) -> bool {
	r := a == b
	r = i == j
	r = i != 1
	r = i == 1.5
	r = p.x != p.x
	r = p.n == p.n
	r = a < b
	return r
}
`,
		config = {enable_lint_float_equality = true},
	}

	test.expect_lint_diagnostics(t, &source, {{8, "float-equality"}, {11, "float-equality"}, {12, "float-equality"}})
}

@(test)
lint_disabled :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: f32) -> bool {
	x := 1
	x = x
	if a == 1.0 {
		return true
	} else {
		return true
	}
	return false
	return false
}
`,
	}

	test.expect_lint_diagnostics(t, &source, {})
}
