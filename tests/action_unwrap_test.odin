package tests

import "core:testing"

import test "src:testing"

UNWRAP_ACTION :: "Unwrap block"
REMOVE_ELSE_ACTION :: "Remove redundant else"

@(test)
action_remove_else_after_return :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

pick :: proc(c: bool) -> int {
	{*}if c {
		return 1
	} else {
		// fallback
		return 2
	}
}
`,
		packages = {},
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_applied(t, &source, REMOVE_ELSE_ACTION, `package test

pick :: proc(c: bool) -> int {
	if c {
		return 1
	}
	// fallback
	return 2
}
`)
}

@(test)
action_remove_else_after_continue :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	for i in 0 ..< 3 {
		{*}if i == 1 {
			continue
		} else {
			x := i
			_ = x
		}
	}
}
`,
		packages = {},
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_applied(t, &source, REMOVE_ELSE_ACTION, `package test

main :: proc() {
	for i in 0 ..< 3 {
		if i == 1 {
			continue
		}
		x := i
		_ = x
	}
}
`)
}

@(test)
action_remove_else_refused_else_if :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

pick :: proc(c, d: bool) -> int {
	{*}if c {
		return 1
	} else if d {
		return 2
	}
	return 3
}
`,
		packages = {},
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, REMOVE_ELSE_ACTION)
}

@(test)
action_remove_else_refused_without_return :: proc(t: ^testing.T) {
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
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, REMOVE_ELSE_ACTION)
}

@(test)
action_unwrap_bare_block :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	{*}{
		x := 1
		_ = x
	}
}
`,
		packages = {},
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_applied(t, &source, UNWRAP_ACTION, `package test

main :: proc() {
	x := 1
	_ = x
}
`)
}

@(test)
action_unwrap_if :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	c := true
	{*}if c {
		x := 1

		_ = x
	}
}
`,
		packages = {},
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_applied(t, &source, UNWRAP_ACTION, `package test

main :: proc() {
	c := true
	x := 1

	_ = x
}
`)
}

@(test)
action_unwrap_for :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	n := 0
	{*}for n < 3 {
		n += 1
	}
}
`,
		packages = {},
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_applied(t, &source, UNWRAP_ACTION, `package test

main :: proc() {
	n := 0
	n += 1
}
`)
}

@(test)
action_unwrap_for_refused_break :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	n := 0
	{*}for n < 3 {
		n += 1
		if n == 2 {
			break
		}
	}
}
`,
		packages = {},
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, UNWRAP_ACTION)
}

@(test)
action_unwrap_for_nested_break :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	n := 0
	{*}for n < 3 {
		for {
			break
		}
		n += 1
	}
}
`,
		packages = {},
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_applied(t, &source, UNWRAP_ACTION, `package test

main :: proc() {
	n := 0
	for {
		break
	}
	n += 1
}
`)
}

@(test)
action_unwrap_refused_if_else :: proc(t: ^testing.T) {
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
		config = {enable_code_action_unwrap = true},
	}

	test.expect_action_missing(t, &source, UNWRAP_ACTION)
}

@(test)
action_unwrap_disabled :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	{*}{
		x := 1
		_ = x
	}
}
`,
		packages = {},
		config = {},
	}

	test.expect_action_missing(t, &source, UNWRAP_ACTION)
}
