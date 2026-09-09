package tests

import "core:testing"

import test "src:testing"

INLINE_PROC_ACTION :: "Inline procedure call"

expect_inline_proc :: proc(t: ^testing.T, main, expected: string) {
	source := test.Source {
		main   = main,
		config = {enable_code_action_inline_proc = true},
	}
	test.expect_action_applied(t, &source, INLINE_PROC_ACTION, expected)
}

expect_no_inline_proc :: proc(t: ^testing.T, main: string, enabled := true) {
	source := test.Source {
		main   = main,
		config = {enable_code_action_inline_proc = enabled},
	}
	test.expect_action_missing(t, &source, INLINE_PROC_ACTION)
}

@(test)
action_inline_proc_expression :: proc(t: ^testing.T) {
	expect_inline_proc(t, `package test

double :: proc(x: int) -> int {
	return x * 2
}

main :: proc() {
	a := 1
	y := dou{*}ble(a + 1)
}
`, `package test

double :: proc(x: int) -> int {
	return x * 2
}

main :: proc() {
	a := 1
	y := (a + 1) * 2
}
`)
}

@(test)
action_inline_proc_expression_in_binary :: proc(t: ^testing.T) {
	expect_inline_proc(t, `package test

double :: proc(x: int) -> int {
	return x * 2
}

main :: proc() {
	a := 1
	y := dou{*}ble(a) + 1
}
`, `package test

double :: proc(x: int) -> int {
	return x * 2
}

main :: proc() {
	a := 1
	y := a * 2 + 1
}
`)
}

@(test)
action_inline_proc_refused_duplicated_call :: proc(t: ^testing.T) {
	expect_no_inline_proc(t, `package test

square :: proc(x: int) -> int {
	return x * x
}

next :: proc() -> int {
	return 1
}

main :: proc() {
	y := squ{*}are(next())
}
`)
}

@(test)
action_inline_proc_statement :: proc(t: ^testing.T) {
	expect_inline_proc(t, `package test

log :: proc(level: int, msg: string) {
	if level > 1 {
		print(msg)
	}
}

main :: proc() {
	n := 2
	lo{*}g(n + 1, "hi")
}
`, `package test

log :: proc(level: int, msg: string) {
	if level > 1 {
		print(msg)
	}
}

main :: proc() {
	n := 2
	{
		level: int = n + 1
		msg: string = "hi"
		if level > 1 {
			print(msg)
		}
	}
}
`)
}

@(test)
action_inline_proc_statement_same_name :: proc(t: ^testing.T) {
	expect_inline_proc(t, `package test

bump :: proc(counter: ^int) {
	counter^ += 1
}

main :: proc() {
	counter := new(int)
	bu{*}mp(counter)
}
`, `package test

bump :: proc(counter: ^int) {
	counter^ += 1
}

main :: proc() {
	counter := new(int)
	{
		counter^ += 1
	}
}
`)
}

@(test)
action_inline_proc_refused_return :: proc(t: ^testing.T) {
	expect_no_inline_proc(t, `package test

check :: proc(x: int) {
	if x > 1 {
		return
	}
	print(x)
}

main :: proc() {
	che{*}ck(1)
}
`)
}

@(test)
action_inline_proc_refused_group :: proc(t: ^testing.T) {
	expect_no_inline_proc(t, `package test

double_int :: proc(x: int) -> int {
	return x * 2
}

double_f32 :: proc(x: f32) -> f32 {
	return x * 2
}

double :: proc {
	double_int,
	double_f32,
}

main :: proc() {
	y := dou{*}ble(1)
}
`)
}

@(test)
action_inline_proc_refused_variadic :: proc(t: ^testing.T) {
	expect_no_inline_proc(t, `package test

first :: proc(xs: ..int) -> int {
	return xs[0]
}

main :: proc() {
	y := fir{*}st(1)
}
`)
}

@(test)
action_inline_proc_refused_other_package :: proc(t: ^testing.T) {
	packages := make([dynamic]test.Package, context.temp_allocator)
	append(&packages, test.Package{pkg = "my_package", source = `package my_package

double :: proc(x: int) -> int {
	return x * 2
}
`})
	source := test.Source {
		main = `package test

import "my_package"

main :: proc() {
	y := my_package.dou{*}ble(1)
}
`,
		packages = packages[:],
		config = {enable_code_action_inline_proc = true},
	}
	test.expect_action_missing(t, &source, INLINE_PROC_ACTION)
}

@(test)
action_inline_proc_disabled :: proc(t: ^testing.T) {
	expect_no_inline_proc(t, `package test

double :: proc(x: int) -> int {
	return x * 2
}

main :: proc() {
	y := dou{*}ble(1)
}
`, enabled = false)
}
