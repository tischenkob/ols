package tests

import "core:testing"

import test "src:testing"

BOOL_COMPARE_SOURCE :: `package test

f :: proc(a, b: bool, x: int) -> bool {
	if a == true {
	}
	if a != true {
	}
	if false == a {
	}
	if x > 1 == false {
	}
	if a == b {
	}
	return a != false
}
`

@(test)
lint_simplify_array_broadcast :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

a: [3]int = {1, 1, 1}
b: [3]int = {1, 1, 2}
c: [3]int = [3]int{2, 2, 2}
d := [3]int{1, 1, 1}
e := [?]int{1, 1}
f := []int{1, 1}
g := [2][2]int{{1, 1}, {1, 1}}
h: [2]f32 = {-0.5, -0.5}
i: [3]int = {1}
K :: [2]int{1, 1}
p :: proc(v: [2]f32 = {0.5, 0.5}, w: [2]f32 = {0.5, 1}) {}
E :: enum {
	A,
	B,
}
j: [E]int = {.A = 1, .B = 1}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{
			{2, "array-broadcast"},
			{4, "array-broadcast"},
			{5, "array-broadcast"},
			{9, "array-broadcast"},
			{11, "array-broadcast"},
			{12, "array-broadcast"},
		},
	)
}

@(test)
lint_simplify_bool_return :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(x: int) -> bool {
	if x > 1 {
		return true
	} else {
		return false
	}
}

g :: proc(x: int) -> bool {
	if x > 1 {
		return false
	}
	return true
}

h :: proc(x: int) -> b32 {
	if x > 1 {
		return true
	}
	return false
}

k :: proc(x: int) -> (bool, int) {
	if x > 1 {
		return true, 1
	}
	return false, 1
}

m :: proc(x: int) -> bool {
	if x > 1 {
		return true
	}
	return true
}

n :: proc(x: int) -> bool {
	switch x {
	case 1:
		if x > 0 {
			return true
		}
		return false
	}
	return false
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{{3, "bool-return"}, {5, "redundant-else"}, {11, "bool-return"}, {41, "bool-return"}},
	)
}

@(test)
lint_simplify_bool_compare :: proc(t: ^testing.T) {
	source := test.Source {
		main = BOOL_COMPARE_SOURCE,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{{3, "bool-compare"}, {5, "bool-compare"}, {7, "bool-compare"}, {9, "bool-compare"}, {13, "bool-compare"}},
	)
}

@(test)
lint_simplify_disabled :: proc(t: ^testing.T) {
	source := test.Source {
		main = BOOL_COMPARE_SOURCE,
	}

	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
lint_simplify_tags :: proc(t: ^testing.T) {
	source := test.Source {
		main = BOOL_COMPARE_SOURCE,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_tags(t, &source, {.Unnecessary})
}

@(test)
lint_simplify_double_negation :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a, b: bool, x: f32) -> bool {
	c := !!a
	d := !(!a)
	e := !(a == b)
	g := !(a != b)
	h := !(x < 1)
	i := !(a && b)
	return c && d && e && g && h && i
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{{3, "double-negation"}, {4, "double-negation"}, {5, "double-negation"}, {6, "double-negation"}},
	)
}

@(test)
lint_simplify_bool_ternary :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: bool, x: int) -> bool {
	b := true if a else false
	c := false if x > 1 else true
	d := a ? true : false
	e := true if a else true
	g := 1 if a else 0
	return b && c && d && e && g > 0
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(t, &source, {{3, "bool-ternary"}, {4, "bool-ternary"}, {5, "bool-ternary"}})
}

@(test)
lint_simplify_redundant_parens :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

P :: struct {
	x: int,
}

f :: proc(a: bool, p: P, m: map[int]bool, k: int) -> bool {
	if (a) {
	}
	if (p == P{}) {
	}
	if (k in m) {
	}
	for (a) {
		break
	}
	switch (k) {
	}
	when (ODIN_OS == .Windows) {
	}
	return (a)
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{
			{7, "redundant-parens"},
			{13, "redundant-parens"},
			{16, "redundant-parens"},
			{18, "redundant-parens"},
			{20, "redundant-parens"},
		},
	)
}

@(test)
lint_simplify_full_slice :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(s: []int) -> []int {
	a := s[0:len(s)]
	b := s[:len(s)]
	c := s[0:]
	d := s[1:len(s)]
	e := s[:]
	g := f(s)[0:len(f(s))]
	h := s[0:len(a)]
	return a[:len(b)]
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(t, &source, {{3, "full-slice"}, {4, "full-slice"}, {5, "full-slice"}})
}

@(test)
lint_simplify_for_true :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() {
	for true {
		break
	}
	for ; true; {
		break
	}
	for false {
		break
	}
	for i := 0; true; i += 1 {
		break
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(t, &source, {{3, "for-true"}})
}

@(test)
lint_simplify_make_zero :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() {
	a := make([dynamic]int, 0)
	b := make([dynamic]int, 0, 8)
	c := make([dynamic]int, 0, context.temp_allocator)
	d := make([dynamic]int, 1)
	e := make([]int, 0)
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(t, &source, {{3, "make-zero"}})
}

@(test)
lint_simplify_empty_else :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: bool) {
	if a {
	} else {
	}
	if a {
	} else {
		// comment
	}
	if a {
	} else if a {
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(t, &source, {{4, "empty-else"}})
}

@(test)
lint_simplify_compound_assign :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: []int, x: int) {
	x := x
	x = x + 1
	x = 1 + x
	x = 1 - x
	a[g()] = a[g()] + 1
	x = x - 1
	x = x * 2
}

