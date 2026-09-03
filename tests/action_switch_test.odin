package tests

import "core:testing"

import test "src:testing"

TO_SWITCH_ACTION :: "Convert to switch"

expect_switch :: proc(t: ^testing.T, main, expected: string) {
	source := test.Source{main = main, config = {enable_code_action_if_to_switch = true}}
	test.expect_action_applied(t, &source, TO_SWITCH_ACTION, expected)
}

expect_no_switch :: proc(t: ^testing.T, main: string, config := test.Source{config = {enable_code_action_if_to_switch = true}}.config) {
	source := test.Source{main = main, config = config}
	test.expect_action_missing(t, &source, TO_SWITCH_ACTION)
}

@(test)
if_to_switch_with_else :: proc(t: ^testing.T) {
	expect_switch(t, `package test

main :: proc() {
	x := 1
	{*}if x == 1 {
		foo()
	} else if x == 2 {
		// two
		bar()
	} else {
		baz()
	}
}
`, `package test

main :: proc() {
	x := 1
	switch x {
	case 1:
		foo()
	case 2:
		// two
		bar()
	case:
		baz()
	}
}
`)
}

@(test)
if_to_switch_or_chain_and_reversed :: proc(t: ^testing.T) {
	expect_switch(t, `package test

Kind :: enum { A, B, C, D }

main :: proc() {
	k := Kind.A
	{*}if k == .A {
		foo()
	} else if (k == .B) || .C == k {
		bar()
	} else if .D == k {
		baz()
	}
}
`, `package test

Kind :: enum { A, B, C, D }

main :: proc() {
	k := Kind.A
	#partial switch k {
	case .A:
		foo()
	case .B, .C:
		bar()
	case .D:
		baz()
	}
}
`)
}

@(test)
if_to_switch_int_no_else :: proc(t: ^testing.T) {
	expect_switch(t, `package test

main :: proc() {
	x := 1
	{*}if x == 1 {
		foo()
	}
}
`, `package test

main :: proc() {
	x := 1
	switch x {
	case 1:
		foo()
	}
}
`)
}

@(test)
if_to_switch_refused :: proc(t: ^testing.T) {
	expect_no_switch(t, `package test

main :: proc() {
	x, y := 1, 2
	{*}if x == 1 {
		foo()
	} else if y == 2 {
		bar()
	}
}
`)
	expect_no_switch(t, `package test

main :: proc() {
	x := 1
	{*}if x == 1 {
		foo()
	} else if x < 2 {
		bar()
	}
}
`)
	expect_no_switch(t, `package test

main :: proc() {
	x := 1
	{*}if x == 1 do foo()
	else if x == 2 do bar()
}
`)
	expect_no_switch(t, `package test

main :: proc() {
	x := 1
	{*}if x == 1 {
		foo()
	} else {
		bar()
	}
}
`, config = {})
}
