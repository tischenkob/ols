package tests

import "core:testing"

import test "src:testing"

@(test)
float_equality_ignores_type_comparison :: proc(t: ^testing.T) {
	// Corpus: odin-godot, reduced, see docs/corpus-validation.md.
	source := test.Source {
		main = `package test

Float :: f32
conv :: proc($T: typeid) -> int {
	when T == Float {
		return 1
	} else {
		return 0
	}
}
`,
		config = {enable_lint_float_equality = true},
	}

	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
bool_compare_keeps_distinct_bool :: proc(t: ^testing.T) {
	// Corpus: odin-http, reduced, see docs/corpus-validation.md.
	// Dropping `== true` would return a distinct b32 from a proc that returns bool.
	source := test.Source {
		main = `package test

B :: distinct b32
g :: proc() -> B { return true }
f :: proc() -> bool { return g() == true }
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
ignored_result_reports_status_results_still :: proc(t: ^testing.T) {
	// `@(require_results)` decides, with a generic result and next to a deferred attribute alike.
	source := test.Source {
		main = `package test

@(require_results) first :: proc(x: $T) -> (T, bool) { return x, true }
cleanup :: proc() {}
@(deferred_none=cleanup)
guard :: proc() -> bool { return true }
finish :: proc(ok: bool) {}
@(deferred_out=finish, require_results)
guard_out :: proc() -> bool { return true }
f :: proc() {
	first(1)
	guard()
	guard_out()
}
`,
		config = {enable_lint_ignored_result = true},
	}

	test.expect_lint_diagnostics(t, &source, {{10, "ignored-result"}, {12, "ignored-result"}})
}

@(test)
bool_compare_reports_plain_bool :: proc(t: ^testing.T) {
	// Only a boolean type other than bool keeps its comparison.
	source := test.Source {
		main = `package test

B :: distinct b32
C :: distinct bool
g :: proc() -> bool { return true }
h :: proc() -> B { return true }
f :: proc(x: bool, y: B, z: C) -> bool {
	_ = h() == true
	_ = y == true
	_ = z == true
	_ = x == true
	return g() == true
}
`,
		config = {enable_lint_simplify = true},
	}

	test.expect_lint_diagnostics(t, &source, {{10, "bool-compare"}, {11, "bool-compare"}})
}
