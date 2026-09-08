package tests

import "core:testing"

import test "src:testing"

@(test)
lint_duplicate_field :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Point :: struct {
	x: int,
	y: int,
}

twice :: proc() -> Point {
	return Point{x = 1, y = 2, x = 3}
}

once :: proc() -> Point {
	return Point{x = 1, y = 2}
}

positional :: proc() -> Point {
	return Point{1, 2}
}

unknown_type :: proc() {
	_ := Missing{a = 1, a = 2}
}
`,
		config = {enable_lint_struct_literal = true},
	}

	test.expect_lint_diagnostics(t, &source, {{8, "duplicate-field"}, {20, "duplicate-field"}})
}

@(test)
lint_unknown_field :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Point :: struct {
	x: int,
	y: int,
}

Base :: struct {
	x: int,
}

Derived :: struct {
	using base: Base,
	y:          int,
}

Raw :: struct #raw_union {
	x: int,
	y: int,
}

Pair :: struct($T: typeid) {
	first: T,
}

bad :: proc() -> Point {
	return Point{x = 1, z = 2}
}

good :: proc() -> Point {
	return Point{x = 1, y = 2}
}

with_using :: proc() -> Derived {
	return Derived{x = 1, y = 2}
}

raw :: proc() -> Raw {
	return Raw{x = 1}
}

poly :: proc() -> Pair(int) {
	return Pair(int){first = 1}
}
`,
		config = {enable_lint_struct_literal = true},
	}

	test.expect_lint_diagnostics(t, &source, {{26, "unknown-field"}})
}
