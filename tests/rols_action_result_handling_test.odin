package tests

import "core:testing"

import test "src:testing"

OR_RETURN_ACTION :: "Add or_return"
OR_ELSE_ACTION :: "Add or_else"
HANDLE_IF_ACTION :: "Handle result with if"
DISCARD_ACTION :: "Discard result"

expect_result_action :: proc(t: ^testing.T, action, main, expected: string) {
	source := test.Source{main = main, config = {enable_code_action_result_handling = true}}
	test.expect_action_applied(t, &source, action, expected)
}

expect_no_result_action :: proc(t: ^testing.T, action, main: string, enabled := true) {
	source := test.Source{main = main, config = {enable_code_action_result_handling = enabled}}
	test.expect_action_missing(t, &source, action)
}

@(test)
result_or_return_value :: proc(t: ^testing.T) {
	expect_result_action(t, OR_RETURN_ACTION, `package test

f :: proc() -> (int, bool) { return 1, true }

main :: proc() -> bool {
	x := f({*})
	return x > 0
}
`, `package test

f :: proc() -> (int, bool) { return 1, true }

main :: proc() -> bool {
	x := f() or_return
	return x > 0
}
`)
}

@(test)
result_or_return_statement :: proc(t: ^testing.T) {
	expect_result_action(t, OR_RETURN_ACTION, `package test

f :: proc() -> (int, bool) { return 1, true }

main :: proc() -> bool {
	f({*})
	return true
}
`, `package test

f :: proc() -> (int, bool) { return 1, true }

main :: proc() -> bool {
	f() or_return
	return true
}
`)
}

@(test)
result_or_return_error :: proc(t: ^testing.T) {
	expect_result_action(t, OR_RETURN_ACTION, `package test

My_Error :: enum { None, Bad }

f :: proc() -> (int, My_Error) { return 1, .None }

main :: proc() -> My_Error {
	x := f({*})
	return nil
}
`, `package test

My_Error :: enum { None, Bad }

f :: proc() -> (int, My_Error) { return 1, .None }

main :: proc() -> My_Error {
	x := f() or_return
	return nil
}
`)
}

@(test)
result_or_return_union :: proc(t: ^testing.T) {
	expect_result_action(t, OR_RETURN_ACTION, `package test

Parse_Error :: enum { None, Bad }
Error :: union { Parse_Error, Allocator_Error }

f :: proc() -> (int, Parse_Error) { return 1, .None }

main :: proc() -> Error {
	x := f({*})
	return nil
}
`, `package test

Parse_Error :: enum { None, Bad }
Error :: union { Parse_Error, Allocator_Error }

f :: proc() -> (int, Parse_Error) { return 1, .None }

main :: proc() -> Error {
	x := f() or_return
	return nil
}
`)
}

@(test)
result_or_return_no_results :: proc(t: ^testing.T) {
	expect_no_result_action(t, OR_RETURN_ACTION, `package test

f :: proc() -> (int, bool) { return 1, true }

main :: proc() {
	x := f({*})
}
`)
}

@(test)
result_or_return_mismatch :: proc(t: ^testing.T) {
	expect_no_result_action(t, OR_RETURN_ACTION, `package test

My_Error :: enum { None, Bad }

f :: proc() -> (int, bool) { return 1, true }

main :: proc() -> My_Error {
	x := f({*})
	return nil
}
`)
}

@(test)
result_or_return_already :: proc(t: ^testing.T) {
	expect_no_result_action(t, OR_RETURN_ACTION, `package test

f :: proc() -> (int, bool) { return 1, true }

main :: proc() -> bool {
	x := f({*}) or_return
	return x > 0
}
`)
}

@(test)
result_or_else_int :: proc(t: ^testing.T) {
	expect_result_action(t, OR_ELSE_ACTION, `package test

f :: proc() -> (int, bool) { return 1, true }

main :: proc() {
	x := f({*})
}
`, `package test

f :: proc() -> (int, bool) { return 1, true }

main :: proc() {
	x := f() or_else 0
}
`)
}

@(test)
result_or_else_struct :: proc(t: ^testing.T) {
	expect_result_action(t, OR_ELSE_ACTION, `package test

Point :: struct { x, y: int }

f :: proc() -> (Point, bool) { return {}, true }

main :: proc() {
	p := f({*})
}
`, `package test

Point :: struct { x, y: int }

f :: proc() -> (Point, bool) { return {}, true }

main :: proc() {
	p := f() or_else {}
}
`)
}

