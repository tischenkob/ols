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
	return true
}
`)
}

@(test)
add_ok_result_none_nested_return :: proc(t: ^testing.T) {
	expect_add_ok_result(t, `package test

f{*} :: proc(x: int) {
	for i in 0 ..< x {
		if i == 0 {
			return
		}
	}
}
`, `package test

f :: proc(x: int) -> bool {
	for i in 0 ..< x {
		if i == 0 {
			return true
		}
	}
	return true
}
`)
}

@(test)
add_ok_result_none_already_ends_in_return :: proc(t: ^testing.T) {
	expect_add_ok_result(t, `package test

f{*} :: proc(x: int) {
	if x == 0 {
		return
	}
	return
}
`, `package test

f :: proc(x: int) -> bool {
	if x == 0 {
		return true
	}
	return true
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

@(test)
add_ok_result_nested_returns :: proc(t: ^testing.T) {
	expect_add_ok_result(t, `package test

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
`, `package test

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
`)
}

@(test)
add_ok_result_appends_to_an_existing_bool :: proc(t: ^testing.T) {
	expect_add_ok_result(t, `package test

f{*} :: proc() -> bool {
	return true
}
`, `package test

f :: proc() -> (bool, bool) {
	return true, true
}
`)
}

@(test)
add_ok_result_leaves_callers_alone :: proc(t: ^testing.T) {
	expect_add_ok_result(t, `package test

f{*} :: proc() -> int {
	return 1
}

main :: proc() {
	x := f()
}
`, `package test

f :: proc() -> (int, bool) {
	return 1, true
}

main :: proc() {
	x := f()
}
`)
}

@(test)
add_ok_result_refused_optional_ok :: proc(t: ^testing.T) {
	expect_no_add_ok_result(t, `package test

f{*} :: proc() -> (int, bool) #optional_ok {
	return 1, true
}
`)
}

@(test)
add_ok_result_twice_appends_a_second_bool :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f{*} :: proc() -> int {
	return 1
}
`,
		config = {enable_code_action_add_ok_result = true},
	}

	test.expect_action_chain(t, &source, {ADD_OK_RESULT_ACTION, ADD_OK_RESULT_ACTION}, `package test

f :: proc() -> (int, bool, bool) {
	return 1, true, true
}
`)
}
