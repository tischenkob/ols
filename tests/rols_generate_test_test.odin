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
