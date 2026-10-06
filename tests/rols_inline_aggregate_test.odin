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

// A poly value parameter takes a pointer to an inline struct as T, keeping the pointer.
@(test)
hover_poly_value_param_of_inline_struct_pointer :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

foo :: proc(x: $T) -> T { return x }
main :: proc() {
	p: struct {
		a: int,
	}
	r{*} := foo(&p)
}
`,
	}
	test.expect_hover(t, &source, "test.r: ^struct {\n\ta: int,\n}")
}

@(test)
hover_pointer_to_inline_struct :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	p: struct {
		a: int,
	}
	q{*} := &p
}
`,
	}
	test.expect_hover(t, &source, "test.q: ^struct {\n\ta: int,\n}")
}

// A copy of an inline struct variable has no type expression of its own, so T comes from the copied variable.
@(test)
hover_poly_param_of_inline_struct_copy :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

foo :: proc(v: $T) -> T { return v }
main :: proc() {
	p: struct {
		a: int,
	}
	x := p
	r{*} := foo(x)
}
`,
	}
	test.expect_hover(t, &source, "test.r: struct {\n\ta: int,\n}")
}

@(test)
completion_poly_result_of_inline_struct_copy :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

foo :: proc(v: $T) -> T { return v }
main :: proc() {
	p: struct {
		a: int,
	}
	x := p
	r := foo(x)
	r.{*}
}
`,
	}
	test.expect_completion_labels(t, &source, ".", {"a"})
}

@(test)
hover_poly_param_of_inline_union_copy :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

foo :: proc(v: $T) -> T { return v }
main :: proc() {
	p: union {
		int,
		f32,
	}
	x := p
	r{*} := foo(x)
}
`,
	}
	test.expect_hover(t, &source, "test.r: union {\n\tint,\n\tf32,\n}")
}

// A file-scope copy of an inline struct global keeps the inline type the same way.
@(test)
hover_poly_param_of_inline_struct_global_copy :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

foo :: proc(v: $T) -> T { return v }
g: struct {
	a: int,
}
g2 := g
main :: proc() {
	r{*} := foo(g2)
}
`,
	}
	test.expect_hover(t, &source, "test.r: struct {\n\ta: int,\n}")
}
