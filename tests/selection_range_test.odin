package tests

import "core:testing"

import test "src:testing"

@(test)
selection_range :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	total := 1 + fo{*}o(2)
}

foo :: proc(x: int) -> int {
	return x
}
`,
		config = {enable_selection_range = true},
	}

	test.expect_selection_ranges(
		t,
		&source,
		{
			"foo",
			"foo(2)",
			"1 + foo(2)",
			"total := 1 + foo(2)",
			`{
	total := 1 + foo(2)
}`,
			`proc() {
	total := 1 + foo(2)
}`,
			`main :: proc() {
	total := 1 + foo(2)
}`,
		},
	)
}

@(test)
selection_range_keyword :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	i{*}f true {
		x := 1
	}
}
`,
		config = {enable_selection_range = true},
	}

	test.expect_selection_ranges(
		t,
		&source,
		{
			"if",
			`if true {
		x := 1
	}`,
			`{
	if true {
		x := 1
	}
}`,
			`proc() {
	if true {
		x := 1
	}
}`,
			`main :: proc() {
	if true {
		x := 1
	}
}`,
		},
	)
}
