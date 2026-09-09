package tests

import "core:strings"
import "core:testing"

import test "src:testing"

EXPAND_ARRAY :: "Expand array literal"
EXPAND_OR_ELSE :: "Expand or_else"
EXPAND_OR_RETURN :: "Expand or_return"
C_STYLE_FOR :: "Convert to C-style for"

expect_expand :: proc(t: ^testing.T, action, main, expected: string) {
	source := test.Source{main = main, config = {enable_code_action_expand = true}}
	test.expect_action_applied(t, &source, action, expected)
}

expect_no_expand :: proc(t: ^testing.T, action, main: string, enabled := true) {
	source := test.Source{main = main, config = {enable_code_action_expand = enabled}}
	test.expect_action_missing(t, &source, action)
}

// Applies expand, puts the cursor before marker in the result, applies simplify and expects main back.
expect_round_trip :: proc(t: ^testing.T, expand, simplify, marker, main: string) {
	source := test.Source{main = main, config = {enable_code_action_expand = true, enable_lint_simplify = true}}
	expanded, ok := test.apply_action(t, &source, expand)
	if !ok {
		return
	}
	cursor := strings.concatenate({"{*}", marker}, context.temp_allocator)
	back := test.Source {
		main   = strings.replace(expanded, marker, cursor, 1, context.temp_allocator) or_else expanded,
		config = {enable_lint_simplify = true},
	}
	original, _ := strings.replace(main, "{*}", "", 1, context.temp_allocator)
	test.expect_action_applied(t, &back, simplify, original)
}

@(test)
expand_array_decl :: proc(t: ^testing.T) {
	expect_expand(t, EXPAND_ARRAY, `package test

a: [3]int = {*}1
`, `package test

a: [3]int = {1, 1, 1}
`)
}

@(test)
expand_array_negative_in_proc :: proc(t: ^testing.T) {
	expect_expand(t, EXPAND_ARRAY, `package test

main :: proc() {
	h: [2]f32 = -0{*}.5
}
`, `package test

main :: proc() {
	h: [2]f32 = {-0.5, -0.5}
}
`)
}

@(test)
expand_array_field_default :: proc(t: ^testing.T) {
	expect_expand(t, EXPAND_ARRAY, `package test

p :: proc(v: [2]f32 = 0.{*}5) {}
`, `package test

p :: proc(v: [2]f32 = {0.5, 0.5}) {}
`)
}

@(test)
expand_array_unknown_len :: proc(t: ^testing.T) {
	expect_no_expand(t, EXPAND_ARRAY, `package test

a: [?]int = {*}1
`)
}

@(test)
expand_array_too_long :: proc(t: ^testing.T) {
	expect_no_expand(t, EXPAND_ARRAY, `package test

a: [64]int = {*}1
`)
}

@(test)
expand_array_comp_lit :: proc(t: ^testing.T) {
	expect_no_expand(t, EXPAND_ARRAY, `package test

a: [3]int = {1, {*}1, 1}
`)
}

@(test)
expand_array_disabled :: proc(t: ^testing.T) {
	expect_no_expand(t, EXPAND_ARRAY, `package test

a: [3]int = {*}1
`, false)
}

@(test)
expand_array_round_trip :: proc(t: ^testing.T) {
	expect_round_trip(t, EXPAND_ARRAY, "Use scalar for array literal", "1, 1", `package test

a: [3]int = {*}1
`)
}

@(test)
expand_or_else_decl :: proc(t: ^testing.T) {
	expect_expand(t, EXPAND_OR_ELSE, `package test

f :: proc(m: map[int]int, k: int) -> int {
	x := m[k] or_{*}else 0
	return x
}
`, `package test

f :: proc(m: map[int]int, k: int) -> int {
	x, ok := m[k]
	if !ok {
		x = 0
	}
	return x
}
`)
}

@(test)
expand_or_else_return :: proc(t: ^testing.T) {
	expect_expand(t, EXPAND_OR_ELSE, `package test

f :: proc(m: map[int]int, k: int) -> int {
	return m[k] or_{*}else 0
}
`, `package test

f :: proc(m: map[int]int, k: int) -> int {
	if v, ok := m[k]; ok {
		return v
	}
	return 0
}
`)
}

@(test)
expand_or_else_assign :: proc(t: ^testing.T) {
	expect_expand(t, EXPAND_OR_ELSE, `package test

f :: proc(a: any) -> int {
	x := 0
	x = a.(int) or_{*}else 1
	return x
}
`, `package test

f :: proc(a: any) -> int {
	x := 0
	if v, ok := a.(int); ok {
		x = v
	} else {
		x = 1
	}
	return x
}
`)
}

@(test)
expand_or_else_argument :: proc(t: ^testing.T) {
	expect_no_expand(t, EXPAND_OR_ELSE, `package test

f :: proc(m: map[int]int, k: int) {
	g(m[k] or_{*}else 0)
}
`)
}

