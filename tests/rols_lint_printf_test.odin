package tests

import "core:testing"

import test "src:testing"

@(private = "file")
packages := []test.Package {
	{pkg = "fmt", source = `package fmt
printf :: proc(f: string, args: ..any) {}
println :: proc(args: ..any) {}
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
