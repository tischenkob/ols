package tests

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
