package tests

import "core:testing"

import test "src:testing"

@(test)
lint_dead_store :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

use :: proc(v: int) {}

overwritten :: proc() {
	x := 1
	x = 2
	use(x)
}

read_between :: proc() {
	y := 1
	use(y)
	y = 2
	use(y)
}

addressed :: proc() {
	z := 1
	p := &z
	z = 2
	use(z)
	use(p^)
}

param :: proc(n: int) {
	n = 3
	use(n)
}
`,
		config = {enable_lint_dead_store = true},
	}

	test.expect_lint_diagnostics(t, &source, {{5, "dead-store"}, {25, "dead-store"}})
}

@(test)
lint_unused_copy_write :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Point :: struct {
	x: int,
	y: int,
}

show :: proc(p: Point) {}

from_index :: proc(ps: []Point) {
	p := ps[0]
	p.x = 1
}

from_map :: proc(m: map[string]Point) {
	v := m["a"]
	v.y = 2
}

from_range :: proc(ps: []Point) {
	for p in ps {
		p.x = 1
	}
	for &p in ps {
		p.x = 1
	}
}

read_after :: proc(ps: []Point) {
	p := ps[0]
	p.x = 1
	show(p)
}
`,
		config = {enable_lint_dead_store = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{{11, "unused-copy-write"}, {16, "unused-copy-write"}, {21, "unused-copy-write"}},
	)
}
