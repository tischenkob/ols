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
clone :: proc(s: string) -> string { return s }
`,
	},
	{
		pkg = "math",
		source = `package math
sqrt :: proc(x: f64) -> f64 { return 0 }
`,
	},
	{
		pkg = "fmt",
		source = `package fmt
tprintf :: proc(f: string, args: ..any) -> string { return f }
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

@(test)
lint_pure_call_cases :: proc(t: ^testing.T) {
	cases := []Lint_Case {
		{
			"a discarded clone",
			`package test

import "strings"

main :: proc(s: string) {
	strings.clone(s)
}
`,
			{{5, "pure-call-unused"}},
		},
		{
			"a discarded math result",
			`package test

import "math"

main :: proc(x: f64) {
	math.sqrt(x)
}
`,
			{{5, "pure-call-unused"}},
		},
		{
			"fmt is not a pure package",
			`package test

import "fmt"

main :: proc() {
	fmt.tprintf("x")
}
`,
			{},
		},
		{
			"builtins are not checked",
			`package test

main :: proc(a: ^[dynamic]int, s: []int) {
	append(a, 1)
	len(s)
}
`,
			{},
		},
	}

	expect_lint_cases(t, cases, {enable_lint_pure_call = true}, packages)
}