g :: proc() -> int {
	return 0
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(t, &source, {{4, "compound-assign"}, {8, "compound-assign"}, {9, "compound-assign"}})
}

@(test)
lint_simplify_nested_if :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a, b: bool) {
	if a {
		if b {
		}
	}
	if a {
		if b {
		}
	} else {
		return
	}
	if a {
		if b {
		}
		if b {
		}
	}
	if a {
		// comment
		if b {
		}
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(t, &source, {{3, "nested-if"}})
}

@(test)
action_simplify_array_broadcast :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

a: [3]int = {1, {*}1, 1}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(t, &source, "Use scalar for array literal", `package test

a: [3]int = 1
`)
}

@(test)
action_simplify_array_broadcast_typed_literal :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

d := [3]in{*}t{1, 1, 1}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(t, &source, "Use scalar for array literal", `package test

d: [3]int = 1
`)
}

@(test)
action_simplify_array_broadcast_constant :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

K :: [2]f32{0.5, {*}0.5}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(t, &source, "Use scalar for array literal", `package test

K: [2]f32 : 0.5
`)
}

@(test)
action_simplify_array_broadcast_param :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

p :: proc(v: [2]f32 = {0.{*}5, 0.5}) {}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Use scalar for array literal",
		`package test

p :: proc(v: [2]f32 = 0.5) {}
`,
	)
}

@(test)
action_simplify_array_broadcast_disabled :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

a: [3]int = {1, {*}1, 1}
`,
	}

	test.expect_action_missing(t, &source, "Use scalar for array literal")
}

@(test)
action_simplify_bool_return :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(x: int) -> bool {
	if x {*}> 1 {
		return true
	} else {
		return false
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Return the condition",
		`package test

f :: proc(x: int) -> bool {
	return x > 1
}
`,
	)
}

@(test)
action_simplify_bool_return_next_stmt :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

g :: proc(x: int) -> bool {
	if x {*}> 1 {
		return false
	}
	return true
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Return the condition",
		`package test

g :: proc(x: int) -> bool {
	return !(x > 1)
}
`,
	)
}

@(test)
action_simplify_bool_compare :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: bool) {
	if a =={*} true {
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Remove comparison with true",
		`package test

f :: proc(a: bool) {
	if a {
	}
}
`,
	)
}

@(test)
action_simplify_bool_compare_false :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(x: int) -> bool {
	ok := x > 1 =={*} false
	return ok
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Remove comparison with false",
		`package test

f :: proc(x: int) -> bool {
	ok := !(x > 1)
	return ok
}
`,
	)
}

@(test)
action_simplify_double_negation :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: bool) -> bool {
	return !{*}!a
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Remove double negation",
		`package test

f :: proc(a: bool) -> bool {
	return a
}
`,
	)
}

@(test)
action_simplify_double_negation_comparison :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a, b: int) -> bool {
	return !{*}(a == b)
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Remove double negation",
		`package test

f :: proc(a, b: int) -> bool {
	return a != b
}
`,
	)
}

@(test)
action_simplify_bool_ternary :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(x: int) -> bool {
	return false if x {*}> 1 else true
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Replace ternary with condition",
		`package test

f :: proc(x: int) -> bool {
	return !(x > 1)
}
`,
	)
}

@(test)
action_simplify_redundant_parens :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: bool) {
	if ({*}a) {
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Remove redundant parentheses",
		`package test

f :: proc(a: bool) {
	if a {
	}
}
`,
	)
}

@(test)
action_simplify_redundant_parens_after_keyword :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: int) -> int {
	return({*}a)
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Remove redundant parentheses",
		`package test

f :: proc(a: int) -> int {
	return a
}
`,
	)
}

@(test)
action_simplify_redundant_parens_before_keyword :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: bool) {
	if({*}a)do f(a)
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Remove redundant parentheses",
		`package test

