package tests

import "core:testing"

import test "src:testing"

@(private = "file")
attr_source :: proc(main: string, files: []test.File = {}) -> test.Source {
	return {main = main, files = files, config = {enable_code_action_attr = true}}
}

@(private = "file")
expect_attr :: proc(t: ^testing.T, title, main, expected: string) {
	source := attr_source(main)
	test.expect_action_applied(t, &source, title, expected)
}

@(private = "file")
expect_no_attr :: proc(t: ^testing.T, title, main: string, files: []test.File = {}) {
	source := attr_source(main, files)
	test.expect_action_missing(t, &source, title)
}

@(test)
attr_add_require_results :: proc(t: ^testing.T) {
	expect_attr(
		t,
		"Add @(require_results)",
		`package test

va{*}lue :: proc() -> int {
	return 1
}

main :: proc() {
	x := value()
	_ = x
}
`,
		`package test

@(require_results)
value :: proc() -> int {
	return 1
}

main :: proc() {
	x := value()
	_ = x
}
`,
	)
}

@(test)
attr_add_require_results_keeps_an_or_return_statement :: proc(t: ^testing.T) {
	expect_attr(
		t,
		"Add @(require_results)",
		`package test

va{*}lue :: proc() -> bool {
	return true
}

caller :: proc() -> bool {
	value() or_return
	return true
}
`,
		`package test

@(require_results)
value :: proc() -> bool {
	return true
}

caller :: proc() -> bool {
	value() or_return
	return true
}
`,
	)
}

@(test)
attr_remove_require_results :: proc(t: ^testing.T) {
	expect_attr(
		t,
		"Remove @(require_results)",
		`package test

@(require_results)
va{*}lue :: proc() -> int {
	return 1
}
`,
		`package test

value :: proc() -> int {
	return 1
}
`,
	)
}

@(test)
attr_remove_require_results_from_a_group :: proc(t: ^testing.T) {
	expect_attr(
		t,
		"Remove @(require_results)",
		`package test

@(private, require_{*}results)
value :: proc() -> int {
	return 1
}
`,
		`package test

@(private)
value :: proc() -> int {
	return 1
}
`,
	)
}

@(test)
attr_require_results_refuses :: proc(t: ^testing.T) {
	ADD :: "Add @(require_results)"
	expect_no_attr(t, ADD, `package test

va{*}lue :: proc() {
}
`)
	expect_no_attr(t, ADD, `package test

va{*}lue :: proc() -> ! {
	for {
	}
}
`)
	expect_no_attr(t, ADD, `package test

va{*}lue :: 1
`)
	expect_no_attr(t, "Remove @(require_results)", `package test

@(require_results)
va{*}lue :: proc() {
}
`)
}

@(test)
attr_require_results_refuses_a_dropped_result :: proc(t: ^testing.T) {
	ADD :: "Add @(require_results)"
	expect_no_attr(t, ADD, `package test

va{*}lue :: proc() -> int {
	return 1
}

main :: proc() {
	value()
}
`)
	expect_no_attr(t, ADD, `package test

va{*}lue :: proc() -> int {
	return 1
}

main :: proc() {
	defer value()
}
`)
	expect_no_attr(
		t,
		ADD,
		`package test

va{*}lue :: proc() -> int {
	return 1
}
`,
		{{"b.odin", `package test

other :: proc() {
	value()
}
`}},
	)
}

@(test)
attr_require_results_refuses_a_use_as_a_value :: proc(t: ^testing.T) {
	ADD :: "Add @(require_results)"
	expect_no_attr(
		t,
		ADD,
		`package test

va{*}lue :: proc() -> int {
	return 1
}

main :: proc() {
	p := value
	p()
}
`,
	)
	expect_no_attr(
		t,
		ADD,
		`package test

va{*}lue :: proc() -> int {
	return 1
}

other :: proc(x: int) -> int {
	return x
}

group :: proc {
	value,
	other,
}
`,
	)
}

@(test)
attr_add_private :: proc(t: ^testing.T) {
	expect_attr(
		t,
		"Add @(private)",
		`package test

va{*}lue :: proc() {
}
`,
		`package test

@(private)
value :: proc() {
}
`,
	)
	expect_attr(
		t,
		"Add @(private)",
		`package test

Va{*}lue :: struct {
	x: int,
}
`,
		`package test

@(private)
Value :: struct {
	x: int,
}
`,
	)
	expect_attr(
		t,
		"Add @(private)",
		`package test

@(cold)
va{*}lue :: proc() {
}
`,
		`package test

@(cold, private)
value :: proc() {
}
`,
	)
}

@(test)
attr_add_private_keeps_uses_in_the_package :: proc(t: ^testing.T) {
	source := attr_source(
		`package test

va{*}lue :: proc() {
}
`,
		{{"b.odin", `package test

other :: proc() {
	value()
}
`}},
	)
	test.expect_action_applied_files(
		t,
		&source,
		"Add @(private)",
		{{"main.odin", `package test

@(private)
value :: proc() {
}
`}},
	)
}

