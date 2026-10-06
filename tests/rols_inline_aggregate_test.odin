package tests

import "core:testing"

import test "src:testing"

// A poly parameter takes the inline struct type of a variable as T, not the argument expression or the variable
// name, although the variable's symbol is flagged `Anonymous`.
@(test)
hover_poly_pointer_param_of_inline_struct :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

foo :: proc(x: ^$T) -> T { return x^ }
main :: proc() {
	p: struct {
		a: int,
	}
	r{*} := foo(&p)
}
`,
	}
	test.expect_hover(t, &source, "test.r: struct {\n\ta: int,\n}")
}

@(test)
hover_poly_value_param_of_inline_struct :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

foo :: proc(x: $T) -> T { return x }
main :: proc() {
	p: struct {
		a: int,
	}
	r{*} := foo(p)
}
`,
	}
	test.expect_hover(t, &source, "test.r: struct {\n\ta: int,\n}")
}