f :: proc(a: bool) {
	if a do f(a)
}
`,
	)
}

// A range reads its bound once, and a call in the body may change a bound that is not a private
// local: a global, or a local whose address escapes.
@(test)
lint_simplify_range_loop_variant_bound :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

queue: [dynamic]int

push :: proc(v: int) {
	append(&queue, v)
}

f :: proc() {
	for i := 0; i < len(queue); i += 1 {
		if queue[i] > 0 do push(queue[i] - 1)
	}
}

grow :: proc(p: ^[dynamic]int) {
	append(p, 1)
}

h :: proc() {
	xs: [dynamic]int
	p := &xs
	for i := 0; i < len(xs); i += 1 {
		grow(p)
	}
}

// len dereferences a pointer, so the length grows through it.
by_pointer :: proc(q: ^[dynamic]int) {
	for i := 0; i < len(q); i += 1 {
		append(q, 1)
	}
}

local_pointer :: proc() {
	xs: [dynamic]int
	p := &xs
	for i := 0; i < len(p); i += 1 {
		grow(p)
	}
}

copied_pointer :: proc(q: ^[dynamic]int) {
	r := q
	for i := 0; i < len(q); i += 1 {
		grow(r)
	}
}

// The local queue comes after the loop, which reads the global.
later_shadow :: proc() {
	for i := 0; i < len(queue); i += 1 {
		push(i)
	}
	{
		queue := make([dynamic]int)
		_ = queue
	}
}

// The block ends before the loop, which reads the global.
earlier_block :: proc() {
	{
		queue: [dynamic]int
		_ = queue
	}
	for i := 0; i < len(queue); i += 1 {
		push(i)
	}
}

// The range, #unroll and type switch variables shadow the slice parameter with a pointer.
range_shadow :: proc(xs: []int, rows: []^[dynamic]int) {
	for xs in rows {
		for i := 0; i < len(xs); i += 1 {
			grow(xs)
		}
	}
}

unroll_shadow :: proc(xs: []int, rows: [2]^[dynamic]int) {
	#unroll for xs in rows {
		for i := 0; i < len(xs); i += 1 {
			grow(xs)
		}
	}
}

Rows :: union {
	^[dynamic]int,
}

type_switch_shadow :: proc(xs: []int, v: Rows) {
	switch xs in v {
	case ^[dynamic]int:
		for i := 0; i < len(xs); i += 1 {
			grow(xs)
		}
	}
}

// A when body opens no scope, so its xs shadows the parameter at the loop.
when_shadow :: proc(xs: []int, q: ^[dynamic]int) {
	when true {
		xs := q
	}
	for i := 0; i < len(xs); i += 1 {
		grow(xs)
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(t, &source, {})
}

// A loop variable the body never reads becomes `_`, which -vet-unused-variables accepts. An i in a
// nested procedure literal is another variable.
@(test)
action_simplify_range_loop_unread_variable :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

g :: proc(p: proc()) {}

i: int

f :: proc(n: int) {
	for i := 0; i {*}< n; i += 1 {
		g(proc() {
			_ = i
		})
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Use range loop",
		`package test

g :: proc(p: proc()) {}

i: int

f :: proc(n: int) {
	for _ in 0..<n {
		g(proc() {
			_ = i
		})
	}
}
`,
	)
}

// A field after a dot and an implicit selector do not read the loop variable.
@(test)
action_simplify_range_loop_field_names :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	i: int,
}

E :: enum {
	a,
	i,
}

f :: proc(s: ^S, n: int) -> E {
	e := E.a
	for i := 0; i {*}< n; i += 1 {
		s.i += 1
		e = .i
	}
	return e
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Use range loop",
		`package test

S :: struct {
	i: int,
}

E :: enum {
	a,
	i,
}

f :: proc(s: ^S, n: int) -> E {
	e := E.a
	for _ in 0..<n {
		s.i += 1
		e = .i
	}
	return e
}
`,
	)
}

// A map literal key is an expression that reads the loop variable.
@(test)
action_simplify_range_loop_map_key :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+feature dynamic-literals
package test

f :: proc(n: int) -> int {
	total := 0
	for i := 0; i {*}< n; i += 1 {
		m := map[int]int{i = 1}
		total += len(m)
		delete(m)
	}
	return total
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Use range loop",
		`#+feature dynamic-literals
package test

f :: proc(n: int) -> int {
	total := 0
	for i in 0..<n {
		m := map[int]int{i = 1}
		total += len(m)
		delete(m)
	}
	return total
}
`,
	)
}

// A field named like the loop variable in a literal whose map type is named or inferred may be a
// key that reads it, so neither `i` nor `_` is safe.
@(test)
lint_simplify_range_loop_unsure_field :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+feature dynamic-literals
package test

M :: map[int]int

f :: proc(out: []M, n: int) {
	for i := 0; i < n; i += 1 {
		out[0] = M{i = 1}
	}
	for i := 0; i < n; i += 1 {
		out[1] = {i = 1}
	}
	for i := 0; i < n; i += 1 {
		out[2] = M{i + 1 = 1}
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	// A key that is not a plain name is an expression, so the last loop reads i and keeps it.
	test.expect_lint_diagnostics(t, &source, {{12, "range-loop"}})
}

@(test)
action_simplify_range_loop_expression_key :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+feature dynamic-literals
package test

M :: map[int]int

f :: proc(out: []M, n: int) {
	for i := 0; i {*}< n; i += 1 {
		out[0] = M{i + 1 = 1}
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Use range loop",
		`#+feature dynamic-literals
package test

M :: map[int]int

f :: proc(out: []M, n: int) {
	for i in 0..<n {
		out[0] = M{i + 1 = 1}
	}
}
`,
	)
}

// A local array, slice or make result keeps its length while the body calls something.
@(test)
lint_simplify_range_loop_local_bound :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

g :: proc(v: int) {}

f :: proc(xs: []int, n: int) {
	ys := make([dynamic]int, 4)
	for i := 0; i < len(ys); i += 1 {
		g(ys[i])
	}
	for i := 0; i < len(xs); i += 1 {
		g(xs[i])
	}
	for i := 0; i < n; i += 1 {
		g(i)
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(t, &source, {{6, "range-loop"}, {9, "range-loop"}, {12, "range-loop"}})
}

// An earlier iteration of the #unroll loop sets n, which or_return would return.
@(test)
lint_simplify_or_return_written_in_unroll :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Error :: union {
	int,
}

f :: proc() -> (int, Error) {
	return 0, nil
}

g :: proc() -> (n: int, err: Error) {
	#unroll for k in 0 ..< 2 {
		v, e := f()
		if e != nil {
			return 0, e
		}
		n += v
	}
	return
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(t, &source, {})
}

// or_return returns the current value of a named result, which is 5 here, not 0.
@(test)
lint_simplify_or_return_written_result :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Error :: union {
	int,
}

f :: proc() -> (int, Error) {
	return 0, nil
}

g :: proc() -> (n: int, err: Error) {
	n = 5
	v, e := f()
	if e != nil {
		return 0, e
	}
	return v, nil
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
action_simplify_full_slice :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(s: []int) -> []int {
	return s[0:len{*}(s)]
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Use full slice",
		`package test

