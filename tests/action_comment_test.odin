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

	one_liner := test.Source {
		main = `package test

main :: proc() {
	/* note {*}here */
	x := 1
}
`,
		config = {enable_code_action_comment = true},
	}

	test.expect_action_applied(t, &one_liner, TO_LINES, `package test

main :: proc() {
	// note here
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
