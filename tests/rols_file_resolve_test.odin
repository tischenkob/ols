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

// Only the whole-file resolve drops a group member that takes fewer arguments than the call passes. Completion
// keeps every member, as upstream does: the call resolves to both members, and a selector on it offers nothing.
// Dropping `one` there would offer `b_field`.
@(test)
completion_on_group_call_keeps_members_that_take_fewer_arguments :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

A :: struct { a_field: int }
B :: struct { b_field: int }
one :: proc(x: int) -> A { return {} }
two :: proc(x: int, y: int) -> B { return {} }
g :: proc{one, two}
main :: proc() {
	g(1, 2).{*}
}
`,
	}
	test.expect_completion_labels(t, &source, ".", {})
}

// An implicit selector on the left of a binary expression resolves against its own expression, not against the
// nested binary on the right that the walker popped before it.
@(test)
file_resolve_implicit_selector_beside_nested_binary :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Kind :: enum { X{*}, Y }
use :: proc(a, b: Kind) -> bool {
	return .X == a + b
}
`,
	}
	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 2, character = 15}, end = {line = 2, character = 16}}},
			{range = {start = {line = 4, character = 9}, end = {line = 4, character = 10}}},
		},
	)
}

// The whole-file resolve drops a group member that needs more arguments than the call passes. `one` fits but its
// parameter type does not resolve, so `g(1)` resolves to no member, and `b_field` is not referenced through `two`.
@(test)
file_resolve_group_call_drops_members_that_need_more_arguments :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

A :: struct { a_field: int }
B :: struct { b_field{*}: int }
one :: proc(a: Missing) -> A { return {} }
two :: proc(a, b: int) -> B { return {} }
g :: proc { one, two }
main :: proc() {
	_ = g(1).b_field
}
`,
	}
	test.expect_reference_locations(
		t,
		&source,
		{{range = {start = {line = 3, character = 14}, end = {line = 3, character = 21}}}},
	)
}

// A global and a procedure declared inside the same top-level `when` are separate declarations, so the
// initializer of `G` does not see the local `a` of `use`.
@(test)
hover_global_initializer_in_when_ignores_locals :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct { field: int }
make_int :: proc(v: int) -> S { return {} }
make_f32 :: proc(v: f32) -> S { return {} }
g :: proc{make_int, make_f32}
when true {
	use :: proc() {
		a: string
		_ = G.fi{*}eld
	}
	a: int
	G := g(a)
}
`,
	}
	test.expect_hover(t, &source, "S.field: int")
}
