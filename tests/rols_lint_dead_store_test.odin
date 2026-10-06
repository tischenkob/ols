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

@(test)
lint_dead_store_forms :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Point :: struct {
	x: int,
	y: int,
}

use :: proc(v: int) {}

make_int :: proc() -> int {
	return 1
}

branches :: proc(c: bool) {
	x: int
	if c {
		x = 1
	} else {
		x = 2
	}
	use(x)
}

guarded :: proc(c: bool) {
	x := 1
	if c {
		x = 2
	}
	use(x)
}

from_call :: proc() {
	x := make_int()
	x = 2
	use(x)
}

compound :: proc() {
	x := 1
	x += 1
	use(x)
}

through_index :: proc(ps: []Point) {
	ps[0].x = 1
}

through_pointer :: proc(ps: []^Point) {
	p := ps[0]
	p.x = 1
}
`,
		config = {enable_lint_dead_store = true},
	}

	// Stores in sibling branches, a conditional overwrite and `x += 1` all read the old value.
	// An index in the assigned chain and an element that is itself a pointer both write through.
	test.expect_lint_diagnostics(t, &source, {{32, "dead-store"}})
}

@(test)
dead_store_ignores_package_global :: proc(t: ^testing.T) {
	// Corpus: tina src/turn_frame_helper_for_test.odin:104, see docs/corpus-validation.md.
	source := test.Source {
		main = `package test

g: int
read_g :: proc() -> int { return g }
f :: proc() -> int {
	prev := g
	g = 1
	x := read_g()
	g = prev
	return x
}
`,
		config = {enable_lint_dead_store = true},
	}

	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
dead_store_ignores_named_result_read_by_bare_return :: proc(t: ^testing.T) {
	// Corpus: odin-godot godin/build_options.odin:17, see docs/corpus-validation.md.
	source := test.Source {
		main = `package test

parse :: proc(x: int) -> (ok: bool) {
	ok = false
	if x > 0 {
		return
	}
	ok = true
	return
}
`,
		config = {enable_lint_dead_store = true},
	}

	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
dead_store_ignores_pointer_escaped_into_struct :: proc(t: ^testing.T) {
	// Corpus: Skald scroll_test.odin:45, see docs/corpus-validation.md.
	source := test.Source {
		main = `package test

Holder :: struct { p: ^int }
read :: proc(h: ^Holder) -> int { return h.p^ }
f :: proc() -> int {
	x: int
	h := Holder{p = &x}
	x = 5
	a := read(&h)
	x = 6
	return a + read(&h)
}
`,
		config = {enable_lint_dead_store = true},
	}

	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
dead_store_reported_after_early_return :: proc(t: ^testing.T) {
	// A bare return reads only named results, and `&x` in another procedure is another variable.
	source := test.Source {
		main = `package test

use :: proc(v: int) {}
other :: proc() { x := 0; use((&x)^) }
f :: proc(c: bool) {
	x := 1
	if c { return }
	x = 2
	use(x)
}
`,
		config = {enable_lint_dead_store = true},
	}

	test.expect_lint_diagnostics(t, &source, {{5, "dead-store"}})
}

@(test)
dead_store_reported_when_name_is_only_an_index :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(items: []int) -> int {
	i := 1
	i = 2
	p := &items[i]
	return p^
}
`,
		config = {enable_lint_dead_store = true},
	}

	test.expect_lint_diagnostics(t, &source, {{3, "dead-store"}})
}

@(test)
dead_store_bare_return_reads_only_named_results :: proc(t: ^testing.T) {
	// A bare return reads the named result `r`, not the plain local `x`. A defer registered before a store may read it through an exit between the stores.
	source := test.Source {
		main = `package test

use :: proc(v: int) {}
plain :: proc(c: bool) {
	x: int
	x = 1
	if c { return }
	x = 2
	use(x)
}
named :: proc(c: bool) -> (r: int) {
	r = 1
	if c { return }
	r = 2
	return
}
deferred :: proc(c: bool) -> int {
	x: int
	defer if x > 0 { use(x) }
	x = 1
	if c { return 0 }
	x = 2
	return 1
}
late_defer :: proc(c: bool) -> int {
	x: int
	x = 1
	if c { return 0 }
	x = 2
	defer use(x)
	return 1
}
straight :: proc() {
	buf: int
	defer use(buf)
	buf = 1
	buf = 2
	use(buf)
}
`,
		config = {enable_lint_dead_store = true},
	}

	test.expect_lint_diagnostics(t, &source, {{5, "dead-store"}, {26, "dead-store"}, {35, "dead-store"}})
}

@(test)
dead_store_ignores_closed_or_shadowed_defer :: proc(t: ^testing.T) {
	// A defer in a block that closed before the store, or one that reads an outer x the store shadows, cannot read the store.
	// A shadowing declaration in a block that closed before the store leaves the defer reading it.
	source := test.Source {
		main = `package test

use :: proc(v: int) {}
closed_block :: proc(c: bool) -> int {
	x: int
	{ defer use(x) }
	x = 1
	if c { return 0 }
	x = 2
	return x
}
shadowed :: proc(c: bool) {
	x := 0
	defer use(x)
	{
		x := 0
		use(x)
		x = 1
		if c { return }
		x = 2
		use(x)
	}
}
closed_shadow :: proc(c: bool) {
	x := 0
	defer use(x)
	{
		x := 0
		use(x)
	}
	x = 1
	if c { return }
	x = 2
	use(x)
}
`,
		config = {enable_lint_dead_store = true},
	}

	test.expect_lint_diagnostics(t, &source, {{6, "dead-store"}, {17, "dead-store"}})
}
