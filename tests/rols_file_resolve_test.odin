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

// A call through a procedure group that fails to resolve in one scope must not stay failed for a later scope.
// In `use` the local `a` hides the global that the initializer of `G` passes, so the call fails there. `G.inner.field`
// names the field of Inner, so it is no reference either way.
@(test)
file_resolve_failed_overload_is_not_cached :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Inner :: struct { field: int }
S :: struct { field{*}: int, inner: Inner }
make_int :: proc(v: int) -> S { return {} }
make_f32 :: proc(v: f32) -> S { return {} }
g :: proc{make_int, make_f32}
use :: proc() {
	a: string
	_ = G.inner.field
}
a: int
G := g(a)
main :: proc() {
	_ = G.field
}
`,
	}
	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 3, character = 14}, end = {line = 3, character = 19}}},
			{range = {start = {line = 14, character = 7}, end = {line = 14, character = 12}}},
		},
	)
}
