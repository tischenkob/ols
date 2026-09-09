package tests

import "core:testing"

import test "src:testing"

@(test)
range_format_only_selected_decl :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

foo :: proc() {
	a:=1
}

bar :: proc() {
	{[b:=2]}
}
`,
		config = {enable_range_format = true},
	}

	test.expect_range_format(t, &source, `package test

foo :: proc() {
	a:=1
}

bar :: proc() {
	b := 2
}
`)
}
