package tests

import "core:testing"

import test "src:testing"

// An index expression in an earlier statement must not decide the type of a later implicit selector.
@(test)
file_resolve_index_does_not_leak_into_later_return :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Kind :: enum { A{*}, B }
get :: proc(m: map[string]int) -> Kind {
	if m["a"] == 1 {}
	return .A
}
`,
	}
	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 2, character = 15}, end = {line = 2, character = 16}}},
			{range = {start = {line = 5, character = 9}, end = {line = 5, character = 10}}},
		},
	)
}

// The initializer of a global resolves against globals only, so a local of the procedure that names the global
// does not hide the global `a` that the initializer passes.
@(test)
file_resolve_global_initializer_ignores_locals :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct { field{*}: int }
make_int :: proc(v: int) -> S { return {} }
make_f32 :: proc(v: f32) -> S { return {} }
g :: proc{make_int, make_f32}
use :: proc() {
	a: string
	_ = G.field
}
a: int
G := g(a)
`,
	}
	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 2, character = 14}, end = {line = 2, character = 19}}},
			{range = {start = {line = 8, character = 7}, end = {line = 8, character = 12}}},
		},
	)
}