f :: proc(s: []int) -> []int {
	return s[:]
}
`,
	)
}

@(test)
action_simplify_for_true :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() {
	for tr{*}ue {
		break
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(t, &source, "Remove redundant true", `package test

f :: proc() {
	for {
		break
	}
}
`)
}

@(test)
action_simplify_make_zero :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() {
	a := make([dynamic]int, {*}0)
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Remove zero length",
		`package test

f :: proc() {
	a := make([dynamic]int)
}
`,
	)
}

@(test)
action_simplify_empty_else :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: bool) {
	if a {
	} else {{*}
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(t, &source, "Remove empty else", `package test

f :: proc(a: bool) {
	if a {
	}
}
`)
}

@(test)
action_simplify_empty_else_outside :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: bool) {
	if {*}a {
	} else {
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_missing(t, &source, "Remove empty else")
}

@(test)
action_simplify_compound_assign :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(x: int) {
	x := x
	x = x {*}+ 1
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Use compound assignment",
		`package test

f :: proc(x: int) {
	x := x
	x += 1
}
`,
	)
}

@(test)
action_simplify_nested_if :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a, b: bool) {
	x := 0
	if {*}a {
		if b {
			x = 1
		}
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Merge nested if",
		`package test

f :: proc(a, b: bool) {
	x := 0
	if a && b {
		x = 1
	}
}
`,
	)
}

@(test)
action_simplify_bool_return_nan :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(x: f32) -> bool {
	if x {*}< 1.0 {
		return false
	}
	return true
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Return the condition",
		`package test

f :: proc(x: f32) -> bool {
	return !(x < 1.0)
}
`,
	)
}

@(test)
action_simplify_bool_return_equality :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(x: int) -> bool {
	if x {*}== 1 {
		return false
	}
	return true
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Return the condition",
		`package test

f :: proc(x: int) -> bool {
	return x != 1
}
`,
	)
}

@(test)
lint_simplify_range_loop :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	items: []int,
}

f :: proc(xs: [dynamic]int, s: S, n: int) {
	n := n
	xs := xs
	for i := 0; i < len(xs); i += 1 {
	}
	for i := 1; i <= n; i += 1 {
	}
	for i := 0; i < len(s.items) - 1; i += 1 {
	}
	for i := 0; i < len(xs); i += 1 {
		append(&xs, i)
	}
	for i := 0; i < n; i += 1 {
		i = 2
	}
	for i := 0; i < n; i += 1 {
		p := &i
	}
	for i: u32 = 0; i < 4; i += 1 {
	}
	for i := 0; i < n; i += 2 {
	}
	for i := 0; i < g(); i += 1 {
	}
	for i := 0; i < n; i += 1 {
		n -= 1
	}
	for i := 0; i > n; i += 1 {
	}
}

g :: proc() -> int {
	return 0
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(t, &source, {{9, "range-loop"}, {11, "range-loop"}, {13, "range-loop"}})
}

@(test)
lint_simplify_or_else :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(m: map[int]int, k: int, a: any, u: Maybe(int)) -> int {
	x := 0
	if v, ok := m[k]; ok {
		return v
	} else {
		return 0
	}
	if v, ok := a.(int); ok {
		x = v
	} else {
		x = 1
	}
	if v, ok := u.?; ok {
		return v
	} else {
		return 0
	}
	if v, ok := m[k]; ok {
		return v
	} else if x > 0 {
		return 0
	}
	if v, ok := m[k]; ok {
		return v
	} else {
		return g()
	}
	if v, ok := m[k]; ok == true {
		return v
	} else {
		return 0
	}
	if v, ok := m[k]; ok {
		return v + 1
	} else {
		return 0
	}
	if v, ok := h(); ok {
		return v
	} else {
		return 0
	}
	return x
}

g :: proc() -> int {
	return 0
}

h :: proc() -> (int, bool) {
	return 0, false
}
`,
		config = {enable_lint_simplify = true},
	}

	// No redundant-else: each else ends in a return and more statements follow the if.
	test.expect_lint_diagnostics(t, &source, {{4, "or-else"}, {9, "or-else"}, {14, "or-else"}, {29, "bool-compare"}})
}

@(test)
lint_simplify_or_return :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Error :: union {
	int,
}

f :: proc() -> (int, Error) {
	return 0, nil
}

g :: proc() -> (x: int, err: Error) {
	v, err := f()
	if err != nil {
		return 0, err
	}
	w, err2 := f()
	if err2 != nil {
		return x, err2
	}
	_, err3 := f()
	if err3 != nil {
		return {}, err3
	}
	y, err4 := f()
	if err4 != nil {
		return 1, err4
	}
	z, err5 := f()
	if err5 != nil {
		return 0, err5
	}
	x = int(err5.(int))
	return v + w + y + z, nil
}

h :: proc() -> Error {
	err := f()
	if err != nil {
		return err
	}
	err2 := f()
	if err2 != nil {
		return wrap(err2)
	}
	return nil
}

k :: proc() -> (int, Error) {
	v, err := f()
	if err != nil {
		return 0, err
	}
	return v, nil
}