@(test)
result_or_else_three_results :: proc(t: ^testing.T) {
	expect_no_result_action(t, OR_ELSE_ACTION, `package test

f :: proc() -> (int, int, bool) { return 1, 2, true }

main :: proc() {
	a, b := f({*})
}
`)
}

@(test)
result_or_else_statement :: proc(t: ^testing.T) {
	expect_no_result_action(t, OR_ELSE_ACTION, `package test

f :: proc() -> (int, bool) { return 1, true }

main :: proc() {
	f({*})
}
`)
}

@(test)
result_if_bool_bare_return :: proc(t: ^testing.T) {
	expect_result_action(t, HANDLE_IF_ACTION, `package test

f :: proc() -> (int, bool) { return 1, true }

main :: proc() {
	x := f({*})
}
`, `package test

f :: proc() -> (int, bool) { return 1, true }

main :: proc() {
	x, ok := f()
	if !ok {
		return
	}
}
`)
}

@(test)
result_if_bool_zeros :: proc(t: ^testing.T) {
	expect_result_action(t, HANDLE_IF_ACTION, `package test

f :: proc() -> (int, bool) { return 1, true }

main :: proc() -> (int, bool) {
	x := f({*})
	return x, true
}
`, `package test

f :: proc() -> (int, bool) { return 1, true }

main :: proc() -> (int, bool) {
	x, ok := f()
	if !ok {
		return 0, false
	}
	return x, true
}
`)
}

@(test)
result_if_error_propagates :: proc(t: ^testing.T) {
	expect_result_action(t, HANDLE_IF_ACTION, `package test

My_Error :: enum { None, Bad }

f :: proc() -> (string, My_Error) { return "", .None }

main :: proc() -> My_Error {
	s := f({*})
	return nil
}
`, `package test

My_Error :: enum { None, Bad }

f :: proc() -> (string, My_Error) { return "", .None }

main :: proc() -> My_Error {
	s, err := f()
	if err != nil {
		return err
	}
	return nil
}
`)
}

@(test)
result_if_error_other_results :: proc(t: ^testing.T) {
	expect_result_action(t, HANDLE_IF_ACTION, `package test

My_Error :: enum { None, Bad }

f :: proc() -> (string, My_Error) { return "", .None }

main :: proc() -> (string, bool) {
	s := f({*})
	return s, true
}
`, `package test

My_Error :: enum { None, Bad }

f :: proc() -> (string, My_Error) { return "", .None }

main :: proc() -> (string, bool) {
	s, err := f()
	if err != nil {
		return "", false
	}
	return s, true
}
`)
}

@(test)
result_if_name_collision :: proc(t: ^testing.T) {
	expect_result_action(t, HANDLE_IF_ACTION, `package test

f :: proc() -> (int, bool) { return 1, true }

main :: proc() {
	ok := true
	x := f({*})
}
`, `package test

f :: proc() -> (int, bool) { return 1, true }

main :: proc() {
	ok := true
	x, ok2 := f()
	if !ok2 {
		return
	}
}
`)
}

@(test)
result_if_not_decl :: proc(t: ^testing.T) {
	expect_no_result_action(t, HANDLE_IF_ACTION, `package test

f :: proc() -> (int, bool) { return 1, true }

main :: proc() {
	x, y := f({*})
}
`)
}

@(test)
result_discard_one :: proc(t: ^testing.T) {
	expect_result_action(t, DISCARD_ACTION, `package test

f :: proc() -> int { return 1 }

main :: proc() {
	f({*})
}
`, `package test

f :: proc() -> int { return 1 }

main :: proc() {
	_ = f()
}
`)
}

@(test)
result_discard_two :: proc(t: ^testing.T) {
	expect_result_action(t, DISCARD_ACTION, `package test

f :: proc() -> (int, bool) { return 1, true }

main :: proc() {
	f({*})
}
`, `package test

f :: proc() -> (int, bool) { return 1, true }

main :: proc() {
	_, _ = f()
}
`)
}

@(test)
result_discard_no_results :: proc(t: ^testing.T) {
	expect_no_result_action(t, DISCARD_ACTION, `package test

f :: proc() {}

main :: proc() {
	f({*})
}
`)
}

@(test)
result_handling_disabled :: proc(t: ^testing.T) {
	expect_no_result_action(t, DISCARD_ACTION, `package test

f :: proc() -> int { return 1 }

main :: proc() {
	f({*})
}
`, enabled = false)
}
