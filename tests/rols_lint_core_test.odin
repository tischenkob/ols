package tests

import "core:testing"

import test "src:testing"

@(private = "file")
packages := []test.Package {
	{
		pkg = "time",
		source = `package time
Duration :: distinct i64
Millisecond :: Duration(1000000)
Second :: Duration(1000000000)
sleep :: proc(d: Duration) {}
`,
	},
	{
		pkg = "strings",
		source = `package strings
replace :: proc(s, old, new: string, n: int) -> (output: string, was_allocation: bool) { return "", false }
replace_all :: proc(s, old, new: string) -> (output: string, was_allocation: bool) { return "", false }
`,
	},
	{
		pkg = "math",
		source = `package math
ceil :: proc(x: f64) -> f64 { return 0 }
floor :: proc(x: f64) -> f64 { return 0 }
round :: proc(x: f64) -> f64 { return 0 }
`,
	},
	{
		pkg = "text/regex",
		source = `package regex
Regular_Expression :: struct {}
create :: proc(pattern: string) -> (Regular_Expression, bool) { return {}, false }
`,
	},
}

@(private = "file")
source :: proc(main: string) -> test.Source {
	return test.Source{main = main, packages = packages, config = {enable_lint_core_misuse = true}}
}

@(test)
lint_sleep_literal :: proc(t: ^testing.T) {
	src := source(
		`package test

import "time"

main :: proc() {
	time.sleep(100)
	time.sleep(-100)
	time.sleep(100 * time.Millisecond)
}
`,
	)

	test.expect_lint_diagnostics(t, &src, {{5, "sleep-literal"}, {6, "sleep-literal"}})
}

@(test)
lint_replace_count :: proc(t: ^testing.T) {
	src := source(
		`package test

import "strings"

main :: proc() {
	strings.replace("a", "b", "c", 0)
	strings.replace("a", "b", "c", -1)
	strings.replace("a", "b", "c", 2)
}
`,
	)

	test.expect_lint_diagnostics(t, &src, {{5, "replace-count"}, {6, "replace-count"}})
}

@(test)
lint_replace_count_fix :: proc(t: ^testing.T) {
	src := source(`package test

import "strings"

main :: proc() {
	s, _ := strings.rep{*}lace("a", "b", "c", -1)
}
`)

	test.expect_action_applied(
		t,
		&src,
		"Use strings.replace_all",
		`package test

import "strings"

main :: proc() {
	s, _ := strings.replace_all("a", "b", "c")
}
`,
	)
}

@(test)
lint_ceil_integer :: proc(t: ^testing.T) {
	src := source(
		`package test

import "math"

main :: proc() {
	n: int
	f: f64
	math.ceil(f64(n))
	math.floor(cast(f64)n)
	math.ceil(f64(f))
	math.ceil(f)
}
`,
	)

	test.expect_lint_diagnostics(t, &src, {{7, "ceil-integer"}, {8, "ceil-integer"}})
}

@(test)
lint_regex_syntax :: proc(t: ^testing.T) {
	src := source(
		`package test

import "text/regex"

main :: proc() {
	regex.create("[a-z")
	regex.create("[a-z]+")
}
`,
	)

	test.expect_lint_diagnostics(t, &src, {{5, "regex-syntax"}})
}

@(test)
lint_core_misuse_cases :: proc(t: ^testing.T) {
	cases := []Lint_Case {
		{
			"sleep with a unit constant",
			`package test

import "time"

main :: proc() {
	time.sleep(time.Second)
}
`,
			{},
		},
		{
			"sleep with a variable",
			`package test

import "time"

main :: proc(d: time.Duration) {
	time.sleep(d)
}
`,
			{},
		},
		{
			"replace with a named count",
			`package test

import "strings"

main :: proc() {
	strings.replace("a", "b", "c", n = 1)
}
`,
			{},
		},
		{
			"floor on a float",
			`package test

import "math"

main :: proc(x: f32) {
	math.floor(f32(x))
}
`,
			{},
		},
		{
			"rounding a division is not a converted integer",
			`package test

import "math"

main :: proc(i: int) {
	math.round(f64(i) / 2)
}
`,
			{},
		},
		{
			"invalid pattern with an escape",
			`package test

import "text/regex"

main :: proc() {
	regex.create("\\d+(")
}
`,
			{{5, "regex-syntax"}},
		},
		{
			"valid pattern in a raw string",
			"package test\n\nimport \"text/regex\"\n\nmain :: proc() {\n\tregex.create(`\\d+`)\n}\n",
			{},
		},
		{
			"pattern in a variable",
			`package test

import "text/regex"

main :: proc(p: string) {
	regex.create(p)
}
`,
			{},
		},
		{
			"reversed repetition bounds",
			`package test

import "text/regex"

main :: proc() {
	regex.create("a{2,1}")
}
`,
			{{5, "regex-syntax"}},
		},
	}

	expect_lint_cases(t, cases, {enable_lint_core_misuse = true}, packages)
}

@(test)
lint_fix_replace_count_extra_args :: proc(t: ^testing.T) {
	src := source(`package test

import "strings"

main :: proc() {
	s, _ := strings.rep{*}lace("a", "b", "c", -1, context.temp_allocator)
}
`)

	test.expect_action_applied(
		t,
		&src,
		"Use strings.replace_all",
		`package test

import "strings"

main :: proc() {
	s, _ := strings.replace_all("a", "b", "c", context.temp_allocator)
}
`,
	)
}

@(test)
lint_fix_replace_count_twice :: proc(t: ^testing.T) {
	cases := []Fix_Twice {
		{
			"replace-count",
			"Use strings.replace_all",
			`package test

import "strings"

main :: proc() {
	s, _ := strings.rep{*}lace("a", "b", "c", -1)
}
`,
			"replace_all(",
		},
	}

	expect_fix_twice(t, cases, {enable_lint_core_misuse = true}, packages)
}