m :: proc() -> bool {
	v, ok := n()
	if !ok {
		return false
	}
	return v > 0
}

n :: proc() -> (int, bool) {
	return 0, true
}

wrap :: proc(err: Error) -> Error {
	return err
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{{11, "or-return"}, {15, "or-return"}, {19, "or-return"}, {36, "or-return"}, {56, "or-return"}},
	)
}

@(test)
action_simplify_range_loop :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(xs: []int) {
	for i := 0; i {*}< len(xs); i += 1 {
		g(xs[i])
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Use range loop",
		`package test

f :: proc(xs: []int) {
	for i in 0..<len(xs) {
		g(xs[i])
	}
}
`,
	)
}

@(test)
action_simplify_range_loop_inclusive :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(n: int) {
	for i := 1; i {*}<= n; i = i + 1 {
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Use range loop",
		`package test

f :: proc(n: int) {
	for _ in 1..=n {
	}
}
`,
	)
}

@(test)
action_simplify_or_else :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(m: map[int]int, k: int) -> int {
	if v, ok := m[k]; o{*}k {
		return v
	} else {
		return 0
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Use or_else",
		`package test

f :: proc(m: map[int]int, k: int) -> int {
	return m[k] or_else 0
}
`,
	)
}

@(test)
action_simplify_or_else_assign :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: any) -> int {
	x := 0
	if v, ok := a.(int); o{*}k {
		x = v
	} else {
		x = 1
	}
	return x
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Use or_else",
		`package test

f :: proc(a: any) -> int {
	x := 0
	x = a.(int) or_else 1
	return x
}
`,
	)
}

@(test)
action_simplify_or_return :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() -> (res: int, err: Error) {
	v, err := f()
	if err {*}!= nil {
		return 0, err
	}
	return v, nil
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Use or_return",
		`package test

f :: proc() -> (res: int, err: Error) {
	v := f() or_return
	return v, nil
}
`,
	)
}

@(test)
action_simplify_or_return_multi :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() -> (x, y: int, err: Error) {
	a, b, err := f()
	if err {*}!= nil {
		return 0, 0, err
	}
	return a, b, nil
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Use or_return",
		`package test

f :: proc() -> (x, y: int, err: Error) {
	a, b := f() or_return
	return a, b, nil
}
`,
	)
}

@(test)
action_simplify_or_return_only_name :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() -> Error {
	err := f()
	if err {*}!= nil {
		return err
	}
	return nil
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Use or_return",
		`package test

f :: proc() -> Error {
	f() or_return
	return nil
}
`,
	)
}

// or_break leaves the innermost loop or switch like the break it replaces, and or_continue the
// innermost loop. A label carries over, and a bare checked name leaves only the call.
@(test)
lint_simplify_or_break :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Error :: union {
	int,
}

f :: proc(i: int) -> (int, bool) {
	return i, true
}

g :: proc(i: int) -> bool {
	return i > 0
}

h :: proc(i: int) -> (int, Error) {
	return i, nil
}

loops :: proc(xs: []int) -> int {
	total := 0
	for x in xs {
		v, ok := f(x)
		if !ok {
			break
		}
		total += v
	}
	for x in xs {
		v, err := h(x)
		if err != nil {
			continue
		}
		total += v
	}
	outer: for x in xs {
		for y in xs {
			ok := g(x + y)
			if !ok {
				continue outer
			}
			total += y
		}
	}
	for x in xs {
		switch x {
		case 0:
			v, ok := f(x)
			if !ok {
				break
			}
			total += v
		}
	}
	return total
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{{21, "or-break"}, {28, "or-continue"}, {36, "or-continue"}, {46, "or-break"}},
	)
}

// Refused: an else branch, the checked name used after the if, the checked name not last, a body
// with more than the branch, and an assignment, which would leave the declared ok unused.
@(test)
lint_simplify_or_break_refused :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(i: int) -> (int, bool) {
	return i, true
}

k :: proc(i: int) -> (bool, int) {
	return true, i
}

log :: proc(v: int) {}

refused :: proc(xs: []int) -> int {
	total := 0
	for x in xs {
		v, ok := f(x)
		if !ok {
			break
		} else {
			total += 1
		}
		total += v
	}
	for x in xs {
		v, ok := f(x)
		if !ok {
			continue
		}
		total += v
		if ok {
			total += 1
		}
	}
	for x in xs {
		ok, v := k(x)
		if !ok {
			break
		}
		total += v
	}
	for x in xs {
		v, ok := f(x)
		if !ok {
			log(v)
			break
		}
		total += v
	}
	v: int
	ok: bool
	for x in xs {
		v, ok = f(x)
		if !ok {
			break
		}
		total += v
	}
	return total
}
`,
		config = {enable_lint_simplify = true},
	}

	// redundant-else refuses too: statements follow the if.
	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
action_simplify_or_break :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(i: int) -> (int, int, bool) {
	return i, i, true
}

g :: proc(xs: []int) -> int {
	total := 0
	outer: for x in xs {
		for y in xs {
			a, b, ok := f(x + y)
			if {*}!ok {
				break outer
			}
			total += a + b
		}
	}
	return total
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Use or_break",
		`package test

f :: proc(i: int) -> (int, int, bool) {
	return i, i, true
}

