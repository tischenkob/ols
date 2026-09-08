package tests

import "core:testing"

import test "src:testing"

@(test)
highlight_read_write :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	co{*}unt := 1
	count = count + 2
	use(&count)
}

use :: proc(p: ^int) {}
`,
		config = {enable_document_highlights = true},
	}

	test.expect_document_highlights(
		t,
		&source,
		{{3, "count", .Write}, {4, "count", .Write}, {4, "count", .Read}, {5, "count", .Write}},
	)
}

@(test)
highlight_return_exits :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() -> int {
	if true {
		ret{*}urn 1
	}
	inner := proc() -> int {
		return 2
	}
	_ = inner
	return 3
}
`,
		config = {enable_document_highlights = true},
	}

	test.expect_document_highlights(t, &source, {{2, "proc", .Text}, {4, "return", .Text}, {10, "return", .Text}})
}

@(test)
highlight_loop_exits :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	outer: for i in 0 ..< 3 {
		switch i {
		case 0:
			break
		case 1:
			continue
		case:
			break outer
		}
		if i == 2 {
			br{*}eak
		}
	}
}
`,
		config = {enable_document_highlights = true},
	}

	test.expect_document_highlights(
		t,
		&source,
		{{3, "for", .Text}, {8, "continue", .Text}, {10, "break", .Text}, {13, "break", .Text}},
	)
}
