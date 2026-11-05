#+feature dynamic-literals

package tests

import "core:strings"
import "core:testing"

import test "src:testing"

FILL_ALL_ACTION :: "Fill all fields"
FILL_MISSING_ACTION :: "Fill missing fields"

expect_fill :: proc(t: ^testing.T, action, main, expected: string) {
	source := test.Source {
		main = main,
		config = {enable_code_action_fill_struct = true},
	}
	test.expect_action_applied(t, &source, action, expected)
}

expect_no_fill :: proc(
	t: ^testing.T,
	main: string,
	config := test.Source{config = {enable_code_action_fill_struct = true}}.config,
) {
	all := test.Source {
		main   = main,
		config = config,
	}
	test.expect_action_missing(t, &all, FILL_ALL_ACTION)
	missing := test.Source {
		main   = main,
		config = config,
	}
	test.expect_action_missing(t, &missing, FILL_MISSING_ACTION)
}

@(test)
fill_struct_all :: proc(t: ^testing.T) {
	expect_fill(
		t,
		FILL_ALL_ACTION,
		`package test

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
`,
		`package test

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
`,
	)
}

@(test)
fill_struct_missing_keeps_existing :: proc(t: ^testing.T) {
	expect_fill(
		t,
		FILL_MISSING_ACTION,
		`package test

Point :: struct {
	x, y: int,
	name: string,
}

main :: proc() {
	p := Point{x = 1{*}}
	_ = p
}
`,
		`package test

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
`,
	)
	expect_fill(
		t,
		FILL_MISSING_ACTION,
		`package test

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
`,
		`package test

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
`,
	)
}

@(test)
fill_struct_untyped_literal :: proc(t: ^testing.T) {
	expect_fill(
		t,
		FILL_ALL_ACTION,
		`package test

Point :: struct {
	x, y: int,
}

main :: proc() {
	p: Point = {{*}}
	_ = p
}
`,
		`package test

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
`,
	)
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
	expect_no_fill(
		t,
		`package test

Point :: struct {
	x, y: int,
}

main :: proc() {
	p := Point{x = 1, y = 2{*}}
	_ = p
}
`,
	)
	expect_no_fill(
		t,
		`package test

Point :: struct {
	x, y: int,
}

main :: proc() {
	p := Point{{*}}
	_ = p
}
`,
		config = {},
	)
}

@(test)
fill_struct_zero_values :: proc(t: ^testing.T) {
	expect_fill(
		t,
		FILL_ALL_ACTION,
		`package test

Value :: union {
	int,
	bool,
}

Meters :: distinct int

Handler :: proc(a: int) -> int

Big :: struct {
	u:  Value,
	m:  Maybe(int),
	h:  Handler,
	d:  Meters,
	dy: [dynamic]int,
	mp: [^]int,
	cs: cstring,
	rp: rawptr,
	ti: typeid,
}

main :: proc() {
	b := Big{{*}}
	_ = b
}
`,
		`package test

Value :: union {
	int,
	bool,
}

Meters :: distinct int

Handler :: proc(a: int) -> int

Big :: struct {
	u:  Value,
	m:  Maybe(int),
	h:  Handler,
	d:  Meters,
	dy: [dynamic]int,
	mp: [^]int,
	cs: cstring,
	rp: rawptr,
	ti: typeid,
}

main :: proc() {
	b := Big{
		u = {},
		m = {},
		h = nil,
		d = 0,
		dy = nil,
		mp = nil,
		cs = "",
		rp = nil,
		ti = nil,
	}
	_ = b
}
`,
	)
}

@(test)
fill_struct_using_field :: proc(t: ^testing.T) {
	// The members a `using` field brings in are filled through the field itself.
	expect_fill(
		t,
		FILL_ALL_ACTION,
		`package test

Base :: struct {
	id: int,
}

Derived :: struct {
	using base: Base,
	name:       string,
}

main :: proc() {
	d := Derived{{*}}
	_ = d
}
`,
		`package test

Base :: struct {
	id: int,
}

Derived :: struct {
	using base: Base,
	name:       string,
}

main :: proc() {
	d := Derived{
		base = {},
		name = "",
	}
	_ = d
}
`,
	)
}

@(test)
fill_struct_imported_type :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "core:geom"

main :: proc() {
	p := geom.Point{{*}}
	_ = p
}
`,
		packages = {{pkg = "geom", source = `package geom

Point :: struct {
	x, y: f32,
	name: string,
}
`}},
		collections = {"core" = "test"},
		config = {enable_code_action_fill_struct = true},
	}

	test.expect_action_applied(
		t,
		&source,
		FILL_ALL_ACTION,
		`package test

import "core:geom"

main :: proc() {
	p := geom.Point{
		x = 0,
		y = 0,
		name = "",
	}
	_ = p
}
`,
	)
}

@(test)
fill_struct_parametric_type :: proc(t: ^testing.T) {
	expect_fill(
		t,
		FILL_ALL_ACTION,
		`package test