g :: proc(xs: []int) -> int {
	total := 0
	outer: for x in xs {
		for y in xs {
			a, b := f(x + y) or_break outer
			total += a + b
		}
	}
	return total
}
`,
	)
}

// Odin rejects `_ := f() or_break` as declaring nothing, so a blank name assigns.
@(test)
action_simplify_or_break_blank :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(i: int) -> (int, bool) {
	return i, true
}

g :: proc(xs: []int) -> int {
	total := 0
	for x in xs {
		_, ok := f(x)
		if {*}!ok {
			break
		}
		total += x
	}
	return total
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Use or_break",
		`package test

f :: proc(i: int) -> (int, bool) {
	return i, true
}

g :: proc(xs: []int) -> int {
	total := 0
	for x in xs {
		_ = f(x) or_break
		total += x
	}
	return total
}
`,
	)
}

// A comment between the declaration and the `if`, or after the declaration, would be lost.
@(test)
lint_simplify_or_branch_comment :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(i: int) -> (int, bool) {
	return i, true
}

g :: proc(xs: []int) -> int {
	total := 0
	for x in xs {
		v, ok := f(x)
		// stop at the first failure
		if !ok {
			break
		}
		total += v
	}
	for x in xs {
		v, ok := f(x) // the value may be stale
		if !ok {
			continue
		}
		total += v
	}
	return total
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(t, &source, {})
}

// Without a loop, or_break leaves the switch like the break it replaces.
@(test)
action_simplify_or_break_switch :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(i: int) -> (int, bool) {
	return i, true
}

g :: proc(x: int) -> int {
	total := 0
	switch x {
	case 0:
		v, ok := f(x)
		if {*}!ok {
			break
		}
		total += v
	}
	return total
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Use or_break",
		`package test

f :: proc(i: int) -> (int, bool) {
	return i, true
}

g :: proc(x: int) -> int {
	total := 0
	switch x {
	case 0:
		v := f(x) or_break
		total += v
	}
	return total
}
`,
	)
}

// A labelled break carries its label, to a block or out of an #unroll loop.
@(test)
lint_simplify_or_break_labels :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(i: int) -> (int, bool) {
	return i, true
}

g :: proc(xs: []int) -> int {
	total := 0
	for x in xs {
		blk: {
			v, ok := f(x)
			if !ok {
				break blk
			}
			total += v
		}
	}
	outer: for x in xs {
		#unroll for i in 0 ..< 2 {
			v, ok := f(x + i)
			if !ok {
				break outer
			}
			total += v
		}
	}
	return total
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(t, &source, {{10, "or-break"}, {19, "or-break"}})
}

// A `do` body is refused: its end, and its `if`'s, stop before an unlabelled break.
@(test)
lint_simplify_or_break_do :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(i: int) -> (int, bool) {
	return i, true
}

g :: proc(xs: []int) -> int {
	total := 0
	for x in xs {
		v, ok := f(x)
		if !ok do break
		total += v
	}
	return total
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
action_simplify_or_return_blank :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Error :: union {
	int,
}

f :: proc() -> (int, Error) {
	return 0, nil
}

g :: proc() -> Error {
	_, err := f()
	if err {*}!= nil {
		return err
	}
	return nil
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Use or_return",
		`package test

Error :: union {
	int,
}

f :: proc() -> (int, Error) {
	return 0, nil
}

g :: proc() -> Error {
	_ = f() or_return
	return nil
}
`,
	)
}

@(test)
action_simplify_or_continue :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Error :: union {
	int,
}

f :: proc(i: int) -> (int, Error) {
	return i, nil
}

g :: proc(xs: []int) -> int {
	total := 0
	for x in xs {
		v, err := f(x)
		if err {*}!= nil {
			continue
		}
		total += v
	}
	return total
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Use or_continue",
		`package test

Error :: union {
	int,
}

f :: proc(i: int) -> (int, Error) {
	return i, nil
}

