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

	test.expect_lint_diagnostics(t, &source, {{3, "bool-return"}, {11, "bool-return"}, {41, "bool-return"}})
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
	for i in 1..=n {
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
