package tests

import "core:strings"
import "core:testing"

import test "src:testing"

ADD_EXPLICIT_TYPE_ACTION :: "Add explicit type"

@(test)
action_add_explicit_type_int :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x{*} := 5
}
`,
		packages = {},
		config = {enable_code_action_add_explicit_type = true},
	}

	test.expect_action_applied(t, &source, ADD_EXPLICIT_TYPE_ACTION, `package test

main :: proc() {
	x: int = 5
}
`)
}

@(test)
action_add_explicit_type_from_variable :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x := 5
	y{*} := x
}
`,
		packages = {},
		config = {enable_code_action_add_explicit_type = true},
	}

	test.expect_action_applied(t, &source, ADD_EXPLICIT_TYPE_ACTION, `package test

main :: proc() {
	x := 5
	y: int = x
}
`)
}

@(test)
action_add_explicit_type_string :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	s :{*}= "a"
}
`,
		packages = {},
		config = {enable_code_action_add_explicit_type = true},
	}

	test.expect_action_applied(t, &source, ADD_EXPLICIT_TYPE_ACTION, `package test

main :: proc() {
	s: string = "a"
}
`)
}

@(test)
action_add_explicit_type_pointer :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Point :: struct {
	x: int,
}

main :: proc() {
	pt: Point
	{*}p := &pt
}
`,
		packages = {},
		config = {enable_code_action_add_explicit_type = true},
	}

	test.expect_action_applied(t, &source, ADD_EXPLICIT_TYPE_ACTION, `package test

Point :: struct {
	x: int,
}

main :: proc() {
	pt: Point
	p: ^Point = &pt
}
`)
}

@(test)
action_add_explicit_type_call :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() -> []int {
	return nil
}

main :: proc() {
	v{*} := f()
}
`,
		packages = {},
		config = {enable_code_action_add_explicit_type = true},
	}

	test.expect_action_applied(t, &source, ADD_EXPLICIT_TYPE_ACTION, `package test

f :: proc() -> []int {
	return nil
}

main :: proc() {
	v: []int = f()
}
`)
}

@(test)
action_add_explicit_type_global :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

g{*} := 5
`,
		packages = {},
		config = {enable_code_action_add_explicit_type = true},
	}

	test.expect_action_applied(t, &source, ADD_EXPLICIT_TYPE_ACTION, `package test

g: int = 5
`)
}

@(test)
action_add_explicit_type_skips_typed_values :: proc(t: ^testing.T) {
	sources := [?]string {
		`package test

Point :: struct {
	x: int,
}

main :: proc() {
	x{*} := Point{}
}
`,
		`package test

main :: proc() {
	z := 1
	y{*} := int(z)
}
`,
		`package test

main :: proc() {
	z := 1
	q{*} := cast(f32)z
}
`,
		`package test

f :: proc() -> (int, int) {
	return 1, 2
}

main :: proc() {
	a{*}, b := f()
}
`,
	}

	for main in sources {
		source := test.Source {
			main     = main,
			packages = {},
			config   = {enable_code_action_add_explicit_type = true},
		}
		test.expect_action_missing(t, &source, ADD_EXPLICIT_TYPE_ACTION)
	}
}

expect_add_explicit_type :: proc(t: ^testing.T, main, expected: string) {
	source := test.Source {
		main   = main,
		config = {enable_code_action_add_explicit_type = true},
	}
	test.expect_action_applied(t, &source, ADD_EXPLICIT_TYPE_ACTION, expected)
}

@(test)
action_add_explicit_type_float :: proc(t: ^testing.T) {
	expect_add_explicit_type(t, `package test

main :: proc() {
	x{*} := 1.5
}
`, `package test

main :: proc() {
	x: f64 = 1.5
}
`)
}

@(test)
action_add_explicit_type_rune :: proc(t: ^testing.T) {
	expect_add_explicit_type(t, `package test

main :: proc() {
	r{*} := 'a'
}
`, `package test

main :: proc() {
	r: rune = 'a'
}
`)
}

@(test)
action_add_explicit_type_enum_member :: proc(t: ^testing.T) {
	expect_add_explicit_type(t, `package test

Color :: enum {
	Red,
	Green,
}

main :: proc() {
	c{*} := Color.Red
}
`, `package test

Color :: enum {
	Red,
	Green,
}

main :: proc() {
	c: Color = Color.Red
}
`)
}

@(test)
action_add_explicit_type_ternary :: proc(t: ^testing.T) {
	expect_add_explicit_type(t, `package test

main :: proc() {
	c := true
	v{*} := c ? 1 : 2
}
`, `package test

main :: proc() {
	c := true
	v: int = c ? 1 : 2
}
`)
}

@(test)
action_add_explicit_type_or_else :: proc(t: ^testing.T) {
	expect_add_explicit_type(t, `package test

main :: proc() {
	m: map[string]int
	v{*} := m["a"] or_else 0
}
`, `package test

main :: proc() {
	m: map[string]int
	v: int = m["a"] or_else 0
}
`)
}

@(test)
action_add_explicit_type_distinct :: proc(t: ^testing.T) {
	expect_add_explicit_type(t, `package test

Meters :: distinct int

main :: proc() {
	d: Meters = 1
	e{*} := d
}
`, `package test

Meters :: distinct int

main :: proc() {
	d: Meters = 1
	e: Meters = d
}
`)
}

@(test)
action_add_explicit_type_for_header :: proc(t: ^testing.T) {
	expect_add_explicit_type(t, `package test

main :: proc() {
	for i{*} := 0; i < 3; i += 1 {
	}
}
`, `package test

main :: proc() {
	for i: int = 0; i < 3; i += 1 {
	}
}
`)
}

@(test)
action_add_explicit_type_unicode_name :: proc(t: ^testing.T) {
	expect_add_explicit_type(t, `package test

main :: proc() {
	héllo{*} := 5
}
`, `package test

main :: proc() {
	héllo: int = 5
}
`)
}

@(test)
action_add_explicit_type_refused_proc_literal :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	f{*} := proc() {
	}
}
`,
		config = {enable_code_action_add_explicit_type = true},
	}

	test.expect_action_missing(t, &source, ADD_EXPLICIT_TYPE_ACTION)
}

// The second run has a type to read, so the action no longer applies.
@(test)
action_add_explicit_type_twice :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x{*} := 5
}
`,
		config = {enable_code_action_add_explicit_type = true},
	}

	_, typed := test.apply_action_chain(t, &source, {ADD_EXPLICIT_TYPE_ACTION})

	again := test.Source {
		main   = strings.replace(typed, "x:", "x{*}:", 1, context.temp_allocator) or_else "",
		config = {enable_code_action_add_explicit_type = true},
	}
	test.expect_action_missing(t, &again, ADD_EXPLICIT_TYPE_ACTION)
}

@(test)
action_add_explicit_type_disabled :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x{*} := 5
}
`,
		packages = {},
		config = {enable_code_action_add_explicit_type = false},
	}

	test.expect_action_missing(t, &source, ADD_EXPLICIT_TYPE_ACTION)
}