g :: proc(xs: []int) -> int {
	total := 0
	for x in xs {
		v := f(x) or_continue
		total += v
	}
	return total
}
`,
	)
}

@(test)
simplify_redundant_else :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: bool, x: int) -> int {
	if a {
		return 1
	} else {
		return 2
	}
	for {
		if a {
			break
		} else {
			y := 1
		}
	}
	if a {
		y := 1
	} else {
		return 3
	}
	if a {
		return 1
	} else if x > 0 {
		return 2
	}
	return 0
}

g :: proc(x: int) -> int {
	switch x {
	case 1:
		if x > 0 {
			return 1
		} else {
			return 2
		}
	}
	return 0
}
`,
		config = {enable_lint_simplify = true},
	}

	// Line 5 is refused: the for loop follows the if.
	test.expect_lint_diagnostics(t, &source, {{11, "redundant-else"}, {33, "redundant-else"}})

	action := test.Source {
		main = `package test

f :: proc(a: bool) -> int {
	if a {
		return 1
	} els{*}e {
		return 2
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&action,
		"Remove redundant else",
		`package test

f :: proc(a: bool) -> int {
	if a {
		return 1
	}
	return 2
}
`,
	)
}

// Unwrapping any of these changes behavior or leaves code Odin rejects.
@(test)
simplify_redundant_else_refused :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

// The unwrapped else would run after the whole chain, also when a is true.
chain :: proc(a, b: bool, x: ^int) {
	if a {
		return
	} else if b {
		return
	} else {
		x^ = 1
	}
}

// The unwrapped return 2 would leave return 0 unreachable.
trailing :: proc(a: bool) -> int {
	if a {
		return 1
	} else {
		return 2
	}
	return 0
}

// break blk leaves only the if, so the unwrapped else would run after it.
labeled :: proc(a: bool, x: ^int) {
	blk: if a {
		break blk
	} else {
		x^ = 1
	}
}

do_body :: proc(xs: []int, x: ^int) {
	for v in xs do if v > 0 { break } else { x^ = v }
}

// A when body opens no scope, so the defer would run after g instead of before it.
in_when :: proc(a: bool) {
	when true {
		if a {
			return
		} else {
			defer g(1)
		}
	}
	g(2)
}

// The unwrapped y := 1 would redeclare y in the same block.
redeclared :: proc(a: bool) {
	y := 0
	g(y)
	if a {
		return
	} else {
		y := 1
		g(y)
	}
}

// The y := 1 in the when body lands in the else's scope, so it would redeclare y too.
redeclared_in_when :: proc(a: bool) {
	y := 0
	g(y)
	if a {
		return
	} else {
		when true {
			y := 1
			g(y)
		}
	}
}

g :: proc(x: int) {}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
simplify_trailing_return :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() {
	g()
	return
}

g :: proc() {
	g()
}

h :: proc() -> int {
	return 0
}

k :: proc() {
	if true {
		return
	}
	g()
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(t, &source, {{4, "trailing-return"}})

	action := test.Source {
		main = `package test

f :: proc() {
	g()
	ret{*}urn
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(t, &action, "Remove trailing return", `package test

f :: proc() {
	g()
}
`)
}

@(test)
lint_simplify_paren_bool_forms :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

g :: proc(v: int) -> int {
	return v
}

f :: proc(a, b: bool, x: int) -> int {
	if ((x > 0)) {
	}
	y := (x) + 1
	z := (x + 1) * 2
	w := (x + 1) + 2
	q := g((x))
	n := -(x)
	m := (a ? 1 : 2) + 1
	k := (1)
	return y + z + w + q + n + m + k
}

h :: proc(a, b: bool, x: int) -> bool {
	r := x > 1 == true
	r = !a == true
	r = !!!a
	r = !(!(a && b))
	return r
}
`,
		config = {enable_lint_simplify = true},
	}

	// Only an if, for, switch, when or return strips its parentheses; parentheses inside an
	// expression are left alone. `!!!a` is reported twice, once per pair.
	test.expect_lint_diagnostics(
		t,
		&source,
		{
			{7, "redundant-parens"},
			{20, "bool-compare"},
			{21, "bool-compare"},
			{22, "double-negation"},
			{22, "double-negation"},
			{23, "double-negation"},
		},
	)
}

@(test)
lint_simplify_structure_forms :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

S :: struct {
	items: []int,
}

g :: proc() {}

slices :: proc(s, t: []int, v: S) {
	a := v.items[0:len(v.items)]
	b := s[0:len(t)]
	_ = a
	_ = b
}

makes :: proc() {
	a := make([dynamic]int, 0, 10)
	_ = a
}

nested_do :: proc(a, b: bool) {
	if a do if b do g()
}

nested_label :: proc(a, b: bool) {
	outer: if a {
		if b {
			g()
		}
	}
}

nested_outer_init :: proc(a, b: bool) {
	if x := 1; a {
		if b {
			g()
		}
	}
}

nested_inner_init :: proc(a: bool) {
	if a {
		if x := 1; x > 0 {
			g()
		}
	}
}

decrement :: proc(n: int) {
	for i := 0; i < n; i -= 1 {
		g()
	}
}

trailing_defer :: proc() {
	defer g()
	g()
	return
}

trailing_nested :: proc(a: bool) {
	if a {
		g()
		return
	}
	g()
}
`,
		config = {enable_lint_simplify = true},
	}

	// The merge keeps an init on the outer if but refuses one on the inner if, and refuses a
	// label or a `do` body. A capacity argument keeps `make`, and only a decrementing post
	// statement blocks the range loop.
	test.expect_lint_diagnostics(t, &source, {{9, "full-slice"}, {33, "nested-if"}, {57, "trailing-return"}})
}

@(test)
lint_simplify_or_guards :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Error :: union {
	int,
}

log :: proc(v: Error) {}

call :: proc() -> (int, Error) {
	return 0, nil
}

scoped_else :: proc(m: map[int]int, k: int) -> int {
	if v, ok := m[k]; ok {
		return v
	} else {
		return v
	}
}

scoped_assign :: proc(m: map[int]int, k: int, xs: []int) {
	if v, ok := m[k]; ok {
		xs[v] = v
	} else {
		xs[v] = 1
	}
}

or_return_forms :: proc() -> (x: int, err: Error) {
	v, e := call()
	if e != nil {
		return e, 0
	}
	w, e2 := call()
	if e2 != nil {
		log(e2)
		return 0, e2
	}
	u, e3 := call()
	if e3 == nil {
		return 0, e3
	}
	return v + w + u, nil
}

init_else :: proc(m: map[int]int, k: int) -> int {
	if v, ok := m[k]; ok {
		log(nil)
		return v
	} else {
		return 0
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	// Neither or_else nor redundant-else can lift text that names the variables the if declares.
	// or_return needs the error last in the return, a body of nothing but the return, and a
	// `!= nil` test.
	test.expect_lint_diagnostics(t, &source, {{49, "redundant-else"}})
}

@(test)
action_simplify_redundant_else_comment :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: bool) -> int {
	if a {
		return 1
	} els{*}e {
		// keep me
		return 2
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Remove redundant else",
		`package test

f :: proc(a: bool) -> int {
	if a {
		return 1
	}
	// keep me
	return 2
}
`,
	)
}

