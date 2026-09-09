package tests

import "core:strings"
import "core:testing"

import "src:common"
import test "src:testing"

@(test)
lint_fix_self_assignment_parens :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: int) -> int {
	a{*} = (a)
	return a
}
`,
		config = {enable_lint_self_assignment = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Remove self-assignment",
		`package test

f :: proc(a: int) -> int {
	return a
}
`,
	)
}

@(test)
lint_fix_unreachable :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() -> int {
	return 1
	x{*} := 2
	_ = x
}
`,
		config = {enable_lint_unreachable_code = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Remove unreachable code",
		`package test

f :: proc() -> int {
	return 1
}
`,
	)
}

@(test)
lint_fix_self_assignment :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: int) -> int {
	a{*} = a
	return a
}
`,
		config = {enable_lint_self_assignment = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Remove self-assignment",
		`package test

f :: proc(a: int) -> int {
	return a
}
`,
	)
}

@(test)
lint_fix_unused_parameter :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a{*}: int, b: int) -> int {
	return b
}
`,
		config = {enable_lint_unused_parameter = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Rename parameter to `_`",
		`package test

f :: proc(_: int, b: int) -> int {
	return b
}
`,
	)
}

@(test)
lint_fix_outside_range :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(a: int, b: int) -> int {
	return b{*}
}
`,
		config = {enable_lint_unused_parameter = true},
	}

	test.expect_action_missing(t, &source, "Rename parameter to `_`")
}

@(test)
lint_fix_unused_parameter_default :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(p{*}: int = 1, q: int) -> int {
	return q
}
`,
		config = {enable_lint_unused_parameter = true},
	}

	test.expect_action_applied(
		t,
		&source,
		"Rename parameter to `_`",
		`package test

f :: proc(_: int = 1, q: int) -> int {
	return q
}
`,
	)
}

Fix_Twice :: struct {
	name:   string,
	title:  string,
	source: string, // carries the {*} cursor
	after:  string, // text of the fixed source; the second cursor goes right after it
}

@(private = "file")
FIX_TWICE :: []Fix_Twice {
	{
		"self-assignment",
		"Remove self-assignment",
		`package test

f :: proc(a: int) -> int {
	a{*} = a
	return a
}
`,
		"return a",
	},
	{
		"unreachable-code",
		"Remove unreachable code",
		`package test

f :: proc() -> int {
	return 1
	x{*} := 2
	_ = x
}
`,
		"return 1",
	},
	{
		"unused-parameter",
		"Rename parameter to `_`",
		`package test

f :: proc(a{*}: int, b: int) -> int {
	return b
}
`,
		"proc(_",
	},
	{
		"no-op-arithmetic",
		"Remove no-op arithmetic",
		`package test

f :: proc(x: int) -> int {
	y := x{*} + 0
	return y
}
`,
		"y := x",
	},
	{
		"append-no-values",
		"Remove append without values",
		`package test

f :: proc(xs: ^[dynamic]int) {
	app{*}end(xs)
	append(xs, 1)
}
`,
		"append(xs",
	},
	{
		"range-off-by-one inclusive",
		"Use ..< instead of ..=",
		`package test

r :: proc(xs: []int) {
	for i in 0 ..={*} len(xs) {
	}
}
`,
		"0 ..<",
	},
	{
		"range-off-by-one plus one",
		"Remove '+ 1' from the range end",
		`package test

r :: proc(s: string) {
	for i in 0 ..< len(s){*} + 1 {
	}
}
`,
		"len(s)",
	},
}

expect_fix_twice :: proc(t: ^testing.T, cases: []Fix_Twice, config: common.Config) {
	for c in cases {
		source := test.Source {
			main   = c.source,
			config = config,
		}

		_, fixed := test.apply_action_chain(t, &source, {c.title})
		at := strings.index(fixed, c.after)
		if !testing.expectf(t, at >= 0, "\n%s: no %q in\n%s", c.name, c.after, fixed) {
			continue
		}
		at += len(c.after)

		again := test.Source {
			main   = strings.concatenate({fixed[:at], "{*}", fixed[at:]}, context.temp_allocator),
			config = config,
		}
		test.expect_action_missing(t, &again, c.title)
	}
}

@(test)
lint_fix_twice :: proc(t: ^testing.T) {
	expect_fix_twice(
		t,
		FIX_TWICE,
		{
			enable_lint_self_assignment = true,
			enable_lint_unreachable_code = true,
			enable_lint_unused_parameter = true,
			enable_lint_no_op = true,
			enable_lint_loops = true,
		},
	)
}
