package tests

import "core:testing"

import test "src:testing"

TO_TERNARY_ACTION :: "Convert to ternary"
TO_IF_ELSE_ACTION :: "Convert to if/else"

@(test)
action_to_ternary_assign :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x := 0
	c := true
	{*}if c {
		x = 1
	} else {
		x = 2
	}
}
`,
		packages = {},
		config = {enable_code_action_ternary = true},
	}

	test.expect_action_applied(t, &source, TO_TERNARY_ACTION, `package test

main :: proc() {
	x := 0
	c := true
	x = 1 if c else 2
}
`)
}

@(test)
action_to_ternary_return :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

pick :: proc(c: bool) -> int {
	{*}if c {
		return 1
	} else {
		return 2
	}
}
`,
		packages = {},
		config = {enable_code_action_ternary = true},
	}

	test.expect_action_applied(t, &source, TO_TERNARY_ACTION, `package test

pick :: proc(c: bool) -> int {
	return 1 if c else 2
}
`)
}

@(test)
action_to_ternary_refused_else_if :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x := 0
	c, d := true, false
	{*}if c {
		x = 1
	} else if d {
		x = 2
	}
}
`,
		packages = {},
		config = {enable_code_action_ternary = true},
	}

	test.expect_action_missing(t, &source, TO_TERNARY_ACTION)
}

@(test)
action_to_ternary_refused_different_lhs :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x, y := 0, 0
	c := true
	{*}if c {
		x = 1
	} else {
		y = 2
	}
}
`,
		packages = {},
		config = {enable_code_action_ternary = true},
	}

	test.expect_action_missing(t, &source, TO_TERNARY_ACTION)
}

@(test)
action_to_ternary_refused_two_statements :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x := 0
	c := true
	{*}if c {
		x = 1
		x = 3
	} else {
		x = 2
	}
}
`,
		packages = {},
		config = {enable_code_action_ternary = true},
	}

	test.expect_action_missing(t, &source, TO_TERNARY_ACTION)
}

@(test)
action_to_ternary_refused_comment :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x := 0
	c := true
	{*}if c {
		// one
		x = 1
	} else {
		x = 2
	}
}
`,
		packages = {},
		config = {enable_code_action_ternary = true},
	}

	test.expect_action_missing(t, &source, TO_TERNARY_ACTION)
}

@(test)
action_to_if_else_assign :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x := 0
	c := true
	x = 1 i{*}f c else 2
}
`,
		packages = {},
		config = {enable_code_action_ternary = true},
	}

	test.expect_action_applied(t, &source, TO_IF_ELSE_ACTION, `package test

main :: proc() {
	x := 0
	c := true
	if c {
		x = 1
	} else {
		x = 2
	}
}
`)
}

@(test)
action_to_if_else_return :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

pick :: proc(c: bool) -> int {
	return 1 if c{*} else 2
}
`,
		packages = {},
		config = {enable_code_action_ternary = true},
	}

	test.expect_action_applied(t, &source, TO_IF_ELSE_ACTION, `package test

pick :: proc(c: bool) -> int {
	if c {
		return 1
	} else {
		return 2
	}
}
`)
}

@(test)
action_to_if_else_decl :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a, b := 1, 2
	c := true
	x := a if {*}c else b
}
`,
		packages = {},
		config = {enable_code_action_ternary = true},
	}

	test.expect_action_applied(t, &source, TO_IF_ELSE_ACTION, `package test

main :: proc() {
	a, b := 1, 2
	c := true
	x: int
	if c {
		x = a
	} else {
		x = b
	}
}
`)
}

@(test)
action_to_if_else_question_syntax :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x := 0
	c := true
	x = c ? {*}1 : 2
}
`,
		packages = {},
		config = {enable_code_action_ternary = true},
	}

	test.expect_action_applied(t, &source, TO_IF_ELSE_ACTION, `package test

main :: proc() {
	x := 0
	c := true
	if c {
		x = 1
	} else {
		x = 2
	}
}
`)
}

@(test)
action_to_if_else_refused_argument :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

foo :: proc(x: int) {}

main :: proc() {
	c := true
	foo(1 if {*}c else 2)
}
`,
		packages = {},
		config = {enable_code_action_ternary = true},
	}

	test.expect_action_missing(t, &source, TO_IF_ELSE_ACTION)
}

@(test)
action_ternary_disabled :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x := 0
	c := true
	{*}if c {
		x = 1
	} else {
		x = 2
	}
}
`,
		packages = {},
		config = {enable_code_action_ternary = false},
	}

	test.expect_action_missing(t, &source, TO_TERNARY_ACTION)
}
