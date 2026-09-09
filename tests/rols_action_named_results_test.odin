package tests

import "core:testing"

import test "src:testing"

NAMED_RESULTS_ACTION :: "Use named results"

expect_named_results :: proc(t: ^testing.T, main, expected: string) {
	source := test.Source{main = main, config = {enable_code_action_named_results = true}}
	test.expect_action_applied(t, &source, NAMED_RESULTS_ACTION, expected)
}

expect_no_named_results :: proc(t: ^testing.T, main: string, enabled := true) {
	source := test.Source{main = main, config = {enable_code_action_named_results = enabled}}
	test.expect_action_missing(t, &source, NAMED_RESULTS_ACTION)
}

@(test)
named_results_single :: proc(t: ^testing.T) {
	expect_named_results(t, `package test

f :: proc(x: int) -> in{*}t {
	return x
}
`, `package test

f :: proc(x: int) -> (result: int) {
	return x
}
`)
}

@(test)
named_results_pair :: proc(t: ^testing.T) {
	expect_named_results(t, `package test

f :: pr{*}oc() -> (int, bool) {
	return 1, true
}
`, `package test

f :: proc() -> (result: int, ok: bool) {
	return 1, true
}
`)
}

@(test)
named_results_types :: proc(t: ^testing.T) {
	expect_named_results(t, `package test

Point :: struct { x, y: int }
My_Error :: enum { None, Bad }

f :: proc() -> (^Point, My_Error{*}) {
	return nil, .None
}
`, `package test

Point :: struct { x, y: int }
My_Error :: enum { None, Bad }

f :: proc() -> (point: ^Point, err: My_Error) {
	return nil, .None
}
`)
}

@(test)
named_results_mixed :: proc(t: ^testing.T) {
	expect_named_results(t, `package test

f :: proc() -> (n: int, _: bool{*}) {
	return 1, true
}
`, `package test

f :: proc() -> (n: int, ok: bool) {
	return 1, true
}
`)
}

@(test)
named_results_collision :: proc(t: ^testing.T) {
	expect_named_results(t, `package test

f :: proc(ok: bool) -> (bool, bool{*}) {
	return ok, ok
}
`, `package test

f :: proc(ok: bool) -> (ok2: bool, ok3: bool) {
	return ok, ok
}
`)
}

@(test)
named_results_all_named :: proc(t: ^testing.T) {
	expect_no_named_results(t, `package test

f :: proc() -> (n: int, ok: bool{*}) {
	return 1, true
}
`)
}

@(test)
named_results_none :: proc(t: ^testing.T) {
	expect_no_named_results(t, `package test

f :: proc({*}) {
}
`)
}

@(test)
named_results_disabled :: proc(t: ^testing.T) {
	expect_no_named_results(t, `package test

f :: proc() -> in{*}t {
	return 1
}
`, false)
}

@(test)
named_results_optional_ok :: proc(t: ^testing.T) {
	expect_named_results(t, `package test

f :: pr{*}oc() -> (int, bool) #optional_ok {
	return 1, true
}
`, `package test

f :: proc() -> (result: int, ok: bool) #optional_ok {
	return 1, true
}
`)
}

@(test)
named_results_proc_literal_in_a_local :: proc(t: ^testing.T) {
	expect_named_results(t, `package test

main :: proc() {
	f := proc() -> in{*}t {
		return 1
	}
	_ = f
}
`, `package test

main :: proc() {
	f := proc() -> (result: int) {
		return 1
	}
	_ = f
}
`)
}

@(test)
named_results_missing_on_struct_field_type :: proc(t: ^testing.T) {
	expect_no_named_results(t, `package test

S :: struct {
	f: proc() -> in{*}t,
}
`)
}
