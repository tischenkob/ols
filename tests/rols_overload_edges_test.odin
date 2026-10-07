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
		packages = {},
		config = {enable_inlay_hints_params = true},
	}

	test.expect_inlay_hints(t, &source)
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
