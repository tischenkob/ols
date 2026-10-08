package tests

import "core:testing"

import test "src:testing"

ADD_OK_RESULT_ACTION :: "Add ok result"

expect_add_ok_result :: proc(t: ^testing.T, main, expected: string) {
	source := test.Source {
		main = main,
		config = {enable_code_action_add_ok_result = true},
	}
	test.expect_action_applied(t, &source, ADD_OK_RESULT_ACTION, expected)
}

expect_no_add_ok_result :: proc(t: ^testing.T, main: string, enabled := true) {
	source := test.Source {
		main = main,
		config = {enable_code_action_add_ok_result = enabled},
	}
	test.expect_action_missing(t, &source, ADD_OK_RESULT_ACTION)
}

@(test)
add_ok_result_single :: proc(t: ^testing.T) {
	expect_add_ok_result(
		t,
		`package test

f{*} :: proc(x: int) -> int {
	return x
}
`,
		`package test

f :: proc(x: int) -> (int, bool) {
	return x, true
}
`,
	)
}

@(test)
add_ok_result_from_result_list :: proc(t: ^testing.T) {
	expect_add_ok_result(
		t,
		`package test

f :: proc(x: int) -> in{*}t {
	return x
}
`,
		`package test

f :: proc(x: int) -> (int, bool) {
	return x, true
}
`,
	)
}

@(test)
add_ok_result_named :: proc(t: ^testing.T) {
	expect_add_ok_result(
		t,
		`package test

f{*} :: proc() -> (a: int, b: string) {
	if a == 0 {
		return
	}
	return 1, "x"
}
`,
		`package test

f :: proc() -> (a: int, b: string, ok: bool) {
	if a == 0 {
		return
	}
	return 1, "x", true
}
`,
	)
}

@(test)
add_ok_result_named_collision :: proc(t: ^testing.T) {
	expect_add_ok_result(
		t,
		`package test

f{*} :: proc(ok: int) -> (a: int) {
	return 1
}
`,
		`package test

f :: proc(ok: int) -> (a: int, ok2: bool) {
	return 1, true
}
`,
	)
}

@(test)
add_ok_result_none :: proc(t: ^testing.T) {
	expect_add_ok_result(
		t,
		`package test

f{*} :: proc(x: int) {
	if x == 0 {
		return
	}
}
`,
		`package test

f :: proc(x: int) -> bool {
	if x == 0 {
		return true
	}
	return true
}
`,
	)
}

@(test)
add_ok_result_none_nested_return :: proc(t: ^testing.T) {
	expect_add_ok_result(
		t,
		`package test

f{*} :: proc(x: int) {
	for i in 0 ..< x {
		if i == 0 {
			return
		}
	}
}
`,
		`package test

f :: proc(x: int) -> bool {
	for i in 0 ..< x {
		if i == 0 {
			return true
		}
	}
	return true
}
`,
	)
}

@(test)
add_ok_result_none_already_ends_in_return :: proc(t: ^testing.T) {
	expect_add_ok_result(
		t,
		`package test

f{*} :: proc(x: int) {
	if x == 0 {
		return
	}
	return
}
`,
		`package test

f :: proc(x: int) -> bool {
	if x == 0 {
		return true
	}
	return true
}
`,
	)
}

@(test)
add_ok_result_skips_nested_proc :: proc(t: ^testing.T) {
	expect_add_ok_result(
		t,
		`package test

f{*} :: proc() -> int {
	g := proc() -> int {
		return 2
	}
	return 1
}
`,
		`package test

f :: proc() -> (int, bool) {
	g := proc() -> int {
		return 2
	}
	return 1, true
}
`,
	)
}

@(test)
add_ok_result_disabled :: proc(t: ^testing.T) {
	expect_no_add_ok_result(t, `package test

f{*} :: proc() -> int {
	return 1
}
`, false)
}

@(test)
add_ok_result_not_on_body :: proc(t: ^testing.T) {
	expect_no_add_ok_result(t, `package test

f :: proc() -> int {
	return {*}1
}
`)
}

@(test)
add_ok_result_nested_returns :: proc(t: ^testing.T) {
	expect_add_ok_result(
		t,
		`package test

f{*} :: proc(x: int) -> int {
	if x == 0 {
		return 1
	}
	for i in 0 ..< x {
		return i
	}
	switch x {
	case 1:
		return 2
	}
	return 3
}
`,
		`package test

f :: proc(x: int) -> (int, bool) {
	if x == 0 {
		return 1, true
	}
	for i in 0 ..< x {
		return i, true
	}
	switch x {
	case 1:
		return 2, true
	}
	return 3, true
}
`,
	)
}

