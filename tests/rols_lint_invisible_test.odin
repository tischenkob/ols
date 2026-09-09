package tests

import "core:testing"

import test "src:testing"

@(test)
lint_invisible_character :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

a := "he​llo"
b := "hello"
c := "\u200b"
d := "admin‮txt"
e := "⁠x"
`,
		config = {enable_lint_invisible_characters = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{{2, "invisible-character"}, {5, "invisible-character"}, {6, "invisible-character"}},
	)
}