@(test)
attr_remove_private :: proc(t: ^testing.T) {
	expect_attr(
		t,
		"Remove @(private)",
		`package test

@(private)
va{*}lue :: proc() {
}
`,
		`package test

value :: proc() {
}
`,
	)
	expect_attr(
		t,
		"Remove @(private)",
		`package test

@(private="fi{*}le")
value :: proc() {
}
`,
		`package test

value :: proc() {
}
`,
	)
}

@(test)
attr_private_refuses_a_private_file :: proc(t: ^testing.T) {
	expect_no_attr(t, "Add @(private)", `#+private
package test

va{*}lue :: proc() {
}
`)
	expect_no_attr(t, "Remove @(private)", `#+private file
package test

@(private)
va{*}lue :: proc() {
}
`)
}

@(test)
attr_private_refuses_a_use_in_another_package :: proc(t: ^testing.T) {
	expect_no_attr(
		t,
		"Add @(private)",
		`package test

va{*}lue :: proc() {
}
`,
		{{"sub/user.odin", `package sub

import "../"

other :: proc() {
	test.value()
}
`}},
	)
}

@(test)
attr_private_refuses_a_test :: proc(t: ^testing.T) {
	expect_no_attr(
		t,
		"Add @(private)",
		`package test

import "core:testing"

@(test)
va{*}lue :: proc(t: ^testing.T) {
}
`,
	)
}

@(test)
attr_remove_file_private_refuses_a_name_taken_in_the_package :: proc(t: ^testing.T) {
	expect_no_attr(
		t,
		"Remove @(private)",
		`package test

@(private = "file")
va{*}lue :: proc() {
}
`,
		{{"b.odin", `package test

value :: proc() {
}
`}},
	)
}

@(test)
attr_add_test :: proc(t: ^testing.T) {
	expect_attr(
		t,
		"Add @(test)",
		`package test

import "core:testing"

va{*}lue :: proc(t: ^testing.T) {
}
`,
		`package test

import "core:testing"

@(test)
value :: proc(t: ^testing.T) {
}
`,
	)
	expect_attr(
		t,
		"Add @(test)",
		`package test

import tt "core:testing"

value :: proc(t{*}: ^tt.T) {
}
`,
		`package test

import tt "core:testing"

@(test)
value :: proc(t: ^tt.T) {
}
`,
	)
}

@(test)
attr_remove_test :: proc(t: ^testing.T) {
	expect_attr(
		t,
		"Remove @(test)",
		`package test

import "core:testing"

@(test)
va{*}lue :: proc(t: ^testing.T) {
}
`,
		`package test

import "core:testing"

value :: proc(t: ^testing.T) {
}
`,
	)
}

@(test)
attr_test_refuses_another_signature :: proc(t: ^testing.T) {
	ADD :: "Add @(test)"
	expect_no_attr(t, ADD, `package test

import "core:testing"

va{*}lue :: proc() {
}
`)
	expect_no_attr(t, ADD, `package test

import "core:testing"

va{*}lue :: proc(t: ^testing.T, other: int) {
}
`)
	expect_no_attr(t, ADD, `package test

import "core:testing"

va{*}lue :: proc(t: testing.T) {
}
`)
	expect_no_attr(
		t,
		ADD,
		`package test

import "core:testing"

va{*}lue :: proc(t: ^testing.T) -> int {
	return 1
}
`,
	)
	expect_no_attr(t, ADD, `package test

import "core:testing"

va{*}lue :: proc "c" (t: ^testing.T) {
}
`)
	expect_no_attr(t, ADD, `package test

import testing "other:testing"

va{*}lue :: proc(t: ^testing.T) {
}
`)
	expect_no_attr(t, "Remove @(test)", `package test

@(test)
va{*}lue :: proc() {
}
`)
}

@(test)
attr_test_refuses_a_private_declaration :: proc(t: ^testing.T) {
	expect_no_attr(
		t,
		"Add @(test)",
		`package test

import "core:testing"

@(private)
va{*}lue :: proc(t: ^testing.T) {
}
`,
	)
}

@(test)
attr_reaches_the_header_only :: proc(t: ^testing.T) {
	expect_attr(
		t,
		"Add @(private)",
		`package test

value :: proc(x: i{*}nt) {
}
`,
		`package test

@(private)
value :: proc(x: int) {
}
`,
	)
	expect_attr(
		t,
		"Add @(private)",
		`package test

when ODIN_OS == .Darwin {
	va{*}lue :: proc() {
	}
}
`,
		`package test

when ODIN_OS == .Darwin {
	@(private)
	value :: proc() {
	}
}
`,
	)
	expect_no_attr(t, "Add @(private)", `package test

value :: proc() {
	x{*} := 1
	_ = x
}
`)
	expect_no_attr(t, "Add @(private)", `package test

value := 1 +{*} 2
`)
	expect_no_attr(
		t,
		"Add @(private)",
		`package test

foreign import lib "lib"

foreign lib {
	va{*}lue :: proc() ---
}
`,
	)
}

@(test)
attr_disappears_with_its_flag :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

va{*}lue :: proc() -> int {
	return 1
}
`,
	}
	test.expect_action_missing(t, &source, "Add @(require_results)")
	again := test.Source {
		main = `package test

va{*}lue :: proc() -> int {
	return 1
}
`,
	}
	test.expect_action_missing(t, &again, "Add @(private)")
}
