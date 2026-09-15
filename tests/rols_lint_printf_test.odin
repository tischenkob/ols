package tests

import "core:testing"

import test "src:testing"

@(private = "file")
packages := []test.Package {
	{pkg = "fmt", source = `package fmt
Builder :: struct {}
printf :: proc(f: string, args: ..any) {}
println :: proc(args: ..any) {}
eprintf :: proc(f: string, args: ..any) {}
tprintf :: proc(f: string, args: ..any) -> string { return f }
sbprintf :: proc(b: ^Builder, f: string, args: ..any) -> string { return f }
panicf :: proc(f: string, args: ..any) {}
assertf :: proc(cond: bool, f: string, args: ..any) {}
`},
	{pkg = "log", source = `package log
infof :: proc(f: string, args: ..any) {}
info :: proc(args: ..any) {}
`},
}

@(test)
lint_printf_verb :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "fmt"

main :: proc() {
	fmt.printf("%d items", 1)
	fmt.printf("50%% off")
	fmt.printf("%k")
	fmt.printf("done %")
}
`,
		packages = packages,
		config = {enable_lint_printf = true},
	}

	test.expect_lint_diagnostics(t, &source, {{7, "printf-verb"}, {8, "printf-verb"}})
}

@(test)
lint_printf_arity :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "fmt"

main :: proc() {
	a: int
	b: int
	fmt.printf("%d %d", a, b)
	fmt.printf("%*d", a, b)
	fmt.printf("{1:d}", a, b)
	fmt.printf("%d %d", a)
	fmt.printf("%d", a, b)
	fmt.printf("%[0]d", a, b)
}
`,
		packages = packages,
		config = {enable_lint_printf = true},
	}

	test.expect_lint_diagnostics(t, &source, {{10, "printf-arity"}, {11, "printf-arity"}})
}

@(test)
lint_printf_type :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "fmt"

main :: proc() {
	n: int
	s: string
	f: f32
	ok: bool
	r: rune
	fmt.printf("%d %s %f %t %c", n, s, f, ok, r)
	fmt.printf("%v %v", s, ok)
	fmt.printf("%s", r)
	fmt.printf("%d", s)
	fmt.printf("%f", n)
	fmt.printf("%t", s)
}
`,
		packages = packages,
		config = {enable_lint_printf = true},
	}

	test.expect_lint_diagnostics(t, &source, {{13, "printf-type"}, {14, "printf-type"}, {15, "printf-type"}})
}

@(test)
lint_print_directive :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "fmt"
import "log"

main :: proc() {
	fmt.println("hello", 1)
	log.info("done")
	fmt.println("%d items", 1)
	log.info("%s", "x")
}
`,
		packages = packages,
		config = {enable_lint_printf = true},
	}

	test.expect_lint_diagnostics(t, &source, {{8, "print-directive"}, {9, "print-directive"}})
}

@(test)
lint_printf_cases :: proc(t: ^testing.T) {
	cases := []Lint_Case {
		{
			"a literal argument has no known type",
			`package test

import "fmt"

main :: proc() {
	fmt.printf("%q", 1)
}
`,
			{},
		},
		{
			"indexed verbs read the argument they name",
			`package test

import "fmt"

main :: proc(s: string, n: int) {
	fmt.printf("%[1]d %[0]d", s, n)
}
`,
			{{5, "printf-type"}},
		},
		{
			"width and precision",
			`package test

import "fmt"

main :: proc(f: f64) {
	fmt.printf("%5.2f", f)
}
`,
			{},
		},
		{
			"log.info with a directive",
			`package test

import "log"

main :: proc() {
	log.info("%d")
}
`,
			{{5, "print-directive"}},
		},
		{
			"a trailing percent sign is not a directive",
			`package test

import "fmt"

main :: proc() {
	fmt.println("100%")
}
`,
			{},
		},
		{
			"log.infof checks its format",
			`package test

import "log"

main :: proc(s: string) {
	log.infof("%d", s)
}
`,
			{{5, "printf-type"}},
		},
		{
			"the other fmt procedures with a format",
			`package test

import "fmt"

main :: proc(s: string, ok: bool) {
	b: fmt.Builder
	fmt.eprintf("%d", s)
	fmt.tprintf("%d", s)
	fmt.sbprintf(&b, "%d", s)
	fmt.panicf("%d", s)
	fmt.assertf(ok, "%d", s)
}
`,
			{
				{6, "printf-type"},
				{7, "printf-type"},
				{8, "printf-type"},
				{9, "printf-type"},
				{10, "printf-type"},
			},
		},
		{
			"a format held in a variable",
			`package test

import "fmt"

main :: proc(f: string, n: int) {
	fmt.printf(f, n)
}
`,
			{},
		},
		{
			"a concatenated format",
			`package test

import "fmt"

main :: proc(n: int) {
	fmt.printf("a " + "%d %d", n)
}
`,
			{},
		},
		{
			"escaped quotes around a verb",
			`package test

import "fmt"

main :: proc(s: string) {
	fmt.printf("say \"%d\"", s)
}
`,
			{{5, "printf-type"}},
		},
		{
			"hex also dumps a string",
			`package test

import "fmt"

main :: proc(s: string) {
	fmt.printf("%x", s)
}
`,
			{},
		},
		{
			"a string verb with an integer",
			`package test

import "fmt"

main :: proc(n: int) {
	fmt.printf("%s", n)
}
`,
			{{5, "printf-type"}},
		},
		{
			"v and T accept anything",
			`package test

import "fmt"

main :: proc(n: int, s: string) {
	fmt.printf("%v %T", n, s)
}
`,
			{},
		},
	}

	expect_lint_cases(t, cases, {enable_lint_printf = true}, packages)
}
