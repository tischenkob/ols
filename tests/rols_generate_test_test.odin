package tests

import "core:testing"

import test "src:testing"

@(private = "file")
generate_source :: proc(main: string, files: []test.File = {}) -> test.Source {
	source := test.Source {
		main = main,
		files = files,
		config = {enable_code_action_generate_test = true, client_create_file_support = true},
	}
	source.collections = make(map[string]string, context.temp_allocator)
	source.collections["core"] = "test"
	return source
}

@(test)
generate_test_new_file :: proc(t: ^testing.T) {
	source := generate_source(`package test

fo{*}o :: proc(a: int, s: string) -> int {
	return a + len(s)
}
`)
	test.expect_action_applied_files(
		t,
		&source,
		"Generate test for foo",
		{
			{
				"main_test.odin",
				"package test\n\nimport \"core:testing\"\n\n@(test)\ntest_foo :: proc(t: ^testing.T) {\n\tresult := foo(0, \"\")\n\ttesting.expect_value(t, result, 0)\n}\n",
			},
		},
	)
}

@(test)
generate_test_appends_to_existing_file :: proc(t: ^testing.T) {
	source := generate_source(
		`package test

fo{*}o :: proc(a: int) {
}
`,
		{
			{
				"main_test.odin",
				"package test\n\nimport \"core:testing\"\n\n@(test)\ntest_foo :: proc(t: ^testing.T) {\n}\n",
			},
		},
	)
	test.expect_action_applied_files(
		t,
		&source,
		"Generate test for foo",
		{
			{
				"main_test.odin",
				"package test\n\nimport \"core:testing\"\n\n@(test)\ntest_foo :: proc(t: ^testing.T) {\n}\n\n@(test)\ntest_foo2 :: proc(t: ^testing.T) {\n\tfoo(0)\n}\n",
			},
		},
	)
}

@(test)
generate_test_two_results :: proc(t: ^testing.T) {
	source := generate_source(
		`package test

Point :: struct {
	x, y: int,
}

pa{*}rse :: proc(s: string, p: ^Point) -> (Point, bool) {
	return {}, false
}
`,
	)
	test.expect_action_applied_files(
		t,
		&source,
		"Generate test for parse",
		{
			{
				"main_test.odin",
				"package test\n\nimport \"core:testing\"\n\n@(test)\ntest_parse :: proc(t: ^testing.T) {\n\ta, b := parse(\"\", nil)\n\ttesting.expect_value(t, a, Point{})\n\ttesting.expect_value(t, b, false)\n}\n",
			},
		},
	)
}

@(test)
generate_test_refused_for_tests_and_groups :: proc(t: ^testing.T) {
	source := generate_source(`package test

import "core:testing"

@(test)
al{*}ready :: proc(t: ^testing.T) {
}
`)
	test.expect_action(t, &source, {})

	group := generate_source(`package test

a :: proc(x: int) {}
b :: proc(x: f32) {}
bo{*}th :: proc {a, b}
`)
	test.expect_action(t, &group, {})
}

@(test)
generate_test_uses_the_file_name :: proc(t: ^testing.T) {
	source := generate_source("")
	source.files = {{"bar.odin", `package test

fo{*}o :: proc(a: int) {
}
`}}
	test.expect_action_applied_files(
		t,
		&source,
		"Generate test for foo",
		{
			{
				"bar_test.odin",
				"package test\n\nimport \"core:testing\"\n\n@(test)\ntest_foo :: proc(t: ^testing.T) {\n\tfoo(0)\n}\n",
			},
		},
	)
}

@(test)
generate_test_adds_the_testing_import :: proc(t: ^testing.T) {
	source := generate_source(`package test

fo{*}o :: proc(a: int) {
}
`, {{"main_test.odin", "package test\n\nhelper :: proc() {}\n"}})
	test.expect_action_applied_files(
		t,
		&source,
		"Generate test for foo",
		{
			{
				"main_test.odin",
				"package test\n\nimport \"core:testing\"\n\nhelper :: proc() {}\n\n@(test)\ntest_foo :: proc(t: ^testing.T) {\n\tfoo(0)\n}\n",
			},
		},
	)
}

@(test)
generate_test_refused_for_file_private :: proc(t: ^testing.T) {
	source := generate_source(`package test

@(private = "file")
fo{*}o :: proc() {
}
`)
	test.expect_action(t, &source, {})
}

// Corpus: karl2d platform_mac.odin:131 on the 2026-10-05 rerun, see docs/corpus-validation.md.
@(test)
generate_test_refused_for_private_file_tag :: proc(t: ^testing.T) {
	source := generate_source(`#+private file
package test

fo{*}o :: proc() {
}
`)
	test.expect_action(t, &source, {})
}

