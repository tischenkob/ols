package tests

import "core:testing"

import "src:common"
import test "src:testing"

@(test)
linked_editing_local :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc(count: int) {
	to{*}tal := count
	total = total + 1
}
`,
		config = {enable_linked_editing = true},
	}

	test.expect_linked_editing_ranges(
		t,
		&source,
		{{start = {3, 1}, end = {3, 6}}, {start = {4, 1}, end = {4, 6}}, {start = {4, 9}, end = {4, 14}}},
	)
}

@(test)
linked_editing_declaration_end :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc(count: int) {
	total{*} := count
	total = total + 1
}
`,
		config = {enable_linked_editing = true},
	}

	test.expect_linked_editing_ranges(
		t,
		&source,
		{{start = {3, 1}, end = {3, 6}}, {start = {4, 1}, end = {4, 6}}, {start = {4, 9}, end = {4, 14}}},
	)
}

@(test)
linked_editing_use_null :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc(count: int) {
	total := count
	to{*}tal = total + 1
}
`,
		config = {enable_linked_editing = true},
	}

	test.expect_linked_editing_ranges(t, &source, {})
}

@(test)
linked_editing_parameter :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc(co{*}unt: int) {
	total := count
}
`,
		config = {enable_linked_editing = true},
	}

	test.expect_linked_editing_ranges(t, &source, {{start = {2, 13}, end = {2, 18}}, {start = {3, 10}, end = {3, 15}}})
}

@(test)
linked_editing_global_null :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

counter: int

main :: proc() {
	coun{*}ter = counter + 1
}
`,
		config = {enable_linked_editing = true},
	}

	test.expect_linked_editing_ranges(t, &source, {})
}
