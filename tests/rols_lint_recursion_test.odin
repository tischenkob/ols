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

foreign import lib "system:lib"

wrap :: proc(n: int) -> int {
	foreign lib {
		wrap :: proc(n: int) -> int ---
	}
	return wrap(n)
}

shadow :: proc(n: int) -> int {
	shadow :: proc(n: int) -> int { return n }
	return shadow(n)
}

shadow_after :: proc(n: int) -> int {
	v := shadow_after(n)
	shadow_after :: proc(n: int) -> int { return n }
	return v
}
`,
		config = {enable_lint_recursion = true},
	}

	test.expect_lint_diagnostics(t, &source, {{3, "infinite-recursion"}})
}
