package tests

import "core:fmt"
import "core:testing"

import test "src:testing"

// A package constant that keeps a `when` branch inactive on every target.
@(private = "file")
OFF_FILE :: `package test

B_OFF :: false

when B_OFF {
	Mode :: enum {
		A,
	}
	counter: Mode
	mode: Mode
}
`

// In inactive code a name with a platform variant may be another platform's declaration, so a deprecation that
// only the host's variant carries is not reported there.
@(test)
deprecated_skips_name_with_platform_variant_in_inactive_branch :: proc(t: ^testing.T) {
	other_os := "Windows" when ODIN_OS != .Windows else "Linux"
	b := fmt.tprintf(
		`package test

when ODIN_OS == .%s {{
	old :: proc() {{}}
}} else {{
	@(deprecated = "use new")
	old :: proc() {{}}
}}
`,
		other_os,
	)
	main := fmt.tprintf(
		`package test

when ODIN_OS == .%s {{
	f :: proc() {{
		old()
	}}
}}
`,
		other_os,
	)
	source := test.Source {
		main = main,
		files = {{"b.odin", b}},
		config = {enable_lint_deprecated = true},
	}
	test.expect_lint_diagnostics(t, &source, {})
}

// The host's `T` is a constant, the other platform's a type, so the kind of `Max_Size` is unknown there.
@(test)
naming_skips_name_with_platform_variant_in_inactive_branch :: proc(t: ^testing.T) {
	other_os := "Windows" when ODIN_OS != .Windows else "Linux"
	b := fmt.tprintf(
		`package test

when ODIN_OS == .%s {{
	T :: struct {{}}
}} else {{
	T :: 3
}}
`,
		other_os,
	)
	main := fmt.tprintf(
		`package test

when ODIN_OS == .%s {{
	Max_Size :: T
}}
`,
		other_os,
	)
	source := test.Source {
		main = main,
		files = {{"b.odin", b}},
		config = {enable_lint_naming = true},
	}
	test.expect_lint_diagnostics(t, &source, {})
}

// The host's `Make` is a procedure, the other platform's a polymorphic type, so `Small_Make(3)` may be a type there.
@(test)
naming_skips_call_of_name_with_platform_variant_in_inactive_branch :: proc(t: ^testing.T) {
	other_os := "Windows" when ODIN_OS != .Windows else "Linux"
	b := fmt.tprintf(
		`package test

when ODIN_OS == .%s {{
	Make :: struct($N: int) {{}}
}} else {{
	Make :: proc(n: int) -> int {{
		return n
	}}
}}
`,
		other_os,
	)
	main := fmt.tprintf(
		`package test

when ODIN_OS == .%s {{
	Small_Make :: Make(3)
}}
`,
		other_os,
	)
	source := test.Source {
		main = main,
		files = {{"b.odin", b}},
		config = {enable_lint_naming = true},
	}
	test.expect_lint_diagnostics(t, &source, {})
}

@(test)
use_stdlib_skips_inactive_when_branch :: proc(t: ^testing.T) {
	other_os := "Windows" when ODIN_OS != .Windows else "Linux"
	source := test.Source {
		main = fmt.tprintf(
			`package test

when ODIN_OS == .%s {{
	has :: proc(s: []int, x: int) -> bool {{
		for e in s {{
			if e == x {{
				return true
			}}
		}}
		return false
	}}
}} else {{
	has :: proc(s: []int, x: int) -> bool {{
		for e in s {{
			if e == x {{
				return true
			}}
		}}
		return false
	}}
}}
`,
			other_os,
		),
		config = {enable_lint_use_stdlib = true},
	}
	test.expect_lint_diagnostics(t, &source, {{13, "use_stdlib"}})
}

@(test)
use_stdlib_skips_file_the_host_does_not_build :: proc(t: ^testing.T) {
	other_os := "windows" when ODIN_OS != .Windows else "linux"
	source := test.Source {
		main = fmt.tprintf(
			`#+build %s
package test

has :: proc(s: []int, x: int) -> bool {{
	for e in s {{
		if e == x {{
			return true
		}}
	}}
	return false
}}
`,
			other_os,
		),
		config = {enable_lint_use_stdlib = true},
	}
	test.expect_lint_diagnostics(t, &source, {})
}

// `counter` resolves only to a global of an inactive branch, so a store to it is not a dead local store.
@(test)
dead_store_judges_fallback_global_in_active_code :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc() {
	counter = 1
	counter = 2
}
`,
		files = {{"b.odin", OFF_FILE}},
		config = {enable_lint_dead_store = true},
	}
	test.expect_lint_diagnostics(t, &source, {})
}

// `mode` resolves only to a variable of an inactive branch, so a repeated case of it is not a constant.
@(test)
duplicate_condition_judges_fallback_variable_in_active_code :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc(x: int) {
	switch x {
	case mode:
	case mode:
	}
}
`,
		files = {{"b.odin", OFF_FILE}},
		config = {enable_lint_bool_logic = true},
	}
	test.expect_lint_diagnostics(t, &source, {{5, "duplicate-condition"}})
}

// On the host `handler` is a variable, so `register(handler)` in the other branch resolves to it, but the target
// that builds that branch passes the procedure there, whose signature the callback type fixes.
@(test)
unused_parameter_counts_value_use_in_inactive_branch_by_name :: proc(t: ^testing.T) {
	source := test.Source {
		main = fmt.tprintf(
			`package test

register :: proc(f: proc(x: int)) {{
	f(1)
}}

when ODIN_OS == .%v {{
	handler: int
}} else {{
	handler :: proc(x: int) {{
		register(nil)
	}}
	g :: proc() {{
		register(handler)
	}}
}}
`,
			ODIN_OS,
		),
		config = {enable_lint_unused_parameter = true},
	}
	test.expect_lint_diagnostics(t, &source, {})
}
