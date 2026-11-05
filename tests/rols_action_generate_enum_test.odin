package tests

import "core:testing"

import test "src:testing"

GENERATE_BIT_SET :: "Generate bit_set"
GENERATE_NAME_TABLE :: "Generate name table"

expect_generate_enum :: proc(t: ^testing.T, title, main, expected: string) {
	source := test.Source {
		main = main,
		config = {enable_code_action_generate_enum = true},
	}
	test.expect_action_applied(t, &source, title, expected)
}

expect_no_generate_enum :: proc(t: ^testing.T, title, main: string, enabled := true) {
	source := test.Source {
		main = main,
		config = {enable_code_action_generate_enum = enabled},
	}
	test.expect_action_missing(t, &source, title)
}

SEQUENTIAL_KIND :: `package test

Ki{*}nd :: enum {
	A,
	Bee,
	Last = Bee,
}
`

@(test)
generate_bit_set_of_a_sequential_enum :: proc(t: ^testing.T) {
	expect_generate_enum(t, GENERATE_BIT_SET, SEQUENTIAL_KIND, `package test

Kind :: enum {
	A,
	Bee,
	Last = Bee,
}

Kind_Set :: bit_set[Kind]
`)
}

// An alias shares the value of its member, so it gets no entry of its own.
@(test)
generate_name_table_of_a_sequential_enum :: proc(t: ^testing.T) {
	expect_generate_enum(t, GENERATE_NAME_TABLE, SEQUENTIAL_KIND, `package test

Kind :: enum {
	A,
	Bee,
	Last = Bee,
}

KIND_NAMES := [Kind]string {
	.A   = "A",
	.Bee = "Bee",
}
`)
}

@(test)
generate_bit_set_names_flags :: proc(t: ^testing.T) {
	expect_generate_enum(t, GENERATE_BIT_SET, "package test\n\nFl{*}ag :: enum u8 {\n\tX = 1,\n\tY = 127,\n}\n", `package test

Flag :: enum u8 {
	X = 1,
	Y = 127,
}

Flags :: bit_set[Flag]
`)
}

@(test)
generate_name_table_of_a_sparse_enum :: proc(t: ^testing.T) {
	expect_generate_enum(t, GENERATE_NAME_TABLE, "package test\n\nCo{*}de :: enum {\n\tOk = 1,\n\tNot_Found = 4,\n}\n", `package test

Code :: enum {
	Ok = 1,
	Not_Found = 4,
}

CODE_NAMES := #sparse[Code]string {
	.Ok        = "Ok",
	.Not_Found = "Not_Found",
}
`)
}

@(test)
generate_bit_set_refuses_values_out_of_range :: proc(t: ^testing.T) {
	expect_no_generate_enum(t, GENERATE_BIT_SET, "package test\n\nK{*}ind :: enum {\n\tA = -1,\n\tB,\n}\n")
	expect_no_generate_enum(t, GENERATE_BIT_SET, "package test\n\nK{*}ind :: enum {\n\tA,\n\tB = 128,\n}\n")
}

@(test)
generate_name_table_refuses_a_wide_spread :: proc(t: ^testing.T) {
	expect_no_generate_enum(t, GENERATE_NAME_TABLE, "package test\n\nK{*}ind :: enum {\n\tA,\n\tB = 1 << 40,\n}\n")
}

@(test)
generate_enum_refuses_an_empty_enum :: proc(t: ^testing.T) {
	expect_no_generate_enum(t, GENERATE_BIT_SET, "package test\n\nK{*}ind :: enum {}\n")
	expect_no_generate_enum(t, GENERATE_NAME_TABLE, "package test\n\nK{*}ind :: enum {}\n")
}

@(test)
generate_enum_refuses_a_taken_name :: proc(t: ^testing.T) {
	main := SEQUENTIAL_KIND + "\nKind_Set :: distinct bit_set[Kind]\n"
	expect_no_generate_enum(t, GENERATE_BIT_SET, main)
	source := test.Source {
		main = SEQUENTIAL_KIND,
		files = {{name = "other.odin", source = "package test\n\nKIND_NAMES :: 1\n"}},
		config = {enable_code_action_generate_enum = true},
	}
	test.expect_action_missing(t, &source, GENERATE_NAME_TABLE)
}

@(test)
generate_enum_disabled :: proc(t: ^testing.T) {
	expect_no_generate_enum(t, GENERATE_BIT_SET, SEQUENTIAL_KIND, enabled = false)
	expect_no_generate_enum(t, GENERATE_NAME_TABLE, SEQUENTIAL_KIND, enabled = false)
}
