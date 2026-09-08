package tests

import "core:testing"

import test "src:testing"

@(test)
lint_redundant_partial :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Color :: enum {
	Red,
	Green,
}

Value :: union {
	int,
	string,
}

all_enum :: proc(c: Color) {
	#partial switch c {
	case .Red:
	case .Green:
	}
}

qualified :: proc(c: Color) {
	#partial switch c {
	case Color.Red, Color.Green:
	}
}

all_union :: proc(v: Value) {
	#partial switch _ in v {
	case int:
	case string:
	}
}

missing_case :: proc(c: Color) {
	#partial switch c {
	case .Red:
	}
}

has_default :: proc(c: Color) {
	#partial switch c {
	case .Red:
	case:
	}
}

not_partial :: proc(c: Color) {
	switch c {
	case .Red:
	case .Green:
	}
}

not_enum :: proc(n: int) {
	#partial switch n {
	case 0:
	case 1:
	}
}
`,
		config = {enable_lint_switch = true},
	}

	test.expect_lint_diagnostics(
		t,
		&source,
		{{13, "redundant-partial"}, {20, "redundant-partial"}, {26, "redundant-partial"}},
	)
}

@(test)
lint_unnecessary_break :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(n: int) {
	switch n {
	case 0:
		n := n
		_ = n
		break
	case 1:
		for i in 0 ..< n {
			if i == 0 {
				break
			}
		}
	case 2:
		fallthrough
	case 3:
	}
}
`,
		config = {enable_lint_switch = true},
	}

	test.expect_lint_diagnostics(t, &source, {{7, "unnecessary-break"}})
}
