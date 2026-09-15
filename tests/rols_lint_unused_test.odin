package tests

import "core:testing"

import test "src:testing"

@(test)
lint_unused_declaration_private_proc :: proc(t: ^testing.T) {
	source := test.Source {
		config = {enable_lint_unused_declaration = true},
		main = `package test

@(private)
helper :: proc() {}

@(private)
recursive :: proc(n: int) {
	recursive(n - 1)
}

main :: proc() {}
`,
	}
	test.expect_unused_declarations(t, &source, {{"main.odin", 3}, {"main.odin", 6}})
}

@(test)
lint_unused_declaration_used_from_other_file :: proc(t: ^testing.T) {
	source := test.Source {
		config = {enable_lint_unused_declaration = true},
		main = `package test

@(private)
helper :: proc() {}

@(private)
LIMIT :: 10

main :: proc() {}
`,
		files = {{"other.odin", `package test

@(private)
other :: proc() -> int {
	helper()
	return LIMIT
}

@(private)
lonely :: proc() {}
`}},
	}
	test.expect_unused_declarations(t, &source, {{"other.odin", 3}, {"other.odin", 9}})
}

@(test)
lint_unused_declaration_exported_and_file_private :: proc(t: ^testing.T) {
	source := test.Source {
		config = {enable_lint_unused_declaration = true},
		main = `package test

exported :: proc() {}

@(private = "file")
Point :: struct {
	x: int,
}

@(private = "file")
Unused_Type :: struct {}

main :: proc() {
	p: Point
	_ = p
}
`,
	}
	test.expect_unused_declarations(t, &source, {{"main.odin", 10}})
}

@(test)
lint_unused_declaration_file_directive :: proc(t: ^testing.T) {
	source := test.Source {
		config = {enable_lint_unused_declaration = true},
		main = `package test

main :: proc() {}
`,
		files = {{"other.odin", `#+private file
package test

used_here :: proc() {}

not_used :: proc() {}

caller :: proc() {
	used_here()
}
`}},
	}
	test.expect_unused_declarations(t, &source, {{"other.odin", 5}, {"other.odin", 7}})
}

@(test)
lint_unused_declaration_constant_used_by_unused_proc :: proc(t: ^testing.T) {
	source := test.Source {
		config = {enable_lint_unused_declaration = true},
		main = `package test

@(private)
SIZE :: 4

@(private)
consumer :: proc() -> int {
	return SIZE
}

main :: proc() {}
`,
	}
	test.expect_unused_declarations(t, &source, {{"main.odin", 6}})
}

@(test)
lint_unused_declaration_proc_group_member :: proc(t: ^testing.T) {
	source := test.Source {
		config = {enable_lint_unused_declaration = true},
		main = `package test

@(private)
add_int :: proc(a, b: int) -> int {
	return a + b
}

@(private)
add_f32 :: proc(a, b: f32) -> f32 {
	return a + b
}

@(private)
add :: proc {
	add_int,
	add_f32,
}

@(private)
unused_group :: proc {
	add_int,
}

main :: proc() {
	_ = add(1, 2)
}
`,
	}
	test.expect_unused_declarations(t, &source, {{"main.odin", 19}})
}

@(test)
lint_unused_declaration_test_attribute :: proc(t: ^testing.T) {
	source := test.Source {
		config = {enable_lint_unused_declaration = true},
		main = `package test

import "core:testing"

@(test)
@(private)
checks :: proc(t: ^testing.T) {}

@(private)
@(export)
exported :: proc() {}

@(private)
_ignored :: proc() {}

main :: proc() {}
`,
	}
	test.expect_unused_declarations(t, &source, {})
}

@(test)
lint_unused_declaration_disabled :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

@(private)
helper :: proc() {}

main :: proc() {}
`,
	}
	test.expect_unused_declarations(t, &source, {})
}

@(test)
lint_unused_declaration_used_from_test_file :: proc(t: ^testing.T) {
	source := test.Source {
		config = {enable_lint_unused_declaration = true},
		main = `package test

@(private)
helper :: proc() {}

main :: proc() {}
`,
		files = {{"main_test.odin", `package test

import "core:testing"

@(test)
uses_helper :: proc(t: ^testing.T) {
	helper()
}
`}},
	}
	test.expect_unused_declarations(t, &source, {})
}

@(test)
lint_unused_declaration_assert_and_discard :: proc(t: ^testing.T) {
	source := test.Source {
		config = {enable_lint_unused_declaration = true},
		main = `package test

@(private)
Point :: struct {
	x: int,
}

@(private)
LIMIT :: 10

#assert(size_of(Point) == 8)

main :: proc() {
	_ = LIMIT
}
`,
	}
	test.expect_unused_declarations(t, &source, {})
}

@(test)
lint_unused_declaration_init_attribute :: proc(t: ^testing.T) {
	source := test.Source {
		config = {enable_lint_unused_declaration = true},
		main = `package test

@(private)
@(init)
setup :: proc() {}

main :: proc() {}
`,
	}
	test.expect_unused_declarations(t, &source, {})
}
