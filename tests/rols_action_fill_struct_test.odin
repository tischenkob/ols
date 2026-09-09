package tests

import "core:testing"

import test "src:testing"

FILL_ALL_ACTION :: "Fill all fields"
FILL_MISSING_ACTION :: "Fill missing fields"

expect_fill :: proc(t: ^testing.T, action, main, expected: string) {
	source := test.Source{main = main, config = {enable_code_action_fill_struct = true}}
	test.expect_action_applied(t, &source, action, expected)
}

expect_no_fill :: proc(t: ^testing.T, main: string, config := test.Source{config = {enable_code_action_fill_struct = true}}.config) {
	all := test.Source{main = main, config = config}
	test.expect_action_missing(t, &all, FILL_ALL_ACTION)
	missing := test.Source{main = main, config = config}
	test.expect_action_missing(t, &missing, FILL_MISSING_ACTION)
}

@(test)
fill_struct_all :: proc(t: ^testing.T) {
	expect_fill(t, FILL_ALL_ACTION, `package test

Kind :: enum { A, B }

Inner :: struct {
	x: int,
}

Outer :: struct {
	i:  int,
	f:  f32,
	s:  string,
	b:  bool,
	p:  ^int,
	sl: []int,
	m:  map[string]int,
	n:  Inner,
	k:  Kind,
	fa: [3]int,
}

main :: proc() {
	o := Outer{{*}}
	_ = o
}
`, `package test

Kind :: enum { A, B }

Inner :: struct {
	x: int,
}

Outer :: struct {
	i:  int,
	f:  f32,
	s:  string,
	b:  bool,
	p:  ^int,
	sl: []int,
	m:  map[string]int,
	n:  Inner,
	k:  Kind,
	fa: [3]int,
}

main :: proc() {
	o := Outer{
		i = 0,
		f = 0,
		s = "",
		b = false,
		p = nil,
		sl = nil,
		m = nil,
		n = {},
		k = {},
		fa = {},
	}
	_ = o
}
`)
}

@(test)
fill_struct_missing_keeps_existing :: proc(t: ^testing.T) {
	expect_fill(t, FILL_MISSING_ACTION, `package test

Point :: struct {
	x, y: int,
	name: string,
}

main :: proc() {
	p := Point{x = 1{*}}
	_ = p
}
`, `package test

Point :: struct {
	x, y: int,
	name: string,
}

main :: proc() {
	p := Point{
		x = 1,
		y = 0,
		name = "",
	}
	_ = p
}
`)
	expect_fill(t, FILL_MISSING_ACTION, `package test

Point :: struct {
	x, y: int,
	name: string,
}

main :: proc() {
	p := Point{
		{*}x = 1, // first
		name = "n"
	}
	_ = p
}
`, `package test

Point :: struct {
	x, y: int,
	name: string,
}

main :: proc() {
	p := Point{
		x = 1, // first
		name = "n",
		y = 0,
	}
	_ = p
}
`)
}

@(test)
fill_struct_untyped_literal :: proc(t: ^testing.T) {
	expect_fill(t, FILL_ALL_ACTION, `package test

Point :: struct {
	x, y: int,
}

main :: proc() {
	p: Point = {{*}}
	_ = p
}
`, `package test

Point :: struct {
	x, y: int,
}

main :: proc() {
	p: Point = {
		x = 0,
		y = 0,
	}
	_ = p
}
`)
}

@(test)
fill_struct_refused :: proc(t: ^testing.T) {
	expect_no_fill(t, `package test

Point :: struct {
	x, y: int,
}

main :: proc() {
	p := Point{1{*}}
	_ = p
}
`)
	expect_no_fill(t, `package test

main :: proc() {
	a := [3]int{{*}}
	_ = a
}
`)
	expect_no_fill(t, `package test

Point :: struct {
	x, y: int,
}

main :: proc() {
	p := Point{x = 1, y = 2{*}}
	_ = p
}
`)
	expect_no_fill(t, `package test

Point :: struct {
	x, y: int,
}

main :: proc() {
	p := Point{{*}}
	_ = p
}
`, config = {})
}
