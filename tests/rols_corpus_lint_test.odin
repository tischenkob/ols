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
ignored_result_skips_error_named_proc_type :: proc(t: ^testing.T) {
	// Corpus: odin-lang/examples glfw.SetErrorCallback, reduced, see docs/corpus-validation.md.
	source := test.Source {
		main = `package test

ErrorProc :: proc()
set_cb :: proc(cb: ErrorProc) -> ErrorProc { return cb }
f :: proc() { set_cb(nil) }
`,
		config = {enable_lint_ignored_result = true},
	}

	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
ignored_result_skips_delete_key :: proc(t: ^testing.T) {
	// Corpus: Skald examples/16_virtual_list/main.odin:45, see docs/corpus-validation.md.
	// The harness has no runtime package, so delete_key is declared with the runtime signature.
	source := test.Source {
		main = `package test

delete_key :: proc(m: ^$T/map[$K]$V, key: K) -> (deleted_key: K, deleted_value: V) {
	return
}
f :: proc(m: ^map[int]bool) { delete_key(m, 1) }
`,
		config = {enable_lint_ignored_result = true},
	}

	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
ignored_result_skips_deferred_guard :: proc(t: ^testing.T) {
	// Corpus: karl2d, 27 hits on sync.mutex_guard, see docs/corpus-validation.md.
	source := test.Source {
		main = `package test

import "sync"
m: sync.Mutex
f :: proc() { sync.mutex_guard(&m) }
`,
		packages = {{pkg = "sync", source = `package sync
Mutex :: struct {}
mutex_unlock :: proc(m: ^Mutex) {}
@(deferred_in=mutex_unlock)
mutex_guard :: proc "contextless" (m: ^Mutex) -> bool { return true }
`}},
		config = {enable_lint_ignored_result = true},
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