@(test)
expand_or_else_round_trip :: proc(t: ^testing.T) {
	expect_round_trip(t, EXPAND_OR_ELSE, "Use or_else", "ok {", `package test

f :: proc(a: any) -> int {
	x := 0
	x = a.(int) or_{*}else 1
	return x
}
`)
}

@(test)
expand_or_return_error :: proc(t: ^testing.T) {
	expect_expand(t, EXPAND_OR_RETURN, `package test

My_Error :: enum { None, Bad }

f :: proc() -> (int, My_Error) { return 1, .None }

main :: proc() -> (int, My_Error) {
	x := f() or_{*}return
	return x, nil
}
`, `package test

My_Error :: enum { None, Bad }

f :: proc() -> (int, My_Error) { return 1, .None }

main :: proc() -> (int, My_Error) {
	x, err := f()
	if err != nil {
		return 0, err
	}
	return x, nil
}
`)
}

@(test)
expand_or_return_bool_named_results :: proc(t: ^testing.T) {
	expect_expand(t, EXPAND_OR_RETURN, `package test

f :: proc() -> (int, bool) { return 1, true }

main :: proc() -> (n: int, ok: bool) {
	x := f() or_{*}return
	return x, true
}
`, `package test

f :: proc() -> (int, bool) { return 1, true }

main :: proc() -> (n: int, ok: bool) {
	x, ok2 := f()
	if !ok2 {
		return 0, false
	}
	return x, true
}
`)
}

@(test)
expand_or_return_statement :: proc(t: ^testing.T) {
	expect_expand(t, EXPAND_OR_RETURN, `package test

My_Error :: enum { None, Bad }

f :: proc() -> My_Error { return .None }

main :: proc() -> My_Error {
	f() or_{*}return
	return nil
}
`, `package test

My_Error :: enum { None, Bad }

f :: proc() -> My_Error { return .None }

main :: proc() -> My_Error {
	err := f()
	if err != nil {
		return err
	}
	return nil
}
`)
}

@(test)
expand_or_return_inside_expression :: proc(t: ^testing.T) {
	expect_no_expand(t, EXPAND_OR_RETURN, `package test

f :: proc() -> (int, bool) { return 1, true }

main :: proc() -> bool {
	x := 1 + f() or_{*}return
	return x > 0
}
`)
}

@(test)
expand_or_return_round_trip :: proc(t: ^testing.T) {
	expect_round_trip(t, EXPAND_OR_RETURN, "Use or_return", "err != nil", `package test

My_Error :: enum { None, Bad }

f :: proc() -> (int, My_Error) { return 1, .None }

main :: proc() -> My_Error {
	x := f() or_{*}return
	return nil
}
`)
}

@(test)
expand_range_half :: proc(t: ^testing.T) {
	expect_expand(t, C_STYLE_FOR, `package test

f :: proc(xs: []int) {
	for i {*}in 0..<len(xs) {
		g(xs[i])
	}
}
`, `package test

f :: proc(xs: []int) {
	for i := 0; i < len(xs); i += 1 {
		g(xs[i])
	}
}
`)
}

@(test)
expand_range_full_labeled :: proc(t: ^testing.T) {
	expect_expand(t, C_STYLE_FOR, `package test

f :: proc(n: int) {
	outer: for i in 1{*}..=n {
	}
}
`, `package test

f :: proc(n: int) {
	outer: for i := 1; i <= n; i += 1 {
	}
}
`)
}

@(test)
expand_range_reverse :: proc(t: ^testing.T) {
	expect_no_expand(t, C_STYLE_FOR, `package test

f :: proc(n: int) {
	#reverse for i in 0..{*}<n {
	}
}
`)
}

@(test)
expand_range_two_vals :: proc(t: ^testing.T) {
	expect_no_expand(t, C_STYLE_FOR, `package test

f :: proc(xs: []int) {
	for i, j in {*}xs {
	}
}
`)
}

@(test)
expand_range_round_trip :: proc(t: ^testing.T) {
	expect_round_trip(t, C_STYLE_FOR, "Use range loop", "i < len", `package test

f :: proc(xs: []int) {
	for i {*}in 0..<len(xs) {
		g(xs[i])
	}
}
`)
}

// Applies expand, puts the cursor before marker in the result and expects simplify not to offer the
// inverse.
expect_no_inverse :: proc(t: ^testing.T, expand, simplify, marker, main: string) {
	source := test.Source{main = main, config = {enable_code_action_expand = true, enable_lint_simplify = true}}
	expanded, ok := test.apply_action(t, &source, expand)
	if !ok {
		return
	}
	cursor := strings.concatenate({"{*}", marker}, context.temp_allocator)
	back := test.Source {
		main   = strings.replace(expanded, marker, cursor, 1, context.temp_allocator) or_else expanded,
		config = {enable_lint_simplify = true},
	}
	test.expect_action_missing(t, &back, simplify)
}