Pair :: struct($T: typeid) {
	a: T,
	b: int,
}

main :: proc() {
	p := Pair(int){{*}}
	_ = p
}
`,
		`package test

Pair :: struct($T: typeid) {
	a: T,
	b: int,
}

main :: proc() {
	p := Pair(int){
		a = 0,
		b = 0,
	}
	_ = p
}
`,
	)
}

FILL_KEYS_ACTION :: "Fill missing keys"

FILL_KEYS_PRELUDE :: "package test\n\nKind :: enum {\n\tA,\n\tB,\n}\n\nAl :: enum {\n\tA,\n\tB,\n\tC = A,\n}\n\nArr :: [Kind]string\n\nmain :: proc() {\n\t"

expect_fill_keys :: proc(t: ^testing.T, body, expected: string) {
	source := test.Source {
		main = strings.concatenate({FILL_KEYS_PRELUDE, body, "\n}\n"}, context.temp_allocator),
		config = {enable_code_action_fill_struct = true},
	}
	test.expect_action_applied(
		t,
		&source,
		FILL_KEYS_ACTION,
		strings.concatenate({FILL_KEYS_PRELUDE, expected, "\n}\n"}, context.temp_allocator),
	)
}

expect_no_fill_keys :: proc(t: ^testing.T, body: string, enabled := true) {
	source := test.Source {
		main = strings.concatenate({FILL_KEYS_PRELUDE, body, "\n}\n"}, context.temp_allocator),
		config = {enable_code_action_fill_struct = enabled},
	}
	test.expect_action_missing(t, &source, FILL_KEYS_ACTION)
}

@(test)
fill_keys_of_an_empty_literal :: proc(t: ^testing.T) {
	expect_fill_keys(t, "x := [Kind]int{{*}}\n\t_ = x", "x := [Kind]int{\n\t\t.A = 0,\n\t\t.B = 0,\n\t}\n\t_ = x")
}

@(test)
fill_keys_keeps_what_is_written :: proc(t: ^testing.T) {
	expect_fill_keys(
		t,
		"x := [Kind]int{.A = {*}1}\n\t_ = x",
		"x := [Kind]int{\n\t\t.A = 1,\n\t\t.B = 0,\n\t}\n\t_ = x",
	)
	expect_fill_keys(
		t,
		"x := [Kind]int{Kind.B = {*}1}\n\t_ = x",
		"x := [Kind]int{\n\t\tKind.B = 1,\n\t\t.A = 0,\n\t}\n\t_ = x",
	)
	expect_fill_keys(
		t,
		"x := [Kind]int{\n\t\t.A = {*}1,\n\t}\n\t_ = x",
		"x := [Kind]int{\n\t\t.A = 1,\n\t\t.B = 0,\n\t}\n\t_ = x",
	)
}

@(test)
fill_keys_takes_the_zero_of_the_element :: proc(t: ^testing.T) {
	expect_fill_keys(t, "x := Arr{{*}}\n\t_ = x", "x := Arr{\n\t\t.A = \"\",\n\t\t.B = \"\",\n\t}\n\t_ = x")
	expect_fill_keys(
		t,
		"x := [Kind]^int{{*}}\n\t_ = x",
		"x := [Kind]^int{\n\t\t.A = nil,\n\t\t.B = nil,\n\t}\n\t_ = x",
	)
}

@(test)
fill_keys_writes_one_line_per_value :: proc(t: ^testing.T) {
	expect_fill_keys(t, "x := [Al]int{{*}}\n\t_ = x", "x := [Al]int{\n\t\t.A = 0,\n\t\t.B = 0,\n\t}\n\t_ = x")
	expect_fill_keys(t, "x := [Al]int{.C = {*}1}\n\t_ = x", "x := [Al]int{\n\t\t.C = 1,\n\t\t.B = 0,\n\t}\n\t_ = x")
}

@(test)
fill_keys_refuses :: proc(t: ^testing.T) {
	// A positional literal, a range key, and nothing left to fill.
	expect_no_fill_keys(t, "x := [Kind]int{{*}1, 2}\n\t_ = x")
	expect_no_fill_keys(t, "x := [Kind]int{.A ..= .B = {*}1}\n\t_ = x")
	expect_no_fill_keys(t, "x := [Kind]int{.A = {*}1, .B = 2}\n\t_ = x")
	// A key that is no member.
	expect_no_fill_keys(t, "x := [Kind]int{.Z = {*}1}\n\t_ = x")
	// A fixed array has no keys.
	expect_no_fill_keys(t, "x := [2]int{{*}}\n\t_ = x")
	expect_no_fill_keys(t, "x := [Kind]int{{*}}\n\t_ = x", enabled = false)
}