@(test)
generate_test_new_file_keeps_file_tags :: proc(t: ^testing.T) {
	source := generate_source(`#+build darwin, linux
#+private
#+vet tabs
package test

fo{*}o :: proc() {
}
`)
	test.expect_action_applied_files(
		t,
		&source,
		"Generate test for foo",
		{
			{
				"main_test.odin",
				"#+build darwin, linux\n#+private\n#+vet tabs\npackage test\n\nimport \"core:testing\"\n\n@(test)\ntest_foo :: proc(t: ^testing.T) {\n\tfoo()\n}\n",
			},
		},
	)
}

@(test)
generate_test_for_package_private :: proc(t: ^testing.T) {
	source := generate_source(`package test

@(private)
fo{*}o :: proc() {
}
`)
	test.expect_action_applied_files(
		t,
		&source,
		"Generate test for foo",
		{
			{
				"main_test.odin",
				"package test\n\nimport \"core:testing\"\n\n@(test)\ntest_foo :: proc(t: ^testing.T) {\n\tfoo()\n}\n",
			},
		},
	)
}

@(test)
generate_test_refused_under_when :: proc(t: ^testing.T) {
	source := generate_source(`package test

when ODIN_OS == .Linux {
	fo{*}o :: proc() {
	}
}
`)
	test.expect_action(t, &source, {})
}

// Corpus: karl2d karl2d.odin:7488, see docs/corpus-validation.md.
@(test)
generate_test_enum_result_uses_typed_zero_value :: proc(t: ^testing.T) {
	source := generate_source(`package test

E :: enum {
	A,
	B,
}

f{*} :: proc() -> E {
	return .A
}
`)
	test.expect_action_applied_files(
		t,
		&source,
		"Generate test for f",
		{
			{
				"main_test.odin",
				"package test\n\nimport \"core:testing\"\n\n@(test)\ntest_f :: proc(t: ^testing.T) {\n\tresult := f()\n\ttesting.expect_value(t, result, E{})\n}\n",
			},
		},
	)
}

@(test)
generate_test_refused_when_result_needs_a_qualified_type :: proc(t: ^testing.T) {
	source := generate_source(`package test

import "core:time"

f{*} :: proc() -> time.Time {
	return {}
}
`)
	test.expect_action_missing(t, &source, "Generate test for f")
}

// Corpus: manual check, repro2. A `$` nested in a parameter type makes the call `send(nil, {})` fail to compile.
@(test)
generate_test_refused_for_nested_poly_parameter :: proc(t: ^testing.T) {
	source := generate_source(`package test

Ctx :: struct($M: typeid) {
	x: M,
}

se{*}nd :: proc(ctx: ^Ctx($Msg), m: Msg) {
	ctx.x = m
}
`)
	test.expect_action_missing(t, &source, "Generate test for send")
}

// Corpus: framework sweep, gen/a.odin. testing.expect_value needs a comparable type, which a slice,
// dynamic array or map is not, so the test checks the length and frees the result.
@(test)
generate_test_collection_results_check_length :: proc(t: ^testing.T) {
	source := generate_source(
		`package test

f{*} :: proc(n: int) -> ([]int, [dynamic]int, map[string]int) {
	return make([]int, n), nil, nil
}
`,
	)
	test.expect_action_applied_files(
		t,
		&source,
		"Generate test for f",
		{
			{
				"main_test.odin",
				"package test\n\nimport \"core:testing\"\n\n@(test)\ntest_f :: proc(t: ^testing.T) {\n\ta, b, c := f(0)\n\tdefer delete(a)\n\tdefer delete(b)\n\tdefer delete(c)\n\ttesting.expect(t, len(a) == 0)\n\ttesting.expect(t, len(b) == 0)\n\ttesting.expect(t, len(c) == 0)\n}\n",
			},
		},
	)
}

// Corpus: framework sweep. A parameter with a default value, such as an allocator, is left out of the
// call, and a later parameter without one is passed by name.
@(test)
generate_test_omits_defaulted_parameters :: proc(t: ^testing.T) {
	source := generate_source(
		`package test

f{*} :: proc(s: string, allocator := context.allocator, n: int, flag := false) {
}
`,
	)
	test.expect_action_applied_files(
		t,
		&source,
		"Generate test for f",
		{
			{
				"main_test.odin",
				"package test\n\nimport \"core:testing\"\n\n@(test)\ntest_f :: proc(t: ^testing.T) {\n\tf(\"\", n = 0)\n}\n",
			},
		},
	)
}