@(test)
add_ok_result_refused_on_a_bool_result :: proc(t: ^testing.T) {
	expect_no_add_ok_result(t, `package test

f{*} :: proc() -> bool {
	return true
}
`)
}

@(test)
add_ok_result_refused_caller_as_argument :: proc(t: ^testing.T) {
	expect_no_add_ok_result(
		t,
		`package test

f{*} :: proc() -> int {
	return 1
}

g :: proc(x: int) {}

main :: proc() {
	g(f())
}
`,
	)
}

@(test)
add_ok_result_refused_optional_ok :: proc(t: ^testing.T) {
	expect_no_add_ok_result(t, `package test

f{*} :: proc() -> (int, bool) #optional_ok {
	return 1, true
}
`)
}

// Corpus: tina src/api.odin:218, see docs/corpus-validation.md.
@(test)
add_ok_result_updates_callers :: proc(t: ^testing.T) {
	// Withholding the action while callers exist would also be correct; then assert expect_no_add_ok_result.
	expect_add_ok_result(
		t,
		`package test

get{*} :: proc(x: int) -> int {
	return x
}

use :: proc() {
	v := get(1)
	_ = v
}
`,
		`package test

get :: proc(x: int) -> (int, bool) {
	return x, true
}

use :: proc() {
	v, _ := get(1)
	_ = v
}
`,
	)
}

// Corpus: reduced (odin-http review), see docs/corpus-validation.md.
@(test)
add_ok_result_not_offered_with_or_return_on_unnamed_results :: proc(t: ^testing.T) {
	expect_no_add_ok_result(
		t,
		`package test

Err :: enum {
	None,
	Bad,
}

g :: proc(x: int) -> Err {
	return .None
}

h{*} :: proc(x: int) -> Err {
	g(x) or_return
	return .None
}
`,
	)
}

@(test)
add_ok_result_updates_multi_value_callers :: proc(t: ^testing.T) {
	expect_add_ok_result(
		t,
		`package test

f{*} :: proc() -> (int, string) {
	return 1, "a"
}

main :: proc() {
	a, b := f()
	a, b = f()
	if c, d := f(); c > 0 {
		_ = d
	}
}
`,
		`package test

f :: proc() -> (int, string, bool) {
	return 1, "a", true
}

main :: proc() {
	a, b, _ := f()
	a, b, _ = f()
	if c, d, _ := f(); c > 0 {
		_ = d
	}
}
`,
	)
}

@(test)
add_ok_result_updates_assignment_caller :: proc(t: ^testing.T) {
	expect_add_ok_result(
		t,
		`package test

f{*} :: proc() -> int {
	return 1
}

main :: proc() {
	v := 0
	v = f()
	_ = v
}
`,
		`package test

f :: proc() -> (int, bool) {
	return 1, true
}

main :: proc() {
	v := 0
	v, _ = f()
	_ = v
}
`,
	)
}

@(test)
add_ok_result_keeps_statement_callers :: proc(t: ^testing.T) {
	expect_add_ok_result(
		t,
		`package test

f{*} :: proc() {
}

main :: proc() {
	f()
	defer f()
}
`,
		`package test

f :: proc() -> bool {
	return true
}

main :: proc() {
	f()
	defer f()
}
`,
	)
}

@(test)
add_ok_result_refused_caller_returns_the_result :: proc(t: ^testing.T) {
	expect_no_add_ok_result(
		t,
		`package test

f{*} :: proc() -> int {
	return 1
}

g :: proc() -> int {
	return f()
}
`,
	)
}

@(test)
add_ok_result_refused_typed_caller :: proc(t: ^testing.T) {
	expect_no_add_ok_result(
		t,
		`package test

f{*} :: proc() -> int {
	return 1
}

main :: proc() {
	v: int = f()
	_ = v
}
`,
	)
}

@(test)
add_ok_result_refused_procedure_value :: proc(t: ^testing.T) {
	expect_no_add_ok_result(t, `package test

f{*} :: proc() -> int {
	return 1
}

main :: proc() {
	g := f
	_ = g
}
`)
}

@(test)
add_ok_result_refused_local_procedure_with_caller :: proc(t: ^testing.T) {
	expect_no_add_ok_result(
		t,
		`package test

main :: proc() {
	f{*} :: proc() -> int {
		return 1
	}
	v := f()
	_ = v
}
`,
	)
}

@(test)
add_ok_result_updates_caller_in_other_file :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

get{*} :: proc(x: int) -> int {
	return x
}
`,
		files = {{"b.odin", `package test

main :: proc() {
	v := get(1)
	_ = v
}
`}},
		config = {enable_code_action_add_ok_result = true},
	}
	test.expect_action_applied_files(
		t,
		&source,
		ADD_OK_RESULT_ACTION,
		{
			{"main.odin", `package test

