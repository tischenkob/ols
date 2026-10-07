package tests

import "core:testing"

import test "src:testing"

@(test)
hover_group_call_with_local_arrow_call_argument :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

one :: proc(a: int) -> (int, int) { return a, a }
two :: proc(a: string) -> int { return 0 }
g :: proc { one, two }

Obj :: struct {
	single: proc(o: ^Obj) -> int,
}

main :: proc() {
	x: ^Obj
	g{*}(x->single())
}
`,
	}

	test.expect_hover(t, &source, "test.g :: proc(a: int) -> (_: int, _: int)")
}

@(test)
hover_append_like_group_with_local_arrow_call_argument :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

push_elem :: proc(array: ^[dynamic]$E, arg: E) -> int { return 1 }
push_elems :: proc(array: ^[dynamic]$E, args: ..E) -> int { return 1 }
push :: proc { push_elem, push_elems }

Counter :: struct {
	count: proc(c: ^Counter) -> int,
}

main :: proc() {
	list: [dynamic]int
	w: ^Counter
	pu{*}sh(&list, w->count())
}
`,
	}

	test.expect_hover(t, &source, "test.push :: proc(array: ^[dynamic]$E, arg: E) -> int")
}

@(test)
completion_on_group_call_result_with_local_arrow_call_argument :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Result :: struct {
	value: int,
}

one :: proc(a: int) -> Result { return {} }
two :: proc(a: string) -> int { return 0 }
g :: proc { one, two }

Obj :: struct {
	single: proc(o: ^Obj) -> int,
}

main :: proc() {
	x: ^Obj
	g(x->single()).{*}
}
`,
	}

	test.expect_completion_labels(t, &source, ".", {"value"})
}

@(test)
hover_group_call_with_conversion_to_procedure_type :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Cb :: proc() -> (int, int)
f :: proc() -> (int, int) { return 1, 2 }
one :: proc(c: Cb) {}
two :: proc(c: Cb, n: int) {}
g :: proc { one, two }

main :: proc() {
	g{*}(Cb(f))
}
`,
	}

	test.expect_hover(t, &source, "test.g :: proc(c: Cb)")
}