// A struct holding a slice is not comparable, and no zero-value assertion compiles for it.
@(test)
generate_test_refused_for_non_comparable_result :: proc(t: ^testing.T) {
	source := generate_source(
		`package test

Inner :: struct {
	xs: []int,
}

Outer :: struct {
	inner: [2]Inner,
}

f{*} :: proc() -> Outer {
	return {}
}
`,
	)
	test.expect_action_missing(t, &source, "Generate test for f")

	any_result := generate_source(`package test

f{*} :: proc() -> any {
	return nil
}
`)
	test.expect_action_missing(t, &any_result, "Generate test for f")
}

// Corpus: review of the comparable fix. Neither `delete` nor `expect_value` accepts a fixed-capacity
// dynamic array, a #soa fixed array or a #raw_union struct.
@(test)
generate_test_refused_for_uncomparable_special_types :: proc(t: ^testing.T) {
	fixed_capacity := generate_source(`package test

f{*} :: proc() -> [dynamic; 4]int {
	return {}
}
`)
	test.expect_action_missing(t, &fixed_capacity, "Generate test for f")

	soa := generate_source(`package test

P :: struct {
	x: int,
}

f{*} :: proc() -> #soa[4]P {
	return {}
}
`)
	test.expect_action_missing(t, &soa, "Generate test for f")

	raw_union := generate_source(`package test

R :: struct #raw_union {
	i: int,
	f: f64,
}

f{*} :: proc() -> R {
	return {}
}
`)
	test.expect_action_missing(t, &raw_union, "Generate test for f")
}

// A variadic parameter accepts no arguments, so the call leaves it out.
@(test)
generate_test_omits_variadic_parameters :: proc(t: ^testing.T) {
	source := generate_source(`package test

f{*} :: proc(n: int, xs: ..int) {
}
`)
	test.expect_action_applied_files(
		t,
		&source,
		"Generate test for f",
		{
			{
				"main_test.odin",
				"package test\n\nimport \"core:testing\"\n\n@(test)\ntest_f :: proc(t: ^testing.T) {\n\tf(0)\n}\n",
			},
		},
	)
}

@(test)
generate_test_poly_struct_result :: proc(t: ^testing.T) {
	source := generate_source(`package test

Box :: struct($T: typeid) {
	v: T,
}

f{*} :: proc() -> Box(int) {
	return {}
}
`)
	test.expect_action_applied_files(
		t,
		&source,
		"Generate test for f",
		{
			{
				"main_test.odin",
				"package test\n\nimport \"core:testing\"\n\n@(test)\ntest_f :: proc(t: ^testing.T) {\n\tresult := f()\n\ttesting.expect_value(t, result, Box(int){})\n}\n",
			},
		},
	)
}

// Corpus: host sweep, host_gentest. The indentation comes from code, not from the lines of a raw string.
@(test)
generate_test_ignores_raw_string_indentation :: proc(t: ^testing.T) {
	source := generate_source("package test\n\nMSG :: `header\n  indented line\n`\n\nfo{*}o :: proc(x: int) -> int {\n\treturn x\n}\n")
	test.expect_action_applied_files(
		t,
		&source,
		"Generate test for foo",
		{
			{
				"main_test.odin",
				"package test\n\nimport \"core:testing\"\n\n@(test)\ntest_foo :: proc(t: ^testing.T) {\n\tresult := foo(0)\n\ttesting.expect_value(t, result, 0)\n}\n",
			},
		},
	)
}

// The OS suffix stays last, so the test builds only where x_windows.odin does.
@(test)
generate_test_keeps_the_os_suffix_last :: proc(t: ^testing.T) {
	source := generate_source("")
	source.files = {{"x_windows.odin", `package test

fo{*}o :: proc(a: int) {
}
`}}
	test.expect_action_applied_files(
		t,
		&source,
		"Generate test for foo",
		{
			{
				"x_test_windows.odin",
				"package test\n\nimport \"core:testing\"\n\n@(test)\ntest_foo :: proc(t: ^testing.T) {\n\tfoo(0)\n}\n",
			},
		},
	)
}

@(test)
generate_test_refused_in_os_suffixed_test_file :: proc(t: ^testing.T) {
	source := generate_source("")
	source.files = {{"x_test_windows.odin", `package test

fo{*}o :: proc(a: int) {
}
`}}
	test.expect_action(t, &source, {})
}

// The test file cannot name a type private to the source file, so `Point{}` would not compile there.
@(test)
generate_test_refused_for_file_private_result_type :: proc(t: ^testing.T) {
	source := generate_source(`package test

@(private = "file")
Point :: struct {
	x: int,
}

fo{*}o :: proc() -> [2]Point {
	return {}
}
`)
	test.expect_action_missing(t, &source, "Generate test for foo")
}
