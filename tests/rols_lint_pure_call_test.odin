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
Reader :: struct {}
Intern :: struct {}
to_reader :: proc(r: ^Reader, s: string) -> int { return 0 }
to_reader_at :: proc(r: ^Reader, s: string) -> int { return 0 }
intern_get :: proc(m: ^Intern, text: string) -> (string, bool) { return text, true }
intern_get_cstring :: proc(m: ^Intern, text: string) -> (cstring, bool) { return nil, true }
to_cstring :: proc(b: ^Builder) -> (cstring, bool) { return nil, true }
split_iterator :: proc(s: ^string, sep: string) -> (string, bool) { return "", false }
fields_iterator :: proc(s: ^string) -> (string, bool) { return "", false }
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

@(test)
lint_pure_call_ignores_buffer_mutators :: proc(t: ^testing.T) {
	// Corpus: bytes.buffer_write on a ^bytes.Buffer, see docs/corpus-validation.md.
	src := test.Source {
		main = `package test

import "bytes"

main :: proc(b: ^bytes.Buffer, chunk: []byte) {
	bytes.buffer_write(b, chunk)
	bytes.buffer_write_string(b, "x")
	bytes.buffer_truncate(b, 0)
	bytes.buffer_next(b, 1)
	bytes.reader_read_byte(nil)
	bytes.buffer_to_string(b)
}
`,
		packages = {
			{
				pkg = "bytes",
				source = `package bytes
Buffer :: struct {}
Reader :: struct {}
buffer_write :: proc(b: ^Buffer, p: []byte) -> (int, bool) { return 0, true }
buffer_write_string :: proc(b: ^Buffer, s: string) -> (int, bool) { return 0, true }
buffer_truncate :: proc(b: ^Buffer, n: int) {}
buffer_next :: proc(b: ^Buffer, n: int) -> []byte { return nil }
buffer_to_string :: proc(b: ^Buffer) -> string { return "" }
reader_read_byte :: proc(r: ^Reader) -> (byte, bool) { return 0, true }
`,
			},
		},
		config = {enable_lint_pure_call = true},
	}

	// Only the accessor, which leaves the buffer alone, is a pure call.
	test.expect_lint_diagnostics(t, &src, {{10, "pure-call-unused"}})
}

@(test)
lint_pure_call_ignores_pointer_variable_outputs :: proc(t: ^testing.T) {
	// These procedures write through a pointer that is often a variable rather than `&x`.
	src := test.Source {
		main = `package test

import "strings"

main :: proc(r: ^strings.Reader, m: ^strings.Intern, b: ^strings.Builder, s: ^string) {
	strings.to_reader(r, "x")
	strings.to_reader_at(r, "x")
	strings.intern_get(m, "x")
	strings.intern_get_cstring(m, "x")
	strings.to_cstring(b)
	strings.split_iterator(s, ",")
	strings.fields_iterator(s)
}
`,
		packages = packages,
		config = {enable_lint_pure_call = true},
	}

	test.expect_lint_diagnostics(t, &src, {})
}
