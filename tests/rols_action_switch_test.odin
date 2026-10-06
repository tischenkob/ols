package tests

import "core:strings"
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
	switch k {
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

@(test)
if_to_switch_string_cases :: proc(t: ^testing.T) {
	expect_switch(t, `package test

main :: proc() {
	s := "a"
	{*}if s == "a" {
		foo()
	} else if s == "b" {
		bar()
	}
}
`, `package test

main :: proc() {
	s := "a"
	switch s {
	case "a":
		foo()
	case "b":
		bar()
	}
}
`)
}

@(test)
if_to_switch_space_indentation :: proc(t: ^testing.T) {
	expect_switch(t, `package test

main :: proc() {
    x := 1
    {*}if x == 1 {
        foo()
    } else {
        bar()
    }
}
`, `package test

main :: proc() {
    x := 1
    switch x {
    case 1:
        foo()
    case:
        bar()
    }
}
`)
}

@(test)
if_to_switch_refusals :: proc(t: ^testing.T) {
	expect_no_switch(t, `package test

main :: proc() {
	x := 1
	{*}if x != 1 {
		foo()
	} else if x == 2 {
		bar()
	}
}
`)
	// Nothing is offered on the result, so the action cannot be applied twice.
	expect_no_switch(t, `package test

main :: proc() {
	x := 1
	{*}switch x {
	case 1:
		foo()
	case:
		bar()
	}
}
`)
}

@(test)
if_to_switch_refuses_init_statement :: proc(t: ^testing.T) {
	expect_no_switch(t, `package test

f :: proc() -> int {
	return 1
}

main :: proc() {
	{*}if v := f(); v == 1 {
		foo()
	} else if v := f(); v == 2 {
		bar()
	}
}
`)
}

// Odin rejects a plain enum switch that leaves a member out, even with a default case.
@(test)
if_to_switch_enum_with_else_is_partial :: proc(t: ^testing.T) {
	expect_switch(t, `package test

Layout :: enum { SPRITE, SHAPE, TEXT }

f :: proc(l: Layout) -> int {
	{*}if l == .SHAPE {
		return 1
	} else {
		return 2
	}
}
`, `package test

Layout :: enum { SPRITE, SHAPE, TEXT }

f :: proc(l: Layout) -> int {
	#partial switch l {
	case .SHAPE:
		return 1
	case:
		return 2
	}
}
`)
}

@(test)
if_to_switch_enum_all_members_is_plain :: proc(t: ^testing.T) {
	expect_switch(t, `package test

Layout :: enum { SPRITE, SHAPE, TEXT }

f :: proc(l: Layout) -> int {
	{*}if l == .SHAPE || l == Layout.TEXT {
		return 1
	} else if l == .SPRITE {
		return 2
	}
	return 3
}
`, `package test

Layout :: enum { SPRITE, SHAPE, TEXT }

f :: proc(l: Layout) -> int {
	switch l {
	case .SHAPE, Layout.TEXT:
		return 1
	case .SPRITE:
		return 2
	}
	return 3
}
`)
}

@(test)
if_to_switch_distinct_enum_from_package_is_partial :: proc(t: ^testing.T) {
	packages := make([dynamic]test.Package, context.temp_allocator)
	append(&packages, test.Package{pkg = "gfx", source = `package gfx
Layout :: enum { SPRITE, SHAPE, TEXT }
`})
	source := test.Source {
		main     = `package test
import "gfx"

My_Layout :: distinct gfx.Layout

f :: proc(l: My_Layout) -> int {
	{*}if l == .SHAPE {
		return 1
	} else {
		return 2
	}
}
`,
		packages = packages[:],
		config   = {enable_code_action_if_to_switch = true},
	}
	test.expect_action_applied(t, &source, TO_SWITCH_ACTION, `package test
import "gfx"

My_Layout :: distinct gfx.Layout

f :: proc(l: My_Layout) -> int {
	#partial switch l {
	case .SHAPE:
		return 1
	case:
		return 2
	}
}
`)
}

// An implicit selector only compares against an enum, so an unresolved subject still gets #partial.
@(test)
if_to_switch_unresolved_enum_subject_is_partial :: proc(t: ^testing.T) {
	expect_switch(t, `package test

f :: proc() -> int {
	l := missing()
	{*}if l == .SHAPE {
		return 1
	}
	return 2
}
`, `package test

f :: proc() -> int {
	l := missing()
	#partial switch l {
	case .SHAPE:
		return 1
	}
	return 2
}
`)
}

@(test)
if_to_switch_unresolved_subject_qualified_value_is_partial :: proc(t: ^testing.T) {
	expect_switch(t, `package test

Layout :: enum { SPRITE, SHAPE, TEXT }

f :: proc() -> int {
	l := missing()
	{*}if l == Layout.SHAPE {
		return 1
	} else {
		return 2
	}
}
`, `package test

Layout :: enum { SPRITE, SHAPE, TEXT }

f :: proc() -> int {
	l := missing()
	#partial switch l {
	case Layout.SHAPE:
		return 1
	case:
		return 2
	}
}
`)
}

// #partial is only legal on an enum, so a resolved non-enum subject stays plain.
@(test)
if_to_switch_float_field_is_plain :: proc(t: ^testing.T) {
	expect_switch(t, `package test

Shape :: struct { radius: f32 }

f :: proc(s: Shape) -> int {
	{*}if s.radius == 1 {
		return 1
	}
	return 2
}
`, `package test

Shape :: struct { radius: f32 }

f :: proc(s: Shape) -> int {
	switch s.radius {
	case 1:
		return 1
	}
	return 2
}
`)
}

// Corpus: a bare `break` in an if body exits the enclosing loop, but in a case body it would exit the switch.
@(test)
if_to_switch_refused_break_leaves_loop :: proc(t: ^testing.T) {
	expect_no_switch(t, `package test

f :: proc(src: []u8) -> bool {
	has_encoded := false
	for b in src {
		{*}if b == '%' || b == '+' {
			has_encoded = true
			break
		}
	}
	return has_encoded
}
`)
	expect_no_switch(t, `package test

g :: proc() -> (int, bool) {
	return 1, true
}

f :: proc(xs: []int) {
	for x in xs {
		{*}if x == 1 {
			foo()
		} else {
			_ = g() or_break
		}
	}
}
`)
}

@(test)
if_to_switch_break_of_own_loop_or_label :: proc(t: ^testing.T) {
	expect_switch(t, `package test

f :: proc(xs: []int) {
	for x in xs {
		{*}if x == 1 {
			for {
				break
			}
		}
	}
}
`, `package test

f :: proc(xs: []int) {
	for x in xs {
		switch x {
		case 1:
			for {
				break
			}
		}
	}
}
`)
	expect_switch(t, `package test

f :: proc(xs: []int) {
	outer: for x in xs {
		{*}if x == 1 {
			break outer
		}
	}
}
`, `package test

f :: proc(xs: []int) {
	outer: for x in xs {
		switch x {
		case 1:
			break outer
		}
	}
}
`)
}

// An `or_break` in a nested loop or switch header, other than a `for` init or condition, exits the outer loop.
@(test)
if_to_switch_refuses_or_break_in_nested_header :: proc(t: ^testing.T) {
	headers := []string{"for y in g() or_break {}", "switch g() or_break {}", "for i := 0; i < 1; i += g() or_break {}"}
	for header in headers {
		expect_no_switch(t, strings.concatenate({`package test

g :: proc() -> (int, bool) {
	return 1, true
}

f :: proc(xs: []int) {
	for x in xs {
		{*}if x == 1 {
			`, header, `
		}
	}
}
`}, context.temp_allocator))
	}
	expect_switch(t, `package test

g :: proc() -> (int, bool) {
	return 1, true
}

f :: proc(xs: []int) {
	for x in xs {
		{*}if x == 1 {
			for (g() or_break) > 0 {}
		}
	}
}
`, `package test

g :: proc() -> (int, bool) {
	return 1, true
}

f :: proc(xs: []int) {
	for x in xs {
		switch x {
		case 1:
			for (g() or_break) > 0 {}
		}
	}
}
`)
}
