package tests

import "core:testing"

import test "src:testing"

@(test)
lint_no_op_arithmetic :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(x: int) -> int {
	a := x
	b := a + 0
	b = 0 + a
	b = a - 0
	b = a * 1
	b = 1 * a
	b = a / 1
	b = a | 0
	b = a ~ 0
	b = a << 0
	b = a >> 0
	b = a % 1
	b = a & 0
	b = a * 0
	a += 0
	a *= 1
	a |= 0
	b = a + 1
	b = 1 + 1
	b = 0 - a
	a += 1
	return b
}
`,
		config = {enable_lint_no_op = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{
			{4, "no-op-arithmetic"},
			{5, "no-op-arithmetic"},
			{6, "no-op-arithmetic"},
			{9, "no-op-arithmetic"},
			{10, "no-op-arithmetic"},
			{11, "no-op-arithmetic"},
			{12, "no-op-arithmetic"},
			{13, "no-op-arithmetic"},
			{14, "no-op-arithmetic"},
			{15, "no-op-arithmetic"},
			{16, "no-op-arithmetic"},
			{17, "no-op-arithmetic"},
			{19, "no-op-arithmetic"},
		},
	)
}

@(test)
lint_fix_no_op_arithmetic :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(x: int) -> int {
	return x{*} + 0
}
`,
		config = {enable_lint_no_op = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Remove no-op arithmetic",
		`package test

f :: proc(x: int) -> int {
	return x
}
`,
	)
}

@(test)
lint_literal_division_zero :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(n: int) {
	a := 1 / 2
	b := 0x1 / 0x10
	c := 3 / 2
	d := 1.0 / 2
	e := 1 / 1
	g := 1 / n
	_, _, _, _, _, _ = a, b, c, d, e, g
}
`,
		config = {enable_lint_no_op = true},
	}

	test.expect_lint_diagnostics(t, &source, {{3, "literal-division-zero"}, {4, "literal-division-zero"}})
}

@(test)
lint_address_nil_compare :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(p: ^int) -> bool {
	x := 1
	r := &x == nil
	r = nil != &x
	r = p == nil
	r = &x == p
	return r
}
`,
		config = {enable_lint_no_op = true},
	}

	test.expect_lint_diagnostics(t, &source, {{4, "address-nil-compare"}, {5, "address-nil-compare"}})
}

@(test)
lint_empty_body :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

g :: proc() {}

f :: proc(n: int) {
	if n > 0 {
	}
	if n > 1 {
		// deliberate
	}
	if n > 2 {
		g()
	} else {
	}
	for i in 0 ..< n {
	}
	for j := 0; j < n; j += 1 {
	}
	for {
	}
	if n > 3 do g()
}
`,
		config = {enable_lint_no_op = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{{5, "empty-body"}, {12, "empty-body"}, {14, "empty-body"}, {16, "empty-body"}},
	)
}

@(test)
lint_append_no_values :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(xs: ^[dynamic]int) {
	append(xs)
	append(xs, 1)
	append_elem(xs)
	n := len(xs^)
	_ = n
}
`,
		config = {enable_lint_no_op = true},
	}

	test.expect_lint_diagnostics(t, &source, {{3, "append-no-values"}, {5, "append-no-values"}})
}

@(test)
lint_no_op_forms :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

g :: proc() {}

f :: proc(c: bool, i: int, a: []int, xs: ^[dynamic]int, s: []int) {
	r := &a[i] == nil
	if c {
	} else {
		g()
	}
	append(xs, ..s)
	_ = r
}
`,
		config = {enable_lint_no_op = true},
	}

	// A spread append passes values, so it is not an empty append.
	test.expect_lint_diagnostics(t, &source, {{5, "address-nil-compare"}, {6, "empty-body"}})
}

@(test)
lint_fix_no_op_arithmetic_decl :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(x: int) -> int {
	y := x{*} + 0
	return y
}
`,
		config = {enable_lint_no_op = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Remove no-op arithmetic",
		`package test

f :: proc(x: int) -> int {
	y := x
	return y
}
`,
	)
}

@(test)
lint_fix_no_op_arithmetic_nested :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(x: int) -> int {
	return (x{*} + 0) * 2
}
`,
		config = {enable_lint_no_op = true},
	}

	// Only the operation is replaced; the parentheses around it stay.
	test.expect_action_applied(
		t,
		&source,
		"Remove no-op arithmetic",
		`package test

f :: proc(x: int) -> int {
	return (x) * 2
}
`,
	)
}

@(test)
lint_fix_append_no_values :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(xs: ^[dynamic]int) {
	app{*}end(xs)
	append(xs, 1)
}
`,
		config = {enable_lint_no_op = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Remove append without values",
		`package test

f :: proc(xs: ^[dynamic]int) {
	append(xs, 1)
}
`,
	)
}
