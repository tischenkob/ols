package tests

import "core:testing"

import test "src:testing"

ADD_OK_RESULT_ACTION :: "Add ok result"

expect_add_ok_result :: proc(t: ^testing.T, main, expected: string) {
	source := test.Source{main = main, config = {enable_code_action_add_ok_result = true}}
	test.expect_action_applied(t, &source, ADD_OK_RESULT_ACTION, expected)
}

expect_no_add_ok_result :: proc(t: ^testing.T, main: string, enabled := true) {
	source := test.Source{main = main, config = {enable_code_action_add_ok_result = enabled}}
	test.expect_action_missing(t, &source, ADD_OK_RESULT_ACTION)
}

@(test)
add_ok_result_single :: proc(t: ^testing.T) {
	expect_add_ok_result(t, `package test

f{*} :: proc(x: int) -> int {
	return x
}
`, `package test

f :: proc(x: int) -> (int, bool) {
	return x, true
}
`)
}

@(test)
add_ok_result_from_result_list :: proc(t: ^testing.T) {
	expect_add_ok_result(t, `package test

f :: proc(x: int) -> in{*}t {
	return x
}
`, `package test

f :: proc(x: int) -> (int, bool) {
	return x, true
}
`)
}

@(test)
add_ok_result_named :: proc(t: ^testing.T) {
	expect_add_ok_result(t, `package test

f{*} :: proc() -> (a: int, b: string) {
	if a == 0 {
		return
	}
	return 1, "x"
}
`, `package test

f :: proc() -> (a: int, b: string, ok: bool) {
	if a == 0 {
		return
	}
	return 1, "x", true
}
`)
}

@(test)
add_ok_result_named_collision :: proc(t: ^testing.T) {
	expect_add_ok_result(t, `package test

f{*} :: proc(ok: int) -> (a: int) {
	return 1
}
`, `package test

f :: proc(ok: int) -> (a: int, ok2: bool) {
	return 1, true
}
`)
}

@(test)
add_ok_result_none :: proc(t: ^testing.T) {
	expect_add_ok_result(t, `package test

f{*} :: proc(x: int) {
	if x == 0 {
		return
	}
}
`, `package test

f :: proc(x: int) -> bool {
	if x == 0 {
		return true
	}
}
`)
}

@(test)
add_ok_result_skips_nested_proc :: proc(t: ^testing.T) {
	expect_add_ok_result(t, `package test

f{*} :: proc() -> int {
	g := proc() -> int {
		return 2
	}
	return 1
}
`, `package test

f :: proc() -> (int, bool) {
	g := proc() -> int {
		return 2
	}
	return 1, true
}
`)
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
