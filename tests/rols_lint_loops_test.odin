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
	outer: for x in xs {
		for y in xs {
			if y == x {
				continue outer
			}
		}
		return x
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
	for i < n {
		v := f() or_break
		use(v)
	}
}

f :: proc() -> (int, bool) {
	return 0, true
}

depth := 3

pop :: proc() {
	depth -= 1
}

h :: proc() {
	for depth > 0 {
		pop()
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

@(test)
range_off_by_one_ignores_slice_end :: proc(t: ^testing.T) {
	// Corpus: Skald wrap_test.odin:395, see docs/corpus-validation.md.
	source := test.Source {
		main = `package test

prefixes :: proc(s: string) -> int {
	n := 0
	for b in 0 ..= len(s) {
		n += len(s[:b])
	}
	return n
}
`,
		config = {enable_lint_loops = true},
	}

	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
range_off_by_one_ignores_other_collection :: proc(t: ^testing.T) {
	// Corpus: Skald text.odin:589, text_runa.odin:441 and wrap_test.odin:395.
	source := test.Source {
		main = `package test

other :: proc(text: string) -> []f32 {
	out := make([]f32, len(text) + 1)
	for b in 0 ..= len(text) {
		out[b] = 1
	}
	for b in 0 ..= len(text) {
		if b < len(text) {
			_ = text[b]
		}
	}
	return out
}

same :: proc(text: string) {
	for b in 0 ..= len(text) {
		_ = text[b]
	}
	for b in 0 ..= len(text) {
		_ = text[:b]
		_ = text[b]
	}
	for b in 0 ..= len(text) {
		if len(text) > 0 {
			_ = text[b]
		}
	}
	for b in 0 ..= len(text) {
		if b == len(text) {
		} else {
			_ = text[b]
		}
	}
}
`,
		config = {enable_lint_loops = true},
	}

	// Indexing the bounded collection itself without a guard still runs one past the end.
	test.expect_lint_diagnostics(t, &source, {{16, "range-off-by-one"}, {19, "range-off-by-one"}, {23, "range-off-by-one"}})
}

@(test)
range_off_by_one_guard_order_and_length_local :: proc(t: ^testing.T) {
	// `&&` evaluates left to right, so only a guard before the index protects it.
	source := test.Source {
		main = `package test

f :: proc(text: string) {
	for b in 0 ..= len(text) {
		if text[b] == 0 && b < len(text) {
		}
	}
	for b in 0 ..= len(text) {
		if b < len(text) && text[b] == 0 {
		}
	}
	n := len(text)
	for b in 0 ..= len(text) {
		if b < n {
			_ = text[b]
		}
	}
	m := len(text) - 1
	for b in 0 ..= len(text) {
		if b < m {
			_ = text[b]
		}
	}
}
`,
		config = {enable_lint_loops = true},
	}

	test.expect_lint_diagnostics(t, &source, {{3, "range-off-by-one"}, {18, "range-off-by-one"}})
}

@(test)
range_off_by_one_guard_operator_and_scope :: proc(t: ^testing.T) {
	// A guard needs the operator that excludes len for the branch the index sits in. An if init runs before the
	// condition, and a length local that is reassigned or shadowed is no guard. Neither is one whose collection
	// changes after it. Equivalent spellings of `b < len(text)` still guard.
	source := test.Source {
		main = `package test

f :: proc(text: string, c: bool) {
	for b in 0 ..= len(text) {
		if b > len(text) {
			_ = text[b]
		}
	}
	for b in 0 ..= len(text) {
		if b < len(text) || text[b] == 0 {
		}
	}
	for b in 0 ..= len(text) {
		if v := text[b]; b < len(text) {
			_ = v
		}
	}
	n := len(text)
	n += 1
	for b in 0 ..= len(text) {
		if b < n {
			_ = text[b]
		}
	}
	k := len(text)
	{
		k := 5
		for b in 0 ..= len(text) {
			if b < k {
				_ = text[b]
			}
		}
	}
}

guarded :: proc(text: string, c: bool) {
	for b in 0 ..= len(text) {
		if len(text) > b {
			_ = text[b]
		}
	}
	for b in 0 ..= len(text) {
		if c && b != len(text) {
			_ = text[b]
		}
	}
	for b in 0 ..= len(text) {
		if c || b >= len(text) {
		} else {
			_ = text[b]
		}
	}
	for b in 0 ..= len(text) {
		if b == len(text) || text[b] == 0 {
		}
	}
	m := len(text)
	{
		_ := 0
	}
	for b in 0 ..= len(text) {
		if b < m {
			_ = text[b]
		}
	}
}
stale :: proc(t: string, c: bool) {
	s := t
	n := len(s)
	s = s[1:]
	for b in 0 ..= len(s) {
		if b < n {
			_ = s[b]
		}
	}
	for b in 0 ..= len(s) {
		if b < len(s) {
		} else if c {
			_ = s[b]
		}
	}
}

equivalent :: proc(text: string, c: bool) {
	for b in 0 ..= len(text) {
		if b <= len(text) - 1 {
			_ = text[b]
		}
	}
	for b in 0 ..= len(text) {
		if b + 1 <= len(text) {
			_ = text[b]
		}
	}
	for b in 0 ..= len(text) {
		if !(b >= len(text)) {
			_ = text[b]
		}
	}
	for b in 0 ..= len(text) {
		if len(text) - 1 >= b {
			_ = text[b]
		}
	}
	for b in 0 ..= len(text) {
		if len(text) >= b + 1 {
			_ = text[b]
		}
	}
	for b in 0 ..= len(text) {
		if !(len(text) <= b) {
			_ = text[b]
		}
	}
	for b in 0 ..= len(text) {
		if b > len(text) - 1 {
		} else {
			_ = text[b]
		}
	}
	for b in 0 ..= len(text) {
		if !(b < len(text)) {
		} else {
			_ = text[b]
		}
	}
	for b in 0 ..= len(text) {
		if b + 1 > len(text) {
		} else {
			_ = text[b]
		}
	}
	for b in 0 ..= len(text) {
		if len(text) <= b {
		} else {
			_ = text[b]
		}
	}
	for b in 0 ..= len(text) {
		if b >= len(text) {
		} else if c {
			_ = text[b]
		}
	}
	when true {
		w := len(text)
	}
	for b in 0 ..= len(text) {
		if b < w {
			_ = text[b]
		}
	}
}

unguarded :: proc(text: string) {
	for b in 0 ..= len(text) {
		if b <= len(text) {
			_ = text[b]
		}
	}
	for b in 0 ..= len(text) {
		if b - 1 < len(text) {
			_ = text[b]
		}
	}
	for b in 0 ..= len(text) {
		if b < len(text) + 1 {
			_ = text[b]
		}
	}
	for b in 0 ..= len(text) {
		if b != len(text) - 1 {
			_ = text[b]
		}
	}
}

results :: proc(text: string) {
	n := len(text)
	_ = n
	g :: proc(text: string) -> (n: int) {
		for b in 0 ..= len(text) {
			if b < n {
				_ = text[b]
			}
		}
		return
	}
	_ = g
}

`,
		config = {enable_lint_loops = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{
			{3, "range-off-by-one"},
			{8, "range-off-by-one"},
			{12, "range-off-by-one"},
			{19, "range-off-by-one"},
			{27, "range-off-by-one"},
			{70, "range-off-by-one"},
			{75, "range-off-by-one"},
			{155, "range-off-by-one"},
			{160, "range-off-by-one"},
			{165, "range-off-by-one"},
			{170, "range-off-by-one"},
			{181, "range-off-by-one"},
		},
	)
}
