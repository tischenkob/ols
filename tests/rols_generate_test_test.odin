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
				"package test\n\nimport \"core:testing\"\n\n@(test)\ntest_parse :: proc(t: ^testing.T) {\n\ta, b := parse(\"\", nil)\n\ttesting.expect_value(t, a, {})\n\ttesting.expect_value(t, b, false)\n}\n",
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
