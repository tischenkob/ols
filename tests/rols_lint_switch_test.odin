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

@(test)
lint_switch_cases :: proc(t: ^testing.T) {
	cases := []Lint_Case {
		{
			"a labelled break leaves the switch",
			`package test

Color :: enum {
	Red,
	Green,
}

f :: proc(c: Color) {
	outer: switch c {
	case .Red:
		break outer
	case .Green:
	}
}
`,
			{},
		},
		{
			"a case whose only statement is break",
			`package test

Color :: enum {
	Red,
	Green,
}

f :: proc(c: Color) {
	switch c {
	case .Red:
		break
	case .Green:
	}
}
`,
			{{10, "unnecessary-break"}},
		},
	}

	expect_lint_cases(t, cases, {enable_lint_switch = true})
}

@(test)
lint_fix_switch :: proc(t: ^testing.T) {
	partial := test.Source {
		main = `package test

Color :: enum {
	Red,
	Green,
}

f :: proc(c: Color) {
	#par{*}tial switch c {
	case .Red:
	case .Green:
	}
}
`,
		config = {enable_lint_switch = true},
	}

	test.expect_action_applied(
		t,
		&partial,
		"Remove #partial",
		`package test

Color :: enum {
	Red,
	Green,
}

f :: proc(c: Color) {
	switch c {
	case .Red:
	case .Green:
	}
}
`,
	)

	unnecessary := test.Source {
		main = `package test

f :: proc(n: int) {
	switch n {
	case 0:
		n := n
		_ = n
		bre{*}ak
	}
}
`,
		config = {enable_lint_switch = true},
	}

	test.expect_action_applied(
		t,
		&unnecessary,
		"Remove break",
		`package test

f :: proc(n: int) {
	switch n {
	case 0:
		n := n
		_ = n
	}
}
`,
	)
}

@(test)
lint_fix_switch_twice :: proc(t: ^testing.T) {
	cases := []Fix_Twice {
		{
			"redundant-partial",
			"Remove #partial",
			`package test

Color :: enum {
	Red,
	Green,
}

f :: proc(c: Color) {
	#par{*}tial switch c {
	case .Red:
	case .Green:
	}
}
`,
			"switch c {",
		},
		{
			"unnecessary-break",
			"Remove break",
			`package test

f :: proc(n: int) {
	switch n {
	case 0:
		n := n
		_ = n
		bre{*}ak
	}
}
`,
			"_ = n",
		},
	}

	expect_fix_twice(t, cases, {enable_lint_switch = true})
}
