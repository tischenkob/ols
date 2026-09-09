package tests

import "core:testing"

import test "src:testing"

@(test)
lint_unused_variable :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

use :: proc(v: int) {}

locals :: proc() {
	unused := 1
	used := 2
	use(used)
	_ := 3
}

constants :: proc() {
	UNUSED :: 4
	USED :: 5
	use(USED)
}

loops :: proc(n: int) {
	for i := 0; i < n; i += 1 {
		use(i)
	}
	for v in 0 ..< n {
	}
}
`,
		config = {enable_lint_unused_variable = true},
	}

	test.expect_lint_diagnostics(t, &source, {{5, "unused-variable"}, {12, "unused-variable"}})
}

@(test)
lint_fix_unused_variable :: proc(t: ^testing.T) {
	removable := test.Source {
		main = `package test

f :: proc() {
	x{*} := 1
}
`,
		config = {enable_lint_unused_variable = true},
	}

	test.expect_action_applied(t, &removable, "Remove declaration", `package test

f :: proc() {
}
`)

	with_call := test.Source {
		main = `package test

g :: proc() -> int {
	return 0
}

f :: proc() {
	x{*} := g()
}
`,
		config = {enable_lint_unused_variable = true},
	}

	test.expect_action_applied(
		t,
		&with_call,
		"Replace with `_`",
		`package test

g :: proc() -> int {
	return 0
}

f :: proc() {
	x := g()
	_ = x
}
`,
	)
}

@(test)
lint_unused_variable_cases :: proc(t: ^testing.T) {
	cases := []Lint_Case {
		{
			"declared and never used",
			`package test

f :: proc() {
	x := 1
}
`,
			{{3, "unused-variable"}},
		},
		{
			"declared without a value",
			`package test

f :: proc() {
	x: int
}
`,
			{{3, "unused-variable"}},
		},
		{
			"used only in defer",
			`package test

g :: proc(v: int) {}

f :: proc() {
	x := 1
	defer g(x)
}
`,
			{},
		},
		{
			"a name reused in a nested procedure literal hides the outer one",
			`package test

f :: proc() {
	x := 1
	cb := proc(x: int) -> int {
		return x
	}
	_ = cb
}
`,
			{},
		},
		{
			"used inside when",
			`package test

f :: proc() {
	x := 1
	when ODIN_DEBUG {
		_ = x
	}
}
`,
			{},
		},
		{
			"shadowed in a nested block",
			`package test

f :: proc() {
	x := 1
	{
		x := 2
		_ = x
	}
}
`,
			{},
		},
		{
			"range variables are not checked",
			`package test

f :: proc(n: int) {
	for i in 0 ..< n {
	}
}
`,
			{},
		},
		{
			"using declarations are not checked",
			`package test

P :: struct {
	a: int,
}

f :: proc(p: P) {
	using q := p
}
`,
			{},
		},
		{
			"unused local constant",
			`package test

f :: proc() {
	X :: 1
}
`,
			{{3, "unused-variable"}},
		},
		{
			"named results are not locals",
			`package test

f :: proc() -> (out: int) {
	return
}
`,
			{},
		},
		{
			"a later write counts as a use",
			`package test

f :: proc() {
	x := 1
	x = 2
}
`,
			{},
		},
	}

	expect_lint_cases(t, cases, {enable_lint_unused_variable = true})
}

@(test)
lint_fix_unused_variable_multi :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

g :: proc() -> (int, int) {
	return 0, 1
}

f :: proc() {
	x, y{*} := g()
	_ = x
}
`,
		config = {enable_lint_unused_variable = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Replace with `_`",
		`package test

g :: proc() -> (int, int) {
	return 0, 1
}

f :: proc() {
	x, _ := g()
	_ = x
}
`,
	)
}

@(test)
lint_fix_unused_variable_no_value :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() {
	x{*}: int
}
`,
		config = {enable_lint_unused_variable = true},
	}

	test.expect_action_applied(t, &source, "Remove declaration", `package test

f :: proc() {
}
`)
}

@(test)
lint_fix_unused_variable_twice :: proc(t: ^testing.T) {
	cases := []Fix_Twice {
		{
			"unused-variable remove",
			"Remove declaration",
			`package test

f :: proc() {
	x{*} := 1
}
`,
			"f :: proc() {",
		},
		{
			"unused-variable discard",
			"Replace with `_`",
			`package test

g :: proc() -> int {
	return 0
}

f :: proc() {
	x{*} := g()
}
`,
			"_ = x",
		},
	}

	expect_fix_twice(t, cases, {enable_lint_unused_variable = true})
}