@(test)
action_simplify_double_negation_triple :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: bool) -> bool {
	return {*}!!!a
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Remove double negation",
		`package test

f :: proc(a: bool) -> bool {
	return !a
}
`,
	)
}

@(test)
action_simplify_bool_return_reversed :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(c: bool) -> bool {
	if{*} c {
		return false
	} else {
		return true
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Return the condition",
		`package test

f :: proc(c: bool) -> bool {
	return !c
}
`,
	)
}

@(private = "file")
FIX_TWICE :: []Fix_Twice {
	{"array-broadcast", "Use scalar for array literal", `package test

a: [3]int = {1{*}, 1, 1}
`, "= 1"},
	{
		"bool-return",
		"Return the condition",
		`package test

f :: proc(c: bool) -> bool {
	if{*} c {
		return true
	} else {
		return false
	}
}
`,
		"return c",
	},
	{
		"bool-compare",
		"Remove comparison with true",
		`package test

f :: proc(a: bool) -> bool {
	return a =={*} true
}
`,
		"return a",
	},
	{
		"double-negation",
		"Remove double negation",
		`package test

f :: proc(a: bool) -> bool {
	return {*}!!a
}
`,
		"return a",
	},
	{
		"bool-ternary",
		"Replace ternary with condition",
		`package test

f :: proc(a: bool) -> bool {
	return a {*}? true : false
}
`,
		"return a",
	},
	{
		"redundant-parens",
		"Remove redundant parentheses",
		`package test

g :: proc() {}

f :: proc(a: bool) {
	if {*}(a) {
		g()
	}
}
`,
		"if a",
	},
	{"full-slice", "Use full slice", `package test

f :: proc(s: []int) -> []int {
	return s[0{*}:len(s)]
}
`, "s[:]"},
	{"for-true", "Remove redundant true", `package test

f :: proc() {
	for {*}true {
		break
	}
}
`, "for"},
	{
		"make-zero",
		"Remove zero length",
		`package test

f :: proc() {
	a := make([dynamic]int, {*}0)
	_ = a
}
`,
		"make([dynamic]int)",
	},
	{
		"empty-else",
		"Remove empty else",
		`package test

g :: proc() {}

f :: proc(a: bool) {
	if a {
		g()
	} els{*}e {
	}
}
`,
		"\tg()",
	},
	{
		"compound-assign",
		"Use compound assignment",
		`package test

f :: proc(x: int) -> int {
	x := x
	x = x {*}+ 1
	return x
}
`,
		"x += 1",
	},
	{
		"nested-if",
		"Merge nested if",
		`package test

g :: proc() {}

f :: proc(a, b: bool) {
	if{*} a {
		if b {
			g()
		}
	}
}
`,
		"a && b",
	},
	{
		"range-loop",
		"Use range loop",
		`package test

g :: proc(v: int) {}

f :: proc(xs: []int) {
	for i := 0; i {*}< len(xs); i += 1 {
		g(xs[i])
	}
}
`,
		"0..<len(xs)",
	},
	{
		"or-else",
		"Use or_else",
		`package test

f :: proc(m: map[int]int, k: int) -> int {
	if v, ok := m[k]; o{*}k {
		return v
	} else {
		return 0
	}
}
`,
		"or_else 0",
	},
	{
		"or-return",
		"Use or_return",
		`package test

Error :: union {
	int,
}

call :: proc() -> (int, Error) {
	return 0, nil
}

f :: proc() -> (res: int, err: Error) {
	v, e := call()
	if e {*}!= nil {
		return 0, e
	}
	return v, nil
}
`,
		"or_return",
	},
	{
		"or-break",
		"Use or_break",
		`package test

f :: proc(i: int) -> (int, bool) {
	return i, true
}

g :: proc(xs: []int) -> int {
	total := 0
	for x in xs {
		v, ok := f(x)
		if {*}!ok {
			break
		}
		total += v
	}
	return total
}
`,
		"or_break",
	},
	{
		"or-continue",
		"Use or_continue",
		`package test

Error :: union {
	int,
}

f :: proc(i: int) -> (int, Error) {
	return i, nil
}

g :: proc(xs: []int) -> int {
	total := 0
	for x in xs {
		v, err := f(x)
		if err {*}!= nil {
			continue
		}
		total += v
	}
	return total
}
`,
		"or_continue",
	},
	{
		"redundant-else",
		"Remove redundant else",
		`package test

f :: proc(a: bool) -> int {
	if a {
		return 1
	} els{*}e {
		return 2
	}
}
`,
		"return 2",
	},
	{
		"trailing-return",
		"Remove trailing return",
		`package test

g :: proc() {}

f :: proc() {
	g()
	ret{*}urn
}
`,
		"\tg()",
	},
}

@(test)
simplify_fix_twice :: proc(t: ^testing.T) {
	expect_fix_twice(t, FIX_TWICE, {enable_lint_simplify = true})
}

// fix_branch_stmt_ends gives the `do` body and its `if` the end of the whole break, so the
// removal starts after it.
@(test)
action_simplify_empty_else_after_do_break :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(xs: []int) {
	for x in xs {
		if x > 0 do break
		else {{*}}
	}
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Remove empty else",
		`package test

f :: proc(xs: []int) {
	for x in xs {
		if x > 0 do break
	}
}
`,
	)
}
