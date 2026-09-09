package tests

import "core:testing"

import test "src:testing"

@(private = "file")
DOC_COMMENT :: "Add doc comment"

@(private = "file")
TO_BLOCK :: "Convert to block comment"

@(private = "file")
TO_LINES :: "Convert to line comments"

@(test)
action_doc_comment :: proc(t: ^testing.T) {
	procedure := test.Source {
		main = `package test

fo{*}o :: proc(a: int) -> int {
	return a
}
`,
		config = {enable_code_action_comment = true},
	}

	test.expect_action_applied(
		t,
		&procedure,
		DOC_COMMENT,
		`package test

// foo 
foo :: proc(a: int) -> int {
	return a
}
`,
	)

	attributed := test.Source {
		main = `package test

@(private)
ba{*}r := 1
`,
		config = {enable_code_action_comment = true},
	}

	test.expect_action_applied(t, &attributed, DOC_COMMENT, `package test

// bar 
@(private)
bar := 1
`)

	documented := test.Source {
		main = `package test

// Already documented.
ba{*}z :: 1
`,
		config = {enable_code_action_comment = true},
	}

	test.expect_action_missing(t, &documented, DOC_COMMENT)

	local := test.Source {
		main = `package test

main :: proc() {
	q{*}ux := 1
}
`,
		config = {enable_code_action_comment = true},
	}

	test.expect_action_missing(t, &local, DOC_COMMENT)
}

@(test)
action_comment_toggle :: proc(t: ^testing.T) {
	lines := test.Source {
		main = `package test

main :: proc() {
	{[// first
	// second]}
	x := 1
}
`,
		config = {enable_code_action_comment = true},
	}

	test.expect_action_applied(t, &lines, TO_BLOCK, `package test

main :: proc() {
	/*
	first
	second
	*/
	x := 1
}
`)

	block := test.Source {
		main = `package test

main :: proc() {
	/*
	fi{*}rst
	second
	*/
	x := 1
}
`,
		config = {enable_code_action_comment = true},
	}

	test.expect_action_applied(t, &block, TO_LINES, `package test

main :: proc() {
	// first
	// second
	x := 1
}
`)

	trailing := test.Source {
		main = `package test

main :: proc() {
	x := 1 // not{*}e
}
`,
		config = {enable_code_action_comment = true},
	}

	test.expect_action_missing(t, &trailing, TO_BLOCK)

	with_code := test.Source {
		main = `package test

main :: proc() {
	{[// note
	x := 1]}
}
`,
		config = {enable_code_action_comment = true},
	}

	test.expect_action_missing(t, &with_code, TO_BLOCK)
}

@(private = "file")
comment_source :: proc(main: string) -> test.Source {
	return test.Source{main = main, config = {enable_code_action_comment = true}}
}

@(test)
action_comment_round_trip :: proc(t: ^testing.T) {
	single := comment_source(`package test

main :: proc() {
	// note{*}
	x := 1
}
`)

	test.expect_action_round_trip(t, &single, {TO_BLOCK, TO_LINES}, {"/*"})

	three := comment_source(`package test

main :: proc() {
	// one{*}
	// two
	// three
	x := 1
}
`)

	test.expect_action_round_trip(t, &three, {TO_BLOCK, TO_LINES}, {"/*"})

	spaces := comment_source(`package test

main :: proc() {
    // note{*}
    x := 1
}
`)

	test.expect_action_round_trip(t, &spaces, {TO_BLOCK, TO_LINES}, {"/*"})

	partial_selection := comment_source(`package test

main :: proc() {
	{[// one
	// two]}
	// three
	x := 1
}
`)

	test.expect_action_applied(t, &partial_selection, TO_BLOCK, `package test

main :: proc() {
	/*
	one
	two
	*/
	// three
	x := 1
}
`)
}

@(test)
action_comment_forms_and_refusals :: proc(t: ^testing.T) {
	// Neither form keeps interior spacing, so a round trip normalises it.
	trailing_space := comment_source("package test\n\nmain :: proc() {\n\t// no{*}te   \n\tx := 1\n}\n")

	test.expect_action_chain(t, &trailing_space, {TO_BLOCK, TO_LINES}, `package test

main :: proc() {
	// note
	x := 1
}
`, {"/*"})

	blank_between := comment_source(`package test

main :: proc() {
	{[// one

	// two]}
	x := 1
}
`)

	test.expect_action_missing(t, &blank_between, TO_BLOCK)

	closes_block := comment_source(`package test

main :: proc() {
	// a */ b{*}
	x := 1
}
`)

	test.expect_action_missing(t, &closes_block, TO_BLOCK)

	starred := comment_source(`package test

main :: proc() {
	/*
	 * one{*}
	 * two
	 */
	x := 1
}
`)

	test.expect_action_applied(t, &starred, TO_LINES, `package test

main :: proc() {
	// * one
	// * two
	x := 1
}
`)

	one_liner := comment_source(`package test

main :: proc() {
	/* note {*}here */
	x := 1
}
`)

	test.expect_action_chain(t, &one_liner, {TO_LINES, TO_BLOCK}, `package test

main :: proc() {
	/*
	note here
	*/
	x := 1
}
`, {"// note"})
}

@(test)
action_doc_comment_decl_kinds :: proc(t: ^testing.T) {
	structure := comment_source(`package test

Poi{*}nt :: struct {
	x: int,
}
`)

	test.expect_action_applied(
		t,
		&structure,
		DOC_COMMENT,
		"package test\n\n// Point \nPoint :: struct {\n\tx: int,\n}\n",
	)

	constant := comment_source(`package test

MA{*}X :: 10
`)

	test.expect_action_applied(t, &constant, DOC_COMMENT, "package test\n\n// MAX \nMAX :: 10\n")

	// Only top level declarations are offered a doc comment.
	conditional := comment_source(`package test

when ODIN_DEBUG {
	fo{*}o :: proc() {}
}
`)

	test.expect_action_missing(t, &conditional, DOC_COMMENT)
}
