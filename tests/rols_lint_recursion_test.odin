package tests

import "core:testing"

import test "src:testing"

@(test)
lint_infinite_recursion :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(n: int) -> int {
	return f(n - 1)
}

g :: proc(n: int) -> int {
	if n > 0 {
		return g(n - 1)
	}
	return 0
}

h :: proc(n: int) -> int {
	return n > 0 ? h(n - 1) : 0
}

k :: proc(n: int) -> int {
	cb := proc(n: int) -> int {
		return k(n - 1)
	}
	return cb(n)
}
`,
		config = {enable_lint_recursion = true},
	}

	test.expect_lint_diagnostics(t, &source, {{3, "infinite-recursion"}})
}

@(test)
lint_recursion_cases :: proc(t: ^testing.T) {
	cases := []Lint_Case {
		{
			"a self-call after a loop",
			`package test

f :: proc(n: int) -> int {
	for i in 0 ..< n {
	}
	return f(n - 1)
}
`,
			{},
		},
		{
			"a self-call after an early return",
			`package test

f :: proc(n: int) -> int {
	if n == 0 {
		return 0
	}
	return f(n - 1)
}
`,
			{},
		},
		{
			"a self-call after a switch",
			`package test

f :: proc(n: int) -> int {
	switch n {
	case 0:
		return 0
	}
	return f(n - 1)
}
`,
			{},
		},
		{
			"a deferred self-call",
			`package test

f :: proc(n: int) {
	defer f(n - 1)
}
`,
			{{3, "infinite-recursion"}},
		},
		{
			"mutual recursion",
			`package test

f :: proc(n: int) -> int {
	return g(n - 1)
}

g :: proc(n: int) -> int {
	return f(n - 1)
}
`,
			{},
		},
		{
			"a call through a package",
			`package test

import "other"

f :: proc(n: int) -> int {
	return other.f(n - 1)
}
`,
			{},
		},
	}

	expect_lint_cases(
		t,
		cases,
		{enable_lint_recursion = true},
		{{pkg = "other", source = `package other
f :: proc(n: int) -> int {
	return n
}
`}},
	)
}