get :: proc(x: int) -> (int, bool) {
	return x, true
}
`},
			{"b.odin", `package test

main :: proc() {
	v, _ := get(1)
	_ = v
}
`},
		},
	)
}

@(test)
add_ok_result_refused_caller_in_other_file_as_argument :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

get{*} :: proc(x: int) -> int {
	return x
}
`,
		files = {{"b.odin", `package test

main :: proc() {
	println(get(1))
}
`}},
		config = {enable_code_action_add_ok_result = true},
	}
	test.expect_action_missing(t, &source, ADD_OK_RESULT_ACTION)
}

@(test)
add_ok_result_keeps_comments_in_the_result_list :: proc(t: ^testing.T) {
	expect_add_ok_result(
		t,
		`package test

Error :: enum {
	None,
}

f{*} :: proc() -> (
	// first
	int, // second
	Error,
) {
	return 1, .None
}
`,
		`package test

Error :: enum {
	None,
}

f :: proc() -> (
	// first
	int, // second
	Error, bool,
) {
	return 1, .None, true
}
`,
	)
}

@(test)
add_ok_result_refused_with_or_return_on_named_results :: proc(t: ^testing.T) {
	// or_return would assign the error to the new bool result.
	expect_no_add_ok_result(
		t,
		`package test

Err :: enum {
	None,
	Bad,
}

g :: proc(x: int) -> Err {
	return .None
}

h{*} :: proc(x: int) -> (err: Err) {
	g(x) or_return
	return .None
}
`,
	)
}

@(test)
add_ok_result_already_named_ok :: proc(t: ^testing.T) {
	expect_no_add_ok_result(t, `package test

named{*} :: proc(h: int) -> (v: int, ok: bool) {
	return h, true
}
`)
}

@(test)
add_ok_result_already_unnamed_bool :: proc(t: ^testing.T) {
	expect_no_add_ok_result(
		t,
		`package test

Entry :: struct {}

find :: proc(h: int) -> (^Entry, b{*}ool) {
	return nil, false
}
`,
	)
}

@(test)
add_ok_result_already_b32 :: proc(t: ^testing.T) {
	expect_no_add_ok_result(t, `package test

check{*} :: proc(h: int) -> (v: int, found: b32) {
	return h, true
}
`)
}

@(test)
add_ok_result_refused_on_empty_results :: proc(t: ^testing.T) {
	expect_no_add_ok_result(t, `package test

f{*} :: proc() -> () {
	return
}
`)
}

@(test)
add_ok_result_distinct_bool :: proc(t: ^testing.T) {
	expect_no_add_ok_result(
		t,
		`package test

My_Ok :: distinct bool

f{*} :: proc(x: int) -> (int, My_Ok) {
	return x, true
}
`,
	)
}

// The action edits one declaration, so a procedure with a platform variant gets no ok result.
@(test)
add_ok_result_skips_platform_variant :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+build !windows
package test

f{*} :: proc(x: int) -> int {
	return x
}

g :: proc() -> int {
	v := f(1)
	return v
}
`,
		files = {
			{"f_windows.odin", "#+build windows\npackage test\n\nf :: proc(x: int) -> int {\n\treturn x + 1\n}\n"},
		},
		config = {enable_code_action_add_ok_result = true},
	}
	test.expect_action_missing(t, &source, ADD_OK_RESULT_ACTION)
}

@(test)
add_ok_result_local_procedure_ignores_other_declarations :: proc(t: ^testing.T) {
	expect_add_ok_result(
		t,
		`package test

main :: proc() {
	f{*} :: proc() -> int {
		return 1
	}
}

other :: proc() {
	f := 2
	_ = f
}
`,
		`package test

main :: proc() {
	f :: proc() -> (int, bool) {
		return 1, true
	}
}

other :: proc() {
	f := 2
	_ = f
}
`,
	)
}

@(test)
add_ok_result_updates_named_argument_caller :: proc(t: ^testing.T) {
	expect_add_ok_result(
		t,
		`package test

f{*} :: proc(x: int, y := 2) -> int {
	return x + y
}

main :: proc() {
	v := f(x = 1)
	_ = v
}
`,
		`package test

f :: proc(x: int, y := 2) -> (int, bool) {
	return x + y, true
}

main :: proc() {
	v, _ := f(x = 1)
	_ = v
}
`,
	)
}

@(test)
add_ok_result_refused_procedure_value_in_callee :: proc(t: ^testing.T) {
	expect_no_add_ok_result(
		t,
		`package test

f{*} :: proc() -> int {
	return 1
}

h :: proc(g: proc() -> int) -> proc() -> int {
	return g
}

main :: proc() {
	v := h(f)()
	_ = v
}
`,
	)
}
