package tests

import "core:testing"

import test "src:testing"

@(private = "file")
packages := []test.Package {
	{
		pkg = "strings",
		source = `package strings
Builder :: struct {}
to_upper :: proc(s: string) -> string { return s }
builder_reset :: proc(b: ^Builder) -> int { return 0 }
write_string :: proc(b: ^Builder, s: string) -> int { return 0 }
index_byte :: proc(s: string, c: byte) -> int { return 0 }
`,
	},
	{
		pkg = "slices",
		source = `package slices
sort :: proc(s: []int) {}
reverse :: proc(s: []int) -> bool { return false }
contains :: proc(s: []int, v: int) -> bool { return false }
fill :: proc(s: []int, v: int) -> int { return 0 }
`,
	},
}

@(test)
lint_pure_call_unused :: proc(t: ^testing.T) {
	src := test.Source {
		main = `package test

import "strings"
import "slices"

main :: proc() {
	s := "hi"
	numbers := []int{1, 2}
	b: strings.Builder

	strings.to_upper(s)
	slices.contains(numbers, 1)

	strings.builder_reset(&b)
	strings.write_string(&b, s)
	slices.reverse(numbers)
	slices.fill(numbers, 0)
	slices.sort(numbers)
	upper := strings.to_upper(s)
	_ = strings.index_byte(upper, 'a')
}
`,
		packages = packages,
		config = {enable_lint_pure_call = true},
	}

	test.expect_lint_diagnostics(t, &src, {{10, "pure-call-unused"}, {11, "pure-call-unused"}})
}