@(test)
expand_or_else_call_fallback :: proc(t: ^testing.T) {
	expect_expand(t, EXPAND_OR_ELSE, `package test

g :: proc() -> int { return 0 }

f :: proc(m: map[int]int, k: int) -> int {
	x := m[k] or_{*}else g()
	return x
}
`, `package test

g :: proc() -> int { return 0 }

f :: proc(m: map[int]int, k: int) -> int {
	x, ok := m[k]
	if !ok {
		x = g()
	}
	return x
}
`)
}

// The declaration form expands to a plain `if`, which the or_else rule does not read back.
@(test)
expand_or_else_decl_is_one_way :: proc(t: ^testing.T) {
	expect_no_inverse(t, EXPAND_OR_ELSE, "Use or_else", "ok {", `package test

f :: proc(m: map[int]int, k: int) -> int {
	x := m[k] or_{*}else 0
	return x
}
`)
}

@(test)
expand_or_else_value_name_taken_round_trip :: proc(t: ^testing.T) {
	expect_round_trip(t, EXPAND_OR_ELSE, "Use or_else", "ok {", `package test

f :: proc(a: any) -> int {
	v := 0
	x := 0
	x = a.(int) or_{*}else 1
	return x + v
}
`)
}

@(test)
expand_or_return_error_name_taken :: proc(t: ^testing.T) {
	expect_expand(t, EXPAND_OR_RETURN, `package test

My_Error :: enum { None, Bad }

f :: proc() -> (int, My_Error) { return 1, .None }

main :: proc() -> (int, My_Error) {
	err := My_Error.None
	x := f() or_{*}return
	return x, err
}
`, `package test

My_Error :: enum { None, Bad }

f :: proc() -> (int, My_Error) { return 1, .None }

main :: proc() -> (int, My_Error) {
	err := My_Error.None
	x, err2 := f()
	if err2 != nil {
		return 0, err2
	}
	return x, err
}
`)
}

@(test)
expand_or_return_statement_discards_other_results :: proc(t: ^testing.T) {
	expect_expand(t, EXPAND_OR_RETURN, `package test

My_Error :: enum { None, Bad }

f :: proc() -> (int, int, My_Error) { return 1, 2, .None }

main :: proc() -> My_Error {
	f() or_{*}return
	return nil
}
`, `package test

My_Error :: enum { None, Bad }

f :: proc() -> (int, int, My_Error) { return 1, 2, .None }

main :: proc() -> My_Error {
	_, _, err := f()
	if err != nil {
		return err
	}
	return nil
}
`)
}

@(test)
expand_or_return_two_names :: proc(t: ^testing.T) {
	expect_no_expand(t, EXPAND_OR_RETURN, `package test

My_Error :: enum { None, Bad }

f :: proc() -> (int, int, My_Error) { return 1, 2, .None }

main :: proc() -> My_Error {
	a, b := f() or_{*}return
	return nil
}
`)
}

@(test)
expand_range_round_trip_bounds :: proc(t: ^testing.T) {
	for bounds in ([?]string{"0..<n", "0..=n", "a..<b"}) {
		main := strings.concatenate({`package test

f :: proc(n, a, b: int) {
	for i {*}in `, bounds, ` {
	}
}
`}, context.temp_allocator)
		expect_round_trip(t, C_STYLE_FOR, "Use range loop", "i <", main)
	}
}

@(test)
expand_range_do_body_round_trip :: proc(t: ^testing.T) {
	expect_round_trip(t, C_STYLE_FOR, "Use range loop", "i <", `package test

f :: proc(n: int) {
	for i {*}in 0..<n do g(i)
}
`)
}

@(test)
expand_range_over_slice :: proc(t: ^testing.T) {
	expect_no_expand(t, C_STYLE_FOR, `package test

f :: proc(xs: []int) {
	for x {*}in xs {
	}
}
`)
}

// The range rule refuses a loop whose variable the body writes, so this expansion has no inverse.
@(test)
expand_range_mutated_var_is_one_way :: proc(t: ^testing.T) {
	expect_no_inverse(t, C_STYLE_FOR, "Use range loop", "i <", `package test

f :: proc(n: int) {
	for i {*}in 0..<n {
		i += 1
	}
}
`)
}

@(test)
expand_array_scalar_round_trip :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

a: [3]int = {1, {*}1, 1}
`,
		config = {enable_code_action_expand = true, enable_lint_simplify = true},
	}
	test.expect_action_round_trip(t, &source, {"Use scalar for array literal", EXPAND_ARRAY}, {"1\n"})
}

@(test)
expand_array_float_scalar_round_trip :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

h: [2]f32 = {0.5, 0.{*}5}
`,
		config = {enable_code_action_expand = true, enable_lint_simplify = true},
	}
	test.expect_action_round_trip(t, &source, {"Use scalar for array literal", EXPAND_ARRAY}, {"0.5\n"})
}

@(test)
expand_array_single_element :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

a: [1]int = {{*}1}
`,
		config = {enable_lint_simplify = true},
	}
	test.expect_action_missing(t, &source, "Use scalar for array literal")
}
