package tests

import "core:testing"

import test "src:testing"

@(private = "file")
source :: proc(main: string) -> test.Source {
	return test.Source{main = main, config = {enable_lint_integer_range = true}}
}

@(test)
lint_shift_overflow :: proc(t: ^testing.T) {
	src := source(
		`package test

main :: proc() {
	a: u8 = 1
	b: i32 = 1
	c: uint = 1
	_ = a << 8
	_ = b >> 32
	_ = c << 64
	b <<= 40
	_ = a << 7
	_ = c >> 63
	b >>= 4
}
`,
	)

	test.expect_lint_diagnostics(
		t,
		&src,
		{{6, "shift-overflow"}, {7, "shift-overflow"}, {8, "shift-overflow"}, {9, "shift-overflow"}},
	)
}

@(test)
lint_unsigned_negative_compare :: proc(t: ^testing.T) {
	src := source(
		`package test

main :: proc() {
	u: u32 = 1
	i: int = 1
	_ = u == -1
	_ = u < -3
	_ = -1 != u
	_ = u < 0
	_ = u >= 0
	_ = 0 > u
	_ = i == -1
	_ = i < 0
	_ = u > 0
	_ = u == 3
}
`,
	)

	test.expect_lint_diagnostics(
		t,
		&src,
		{
			{5, "unsigned-negative-compare"},
			{6, "unsigned-negative-compare"},
			{7, "unsigned-negative-compare"},
			{8, "unsigned-negative-compare"},
			{9, "unsigned-negative-compare"},
			{10, "unsigned-negative-compare"},
		},
	)
}

@(test)
lint_integer_division_float :: proc(t: ^testing.T) {
	src := source(
		`package test

main :: proc() {
	a: int = 3
	b: int = 4
	f: f64 = 1
	_ = f64(a / b)
	_ = f32((a / b))
	_ = cast(f64)(a / b)
	_ = f64(1 / 2)
	_ = f64(a) / f64(b)
	_ = f64(a * b)
	_ = f / 2
}
`,
	)

	test.expect_lint_diagnostics(
		t,
		&src,
		{
			{6, "integer-division-float"},
			{7, "integer-division-float"},
			{8, "integer-division-float"},
			{9, "integer-division-float"},
		},
	)
}
