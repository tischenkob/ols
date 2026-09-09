#+feature dynamic-literals

package tests

import "core:testing"

import test "src:testing"

@(private = "file")
packages :: proc() -> []test.Package {
	packages := make([dynamic]test.Package, context.temp_allocator)
	append(&packages, test.Package{pkg = "strings", source = `package strings
Builder :: struct { buf: [dynamic]u8 }
builder_make :: proc(allocator := context.allocator) -> Builder { return {} }
builder_destroy :: proc(b: ^Builder) {}
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
