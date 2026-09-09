#+feature dynamic-literals

package tests

import "core:strings"
import "core:testing"

import test "src:testing"

@(private = "file")
packages :: proc() -> []test.Package {
	packages := make([dynamic]test.Package, context.temp_allocator)
	append(&packages, test.Package{pkg = "strings", source = `package strings
Builder :: struct { buf: [dynamic]u8 }
builder_make :: proc(allocator := context.allocator) -> Builder { return {} }
builder_destroy :: proc(b: ^Builder) {}
clone :: proc(s: string, allocator := context.allocator) -> string { return s }
`})
	append(&packages, test.Package{pkg = "os", source = `package os
read_entire_file :: proc(name: string, allocator := context.allocator) -> (data: []byte, success: bool) { return nil, false }
`})
	return packages[:]
}

// The harness has no runtime package, so the builtins are declared in the test source.
BUILTINS :: `
make :: proc($T: typeid, len: int, allocator := context.allocator) -> T { return {} }
new :: proc($T: typeid, allocator := context.allocator) -> ^T { return nil }
append :: proc(array: ^$T/[dynamic]$E, arg: E) {}
delete :: proc(array: $T/[]$E, allocator := context.allocator) {}
`

expect_defer_delete :: proc(t: ^testing.T, title, main, expected: string) {
	source := test.Source {
		main        = main,
		packages    = packages(),
		collections = {"core" = "test"},
		config      = {enable_code_action_defer_delete = true},
	}
	test.expect_action_applied(t, &source, title, expected)
}

expect_no_defer_delete :: proc(t: ^testing.T, title, main: string, enabled := true) {
	source := test.Source {
		main        = main,
		packages    = packages(),
		collections = {"core" = "test"},
		config      = {enable_code_action_defer_delete = enabled},
	}
	test.expect_action_missing(t, &source, title)
}

@(test)
defer_delete_make :: proc(t: ^testing.T) {
	expect_defer_delete(t, "Add defer delete(s)", `package test
` + BUILTINS + `
main :: proc() {
	s{*} := make([]int, 4)
	s[0] = 1
}
`, `package test
` + BUILTINS + `
main :: proc() {
	s := make([]int, 4)
	defer delete(s)
	s[0] = 1
}
`)
}

@(test)
defer_delete_new :: proc(t: ^testing.T) {
	expect_defer_delete(t, "Add defer free(p)", `package test
` + BUILTINS + `
Point :: struct { x, y: int }

main :: proc() {
	p := ne{*}w(Point)
}
`, `package test
` + BUILTINS + `
Point :: struct { x, y: int }

main :: proc() {
	p := new(Point)
	defer free(p)
}
`)
}

@(test)
defer_delete_builder :: proc(t: ^testing.T) {
	expect_defer_delete(t, "Add defer strings.builder_destroy(&sb)", `package test

import "core:strings"

main :: proc() {
	sb := strings.builder_ma{*}ke()
}
`, `package test

import "core:strings"

main :: proc() {
	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)
}
`)
}

@(test)
defer_delete_two_names :: proc(t: ^testing.T) {
	expect_defer_delete(t, "Add defer delete(data)", `package test

import "core:os"

main :: proc(path: string) {
	data, ok := os.read_entire_file(pa{*}th)
}
`, `package test

import "core:os"

main :: proc(path: string) {
	data, ok := os.read_entire_file(path)
	defer delete(data)
}
`)
}

@(test)
defer_delete_or_else :: proc(t: ^testing.T) {
	expect_defer_delete(t, "Add defer delete(s)", `package test
` + BUILTINS + `
main :: proc() {
	s :{*}= make([]int, 4) or_else nil
}
`, `package test
` + BUILTINS + `
main :: proc() {
	s := make([]int, 4) or_else nil
	defer delete(s)
}
`)
}

@(test)
defer_delete_existing :: proc(t: ^testing.T) {
	expect_no_defer_delete(t, "Add defer delete(s)", `package test
` + BUILTINS + `
main :: proc() {
	s{*} := make([]int, 4)
	defer delete(s)
}
`)
}

@(test)
defer_delete_returned :: proc(t: ^testing.T) {
	expect_no_defer_delete(t, "Add defer delete(s)", `package test
` + BUILTINS + `
main :: proc() -> []int {
	s{*} := make([]int, 4)
	return s
}
`)
}

@(test)
defer_delete_appended :: proc(t: ^testing.T) {
	expect_no_defer_delete(t, "Add defer delete(s)", `package test
` + BUILTINS + `
main :: proc(list: ^[dynamic][]int) {
	s{*} := make([]int, 4)
	append(list, s)
}
`)
}

@(test)
defer_delete_temp_allocator :: proc(t: ^testing.T) {
	expect_no_defer_delete(t, "Add defer delete(s)", `package test
` + BUILTINS + `
main :: proc() {
	s{*} := make([]int, 4, context.temp_allocator)
}
`)
}

@(test)
defer_delete_unrelated_call :: proc(t: ^testing.T) {
	expect_no_defer_delete(t, "Add defer delete(s)", `package test
` + BUILTINS + `
f :: proc() -> []int { return nil }

main :: proc() {
	s{*} := f()
}
`)
}

@(test)
defer_delete_disabled :: proc(t: ^testing.T) {
	expect_no_defer_delete(t, "Add defer delete(s)", `package test
` + BUILTINS + `
main :: proc() {
	s{*} := make([]int, 4)
}
`, false)
}

