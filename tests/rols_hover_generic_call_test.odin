package tests

import "core:testing"

import test "src:testing"

// A poly-type argument leaves T unbound for picking a group member, but the result still takes its type, U.
@(test)
hover_local_from_generic_call_on_poly_argument :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

foo :: proc(x: $T) -> T { return x }

h :: proc(w: $U) {
	r := foo(w)
	r{*}
}
`,
	}

	test.expect_hover(t, &source, "test.r: U")
}
