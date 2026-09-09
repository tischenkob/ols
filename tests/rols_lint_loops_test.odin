package tests

import "core:testing"

import test "src:testing"

@(test)
lint_loop_single_iteration :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(xs: []int) -> int {
	for x in xs {
		return x
	}
	for i := 0; i < 3; i += 1 {
		break
	}
	for x in xs {
		if x > 0 {
			continue
		}
		break
	}
	for x in xs {
		if x > 0 {
			return x
		}
	}
	return 0
}
`,
		config = {enable_lint_loops = true},
	}

	test.expect_lint_diagnostics(t, &source, {{3, "loop-single-iteration"}, {6, "loop-single-iteration"}})
}

@(test)
lint_loop_condition_constant :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

use :: proc(v: int) {}

g :: proc(n: int) {
	i := 0
	for i < n {
		use(i)
	}
	for i < n {
		i += 1
	}
}
`,
		config = {enable_lint_loops = true},
	}

	test.expect_lint_diagnostics(t, &source, {{6, "loop-condition-constant"}})
}

@(test)
lint_empty_loop :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

h :: proc() {
	for {}
	for i := 0; i < 3; i += 1 {}
	for {
		h()
	}
}
`,
		config = {enable_lint_loops = true},
	}

	test.expect_lint_diagnostics(t, &source, {{3, "empty-loop"}})
}

@(test)
lint_range_off_by_one :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

r :: proc(xs: []int) {
	for i in 0 ..= len(xs) {
	}
	for i in 0 ..< len(xs) + 1 {
	}
	for i in 0 ..< len(xs) {
	}
	for i in 0 ..= len(xs) - 1 {
	}
}
`,
		config = {enable_lint_loops = true},
	}

	test.expect_lint_diagnostics(t, &source, {{3, "range-off-by-one"}, {5, "range-off-by-one"}})
}

@(test)
lint_fix_range_off_by_one :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

r :: proc(xs: []int) {
	for i in 0 ..={*} len(xs) {
		use(i)
	}
}
`,
		config = {enable_lint_loops = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Use ..< instead of ..=",
		`package test

r :: proc(xs: []int) {
	for i in 0 ..< len(xs) {
		use(i)
	}
}
`,
	)
}

@(test)
lint_loops_forms :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

use :: proc(v: int) {}

bump :: proc(p: ^int) {
	p^ += 1
}

break_in_if :: proc(xs: []int) {
	for x in xs {
		if x > 0 {
			break
		}
	}
}

via_address :: proc(n: int) {
	i := 0
	for i < n {
		bump(&i)
	}
}

via_pointer :: proc(n: int, p: ^int) {
	for p^ < n {
		bump(p)
	}
}

ranges :: proc(s: string, xs: []int) {
	for i in 1 ..= len(xs) {
		use(i)
	}
	for i in 0 ..= len(xs) {
		use(i)
	}
	for c in 0 ..< len(s) + 1 {
		use(c)
	}
}
`,
		config = {enable_lint_loops = true},
	}

	// A conditional break does not end the first iteration, a call handed the loop variable by
	// pointer can change it, and a range starting past 0 stays within len.
	test.expect_lint_diagnostics(t, &source, {{33, "range-off-by-one"}, {36, "range-off-by-one"}})
}

@(test)
lint_fix_range_off_by_one_plus_one :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

r :: proc(s: string) {
	for i in 0 ..< len(s){*} + 1 {
		use(i)
	}
}
`,
		config = {enable_lint_loops = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Remove '+ 1' from the range end",
		`package test

r :: proc(s: string) {
	for i in 0 ..< len(s) {
		use(i)
	}
}
`,
	)
}

@(test)
lint_range_map_lookup :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Kind :: enum {
	A,
	B,
}

table: [Kind]map[string][dynamic]int

f :: proc(m: map[string][dynamic]int, sl: map[string][]int, fa: map[string][2]int, xs: [][]int, key: string) {
	for x in m[key] {
		_ = x
	}
	for x in table[.A][key] {
		_ = x
	}
	for x in fa[key] {
		_ = x
	}
	for x in sl[key] {
		_ = x
	}
	bound := m[key]
	for x in bound {
		_ = x
	}
	for x in xs[0] {
		_ = x
	}
	for k, v in m {
		_ = k
		_ = v
	}
}
`,
		config = {enable_lint_loops = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{{10, "range-map-lookup"}, {13, "range-map-lookup"}, {16, "range-map-lookup"}},
	)
}