@(test)
defer_delete_dynamic_array :: proc(t: ^testing.T) {
	expect_defer_delete(t, "Add defer delete(d)", `package test
` + BUILTINS + `
main :: proc() {
	d{*} := make([dynamic]int)
}
`, `package test
` + BUILTINS + `
main :: proc() {
	d := make([dynamic]int)
	defer delete(d)
}
`)
}

@(test)
defer_delete_map :: proc(t: ^testing.T) {
	expect_defer_delete(t, "Add defer delete(m)", `package test
` + BUILTINS + `
main :: proc() {
	m{*} := make(map[string]int)
}
`, `package test
` + BUILTINS + `
main :: proc() {
	m := make(map[string]int)
	defer delete(m)
}
`)
}

@(test)
defer_delete_strings_clone :: proc(t: ^testing.T) {
	expect_defer_delete(t, "Add defer delete(c)", `package test

import "core:strings"

main :: proc(s: string) {
	c := strings.clo{*}ne(s)
}
`, `package test

import "core:strings"

main :: proc(s: string) {
	c := strings.clone(s)
	defer delete(c)
}
`)
}

@(test)
defer_delete_keeps_the_allocator :: proc(t: ^testing.T) {
	expect_defer_delete(t, "Add defer delete(s, allocator)", `package test
` + BUILTINS + `
main :: proc(allocator := context.allocator) {
	s{*} := make([]int, 4, allocator)
}
`, `package test
` + BUILTINS + `
main :: proc(allocator := context.allocator) {
	s := make([]int, 4, allocator)
	defer delete(s, allocator)
}
`)
}

@(test)
defer_delete_dynamic_array_drops_the_allocator :: proc(t: ^testing.T) {
	expect_defer_delete(t, "Add defer delete(d)", `package test
` + BUILTINS + `
main :: proc(allocator := context.allocator) {
	d{*} := make([dynamic]int, 0, 16, allocator)
}
`, `package test
` + BUILTINS + `
main :: proc(allocator := context.allocator) {
	d := make([dynamic]int, 0, 16, allocator)
	defer delete(d)
}
`)
}

@(test)
defer_delete_map_drops_the_allocator :: proc(t: ^testing.T) {
	expect_defer_delete(t, "Add defer delete(m)", `package test
` + BUILTINS + `
main :: proc(allocator := context.allocator) {
	m{*} := make(map[string]int, 16, allocator)
}
`, `package test
` + BUILTINS + `
main :: proc(allocator := context.allocator) {
	m := make(map[string]int, 16, allocator)
	defer delete(m)
}
`)
}

@(test)
defer_delete_string_naming_an_allocator :: proc(t: ^testing.T) {
	expect_defer_delete(t, "Add defer delete(c)", `package test

import "core:strings"

main :: proc() {
	c := strings.clo{*}ne("bad allocator")
}
`, `package test

import "core:strings"

main :: proc() {
	c := strings.clone("bad allocator")
	defer delete(c)
}
`)
}

@(test)
defer_delete_error_name :: proc(t: ^testing.T) {
	expect_defer_delete(t, "Add defer delete(a)", `package test
` + BUILTINS + `
main :: proc() {
	a, err := ma{*}ke([]int, 4)
}
`, `package test
` + BUILTINS + `
main :: proc() {
	a, err := make([]int, 4)
	defer delete(a)
}
`)
}

@(test)
defer_delete_reassignment :: proc(t: ^testing.T) {
	expect_defer_delete(t, "Add defer delete(s)", `package test
` + BUILTINS + `
main :: proc() {
	s: []int
	s = ma{*}ke([]int, 4)
}
`, `package test
` + BUILTINS + `
main :: proc() {
	s: []int
	s = make([]int, 4)
	defer delete(s)
}
`)
}

@(test)
defer_delete_nested_block :: proc(t: ^testing.T) {
	expect_defer_delete(t, "Add defer delete(s)", `package test
` + BUILTINS + `
main :: proc(c: bool) {
	if c {
		s{*} := make([]int, 4)
		s[0] = 1
	}
}
`, `package test
` + BUILTINS + `
main :: proc(c: bool) {
	if c {
		s := make([]int, 4)
		defer delete(s)
		s[0] = 1
	}
}
`)
}

@(test)
defer_delete_do_body :: proc(t: ^testing.T) {
	expect_no_defer_delete(t, "Add defer delete(s)", `package test
` + BUILTINS + `
main :: proc(c: bool) {
	if c do s{*} := make([]int, 4)
}
`)
}

@(test)
defer_delete_twice :: proc(t: ^testing.T) {
	source := test.Source {
		main        = `package test
` + BUILTINS + `
main :: proc() {
	s{*} := make([]int, 4)
	s[0] = 1
}
`,
		packages    = packages(),
		collections = {"core" = "test"},
		config      = {enable_code_action_defer_delete = true},
	}
	once, ok := test.apply_action(t, &source, "Add defer delete(s)")
	if !ok {
		return
	}
	again := test.Source {
		main        = strings.replace(once, "\ts :=", "\ts{*} :=", 1, context.temp_allocator) or_else once,
		packages    = packages(),
		collections = {"core" = "test"},
		config      = {enable_code_action_defer_delete = true},
	}
	test.expect_action_missing(t, &again, "Add defer delete(s)")
}
