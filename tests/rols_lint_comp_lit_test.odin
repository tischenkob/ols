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

@(test)
lint_struct_literal_cases :: proc(t: ^testing.T) {
	cases := []Lint_Case {
		{
			"a nested literal with its own type",
			`package test

Inner :: struct {
	a: int,
}

Outer :: struct {
	inner: Inner,
}

f :: proc() -> Outer {
	return Outer{inner = Inner{a = 1, a = 2}}
}
`,
			{{11, "duplicate-field"}},
		},
		{
			"an anonymous struct literal",
			`package test

f :: proc() {
	_ = struct {
		a: int,
	}{a = 1, a = 2}
}
`,
			{{5, "duplicate-field"}},
		},
		{
			"enum-indexed array keys are not field names",
			`package test

E :: enum {
	A,
	B,
}

f :: proc() {
	_ = [E]int{.A = 1, .A = 2, .B = 3}
}
`,
			{},
		},
		{
			"map keys are not field names",
			`package test

f :: proc() {
	_ = map[string]int{"a" = 1, "a" = 2}
}
`,
			{},
		},
		{
			"a struct from another package",
			`package test

import "other"

f :: proc() -> other.Point {
	return other.Point{x = 1, z = 2}
}
`,
			{{5, "unknown-field"}},
		},
		{
			"a bit_field literal",
			`package test

Flags :: bit_field u8 {
	on: bool | 1,
}

f :: proc() -> Flags {
	return Flags{on = true, on = false}
}
`,
			{{7, "duplicate-field"}},
		},
	}

	expect_lint_cases(
		t,
		cases,
		{enable_lint_struct_literal = true},
		{{pkg = "other", source = `package other
Point :: struct {
	x: int,
	y: int,
}
`}},
	)
}
