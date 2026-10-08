package tests

import "core:testing"

import test "src:testing"

@(private = "file")
packages := []test.Package {
	{
		pkg = "fmt",
		source = `package fmt
Builder :: struct {}
printf :: proc(f: string, args: ..any) {}
println :: proc(args: ..any) {}
eprintf :: proc(f: string, args: ..any) {}
tprintf :: proc(f: string, args: ..any) -> string { return f }
sbprintf :: proc(b: ^Builder, f: string, args: ..any) -> string { return f }
panicf :: proc(f: string, args: ..any) {}
assertf :: proc(cond: bool, f: string, args: ..any) {}
`,
	},
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

	// `%k` reads an argument the call does not pass, which core:fmt prints as %!(MISSING ARGUMENT).
	test.expect_lint_diagnostics(t, &source, {{7, "printf-verb"}, {7, "printf-arity"}, {8, "printf-verb"}})
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

	// `{1:d}` and `%[0]d` leave argument 0 or 1 unread, which core:fmt prints as %!(EXTRA …).
	test.expect_lint_diagnostics(
		t,
		&source,
		{{9, "printf-arity"}, {10, "printf-arity"}, {11, "printf-arity"}, {12, "printf-arity"}},
	)
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
		{"width and precision", `package test

import "fmt"

main :: proc(f: f64) {
	fmt.printf("%5.2f", f)
}
`, {}},
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
			{{6, "printf-type"}, {7, "printf-type"}, {8, "printf-type"}, {9, "printf-type"}, {10, "printf-type"}},
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

@(private = "file")
corpus_fmt := []test.Package {
	{
		pkg = "fmt",
		source = `package fmt
printfln :: proc(f: string, args: ..any) {}
aprintf :: proc(f: string, args: ..any) -> string { return f }
`,
	},
}

@(test)
printf_arity_expands_multi_value_call :: proc(t: ^testing.T) {
	// Corpus: odin-lang/examples simd/basic-sum/main.odin:189, see docs/corpus-validation.md.
	source := test.Source {
		main = `package test

import "fmt"
two :: proc() -> (f32, int) { return 1, 2 }
f :: proc() { fmt.printfln("%v %v", two()) }
`,
		packages = corpus_fmt,
		config = {enable_lint_printf = true},
	}

	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
printf_arity_star_with_explicit_index :: proc(t: ^testing.T) {
	// Corpus: core/testing/runner.odin:440, see docs/corpus-validation.md.
	source := test.Source {
		main = `package test

import "fmt"
f :: proc() -> string { return fmt.aprintf("%- *[1]s|", "ab", 6) }
`,
		packages = corpus_fmt,
		config = {enable_lint_printf = true},
	}

	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
printf_arity_counts_multi_value_call_results :: proc(t: ^testing.T) {
	// The expansion must not hide a real shortfall or a real extra argument.
	source := test.Source {
		main = `package test

import "fmt"
two :: proc() -> (f32, int) { return 1, 2 }
f :: proc() {
	fmt.printfln("%v %v %v", two())
	fmt.printfln("%v", two())
}
`,
		packages = corpus_fmt,
		config = {enable_lint_printf = true},
	}

	test.expect_lint_diagnostics(t, &source, {{5, "printf-arity"}, {6, "printf-arity"}})
}

@(test)
printf_arity_star_with_explicit_index_still_counts :: proc(t: ^testing.T) {
	// `*[1]` reads argument 1 and `s` the first unused one, so two arguments are needed and a third is extra.
	source := test.Source {
		main = `package test

import "fmt"
f :: proc() {
	_ = fmt.aprintf("%*[1]s", "ab")
	_ = fmt.aprintf("%*[1]s", "ab", 6, 7)
	_ = fmt.aprintf("%*[1]s", "ab", 6)
}
`,
		packages = corpus_fmt,
		config = {enable_lint_printf = true},
	}

	test.expect_lint_diagnostics(t, &source, {{4, "printf-arity"}, {5, "printf-arity"}})
}

@(test)
printf_brace_star_reads_the_value_argument :: proc(t: ^testing.T) {
	// core:fmt picks the argument of `{` before its options, so `*` reads the same argument as the value.
	source := test.Source {
		main = `package test

import "fmt"
f :: proc(n: int) {
	_ = fmt.aprintf("{:*d}", n)
	_ = fmt.aprintf("{:*d}", n, n)
}
`,
		packages = corpus_fmt,
		config = {enable_lint_printf = true},
	}

	test.expect_lint_diagnostics(t, &source, {{5, "printf-arity"}}, {"call has 1 extra argument"})
}

@(test)
printf_checks_types_after_a_multi_value_call :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "fmt"
two :: proc() -> (f32, int) { return 1, 2 }
f :: proc(s: string) {
	fmt.printfln("%v %v %d", two(), s)
	fmt.printfln("%d %v", s, missing())
}
`,
		packages = corpus_fmt,
		config = {enable_lint_printf = true},
	}

	test.expect_lint_diagnostics(t, &source, {{5, "printf-type"}, {6, "printf-type"}})
}

@(test)
printf_arity_skips_unknown_result_counts :: proc(t: ^testing.T) {
	// A group whose members disagree, or an unresolved callee, passes an unknown number of values.
	source := test.Source {
		main = `package test

import "fmt"
one :: proc() -> int { return 1 }
two :: proc(x: int) -> (int, bool) { return x, true }
mixed :: proc { one, two }
pair_none :: proc() -> (int, bool) { return 1, true }
pair_one :: proc(x: int) -> (int, bool) { return x, true }
pair :: proc { pair_none, pair_one }
f :: proc() {
	fmt.printfln("%v %v", mixed())
	fmt.printfln("%v %v", missing())
	fmt.printfln("%v %v", pair())
	fmt.printfln("%v", pair())
}
`,
		packages = corpus_fmt,
		config = {enable_lint_printf = true},
	}

	test.expect_lint_diagnostics(t, &source, {{13, "printf-arity"}})
}

@(test)
printf_unknown_verb_reads_its_argument :: proc(t: ^testing.T) {
	// core:fmt prints the argument of an unknown verb as %!k(…), but `%5 ` has no verb and reads nothing.
	source := test.Source {
		main = `package test

import "fmt"

main :: proc() {
	x: int
	fmt.printf("%k", x)
	fmt.printf("{:k}", x)
	fmt.printf("%5 d", x)
}
`,
		packages = packages,
		config = {enable_lint_printf = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{{6, "printf-verb"}, {7, "printf-verb"}, {8, "printf-verb"}, {8, "printf-arity"}},
	)
}

@(test)
printf_counts_results_of_unnamed_callee :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "fmt"

h :: proc() -> proc() -> (int, int) { return nil }

main :: proc() {
	arr: [2]proc() -> (int, int)
	fmt.printf("%d %d", h()())
	fmt.printf("%d %d", arr[0]())
	fmt.printf("%d", h()())
	fmt.printf("%d", arr[0]())
}
`,
		packages = packages,
		config = {enable_lint_printf = true},
	}

	test.expect_lint_diagnostics(t, &source, {{10, "printf-arity"}, {11, "printf-arity"}})
}

@(test)
printf_counts_results_of_local_group :: proc(t: ^testing.T) {
	// The local group g shadows the global one, whose members return two values. An argument that does not
	// resolve leaves the call unresolved in the whole-file resolve.
	source := test.Source {
		main = `package test

import "fmt"

a2 :: proc(x: int) -> (int, int) { return x, x }
b2 :: proc(x: f32) -> (int, int) { return 1, 1 }
g :: proc { a2, b2 }

f :: proc(v: $T) {
	a1 :: proc(x: int) -> int { return x }
	b1 :: proc(x: f32) -> int { return 1 }
	g :: proc { a1, b1 }
	fmt.printf("%d", g(v))
	fmt.printf("%d", g(missing))
	fmt.printf("%d %d", g(v))
	fmt.printf("%d %d", g(missing))
}
`,
		packages = packages,
		config = {enable_lint_printf = true},
	}

	test.expect_lint_diagnostics(t, &source, {{14, "printf-arity"}, {15, "printf-arity"}})
}

@(test)
printf_counts_directive_call_as_one_value :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "log"

main :: proc() {
	log.infof("%v", #location())
	log.infof("%v %v", #location())
}
`,
		packages = packages,
		config = {enable_lint_printf = true},
	}

	test.expect_lint_diagnostics(t, &source, {{6, "printf-arity"}})
}

@(test)
printf_counts_group_call_by_members_that_fit :: proc(t: ^testing.T) {
	// two needs more arguments than the call passes, so the call does not resolve to it.
	source := test.Source {
		main = `package test

import "fmt"

one :: proc(a: Missing) -> (int, int) { return 1, 2 }
two :: proc(a, b: int) -> int { return a }
g :: proc { one, two }

main :: proc() {
	fmt.printf("%d %d", g(1))
}
`,
		packages = packages,
		config = {enable_lint_printf = true},
	}

	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
printf_counts_results_of_arrow_call :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "fmt"

Obj :: struct {
	pair: proc(o: ^Obj) -> (int, int),
}

one :: proc(a: int) -> int { return a }
two :: proc(a, b: int) -> (int, int) { return a, b }
g :: proc { one, two }

main :: proc() {
	x: ^Obj
	fmt.printf("%d %d", x->pair())
	fmt.printf("%d", x->pair())
	fmt.printf("%d %d", g(x->pair()))
	fmt.printf("%d", g(x->pair()))
}
`,
		packages = packages,
		config = {enable_lint_printf = true},
	}

	test.expect_lint_diagnostics(t, &source, {{15, "printf-arity"}, {17, "printf-arity"}})
}

@(test)
printf_counts_conversion_to_poly_struct_as_one_value :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

import "fmt"

Vec :: struct($T: typeid) {
	x: T,
}

main :: proc() {
	v: Vec(int)
	fmt.printf("%v", Vec(int)(v))
	fmt.printf("%v %v", Vec(int)(v))
}
`,
		packages = packages,
		config = {enable_lint_printf = true},
	}

	test.expect_lint_diagnostics(t, &source, {{11, "printf-arity"}})
}

@(test)
printf_counts_group_call_over_named_results :: proc(t: ^testing.T) {
	// pair passes two values, so g(pair()) calls two.
	source := test.Source {
		main = `package test

import "fmt"

pair :: proc() -> (a, b: int) { return 1, 2 }
one :: proc(a: int) -> int { return a }
two :: proc(a, b: int) -> (int, int, int) { return a, b, 0 }
g :: proc { one, two }

main :: proc() {
	fmt.printf("%d %d %d", g(pair()))
	fmt.printf("%d", g(pair()))
}
`,
		packages = packages,
		config = {enable_lint_printf = true},
	}

	test.expect_lint_diagnostics(t, &source, {{11, "printf-arity"}})
}

@(test)
printf_counts_group_call_with_local_arrow_call_argument :: proc(t: ^testing.T) {
	// x->single() passes one value, so g(x->single()) calls one.
	source := test.Source {
		main = `package test

import "fmt"

one :: proc(a: int) -> (int, int) { return a, a }
two :: proc(a: string) -> int { return 0 }
g :: proc { one, two }

Obj :: struct {
	single: proc(o: ^Obj) -> int,
}

main :: proc() {
	x: ^Obj
	fmt.printf("%d %d", g(x->single()))
	fmt.printf("%d", g(x->single()))
}
`,
		packages = packages,
		config = {enable_lint_printf = true},
	}

	test.expect_lint_diagnostics(t, &source, {{15, "printf-arity"}})
}
