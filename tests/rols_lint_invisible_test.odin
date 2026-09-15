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

// The sources are written with escapes so the characters under test survive editing.
@(test)
lint_invisible_character_cases :: proc(t: ^testing.T) {
	cases := []Lint_Case {
		{"a tab", "package test\n\na := \"x\ty\"\n", {}},
		{"a non-breaking space", "package test\n\na := \"x\u00a0y\"\n", {}},
		{"a raw string", "package test\n\na := `x\u200by`\n", {{2, "invisible-character"}}},
		{"a comment", "package test\n\n// he\u200bllo\nb := 1\n", {}},
		{"an identifier", "package test\n\na\u200bb := 1\n", {}},
		{"a byte order mark", "\ufeffpackage test\n\na := 1\n", {}},
		{"a rune literal", "package test\n\nr := '\u200b'\n", {}},
	}

	expect_lint_cases(t, cases, {enable_lint_invisible_characters = true})
}
