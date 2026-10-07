package tests

import "core:testing"

import test "src:testing"

// While `g(1, )` is being typed, the whole-file resolve keeps the member that takes two arguments.
@(test)
inlay_hints_overload_keeps_member_after_trailing_comma :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

		f1 :: proc(s: string) {}
		f2 :: proc(a: int, b: int) {}
		g :: proc { f1, f2 }

		main :: proc() {
			g([[a = ]]1, )
		}
		`,
		config = {enable_inlay_hints_params = true},
	}

	test.expect_inlay_hints(t, &source)
}

// The comma that ends the last argument of a multi-line call is no argument being typed, so the whole-file resolve
// still drops `two`, which needs two arguments, and `b_field` is not referenced through it.
@(test)
file_resolve_multi_line_call_with_trailing_comma_drops_members_that_need_more_arguments :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

A :: struct { a_field: int }
B :: struct { b_field{*}: int }
one :: proc(a: Missing) -> A { return {} }
two :: proc(a, b: int) -> B { return {} }
g :: proc { one, two }
main :: proc() {
	_ = g(
		1,
	).b_field
}
`,
	}
	test.expect_reference_locations(
		t,
		&source,
		{{range = {start = {line = 3, character = 14}, end = {line = 3, character = 21}}}},
	)
}

// A poly-type argument does not make tied completion offer the values of a member outside the tie.
@(test)
completion_overload_tie_with_poly_argument_offers_tied_members_only :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

E1 :: enum { A, B }
E2 :: enum { A, C }
E3 :: enum { D }
f1 :: proc(v: int, e: E1) {}
f2 :: proc(v: int, e: E2) {}
f3 :: proc(v: int, e: E3, x := 0) {}
g :: proc { f1, f2, f3 }
h :: proc(v: $T) {
	g(v, .{*})
}
`,
	}
	test.expect_completion_labels(t, &source, ".", {"A", "B", "C"}, {"D"})
}

// Signature help in a tied call lists every tied member when another argument does not resolve.
@(test)
signature_help_overload_tie_with_unresolved_argument_lists_every_member :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

E1 :: enum { A, B }
E2 :: enum { A, C }
f1 :: proc(e: E1, p: []u8) {}
f2 :: proc(e: E2, p: ^int) {}
g :: proc { f1, f2 }
main :: proc() {
	g(.A, n{*})
}
`,
	}
	test.expect_signature_labels(t, &source, {"test.f1 :: proc(e: E1, p: []u8)", "test.f2 :: proc(e: E2, p: ^int)"})
}

// A poly-type argument binds a generic member's poly parameter, so the enum argument picks the member.
@(test)
hover_overload_generic_members_with_poly_argument :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

E1 :: enum { A, B }
f1 :: proc(v: $T, e: E1) {}
f2 :: proc(v: $T, s: string) {}
g :: proc { f1, f2 }
h :: proc(v: $T) {
	{*}g(v, .A)
}
`,
	}
	test.expect_hover(t, &source, "test.g :: proc(v: $T, e: E1)")
}

// Completion in a tied call with a poly-type argument offers the values of the generic members.
@(test)
completion_overload_generic_members_with_poly_argument :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

E1 :: enum { A, B }
E2 :: enum { A, C }
f1 :: proc(v: $T, e: E1) {}
f2 :: proc(v: $T, e: E2) {}
g :: proc { f1, f2 }
h :: proc(v: $T) {
	g(v, .{*})
}
`,
	}
	test.expect_completion_labels(t, &source, ".", {"A", "B", "C"}, {})
}
