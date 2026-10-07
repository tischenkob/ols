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

// In a file the host does not build, a constant that a `when` branch declares names the choice of the target that
// builds the file. With `f :: k` there, `f()` may ignore its result. With `f :: g` there, the lint reports it.
@(test)
ignored_result_follows_when_local_of_excluded_file_target :: proc(t: ^testing.T) {
	Row :: struct {
		target_callee, host_callee: string,
		expected:                   []test.LintExpect,
	}
	rows := []Row{{"k", "g", {}}, {"g", "k", {{9, "ignored-result"}}}}
	for row in rows {
		source := test.Source {
			main = excluded_when_source(row.target_callee, row.host_callee, "f()"),
			files = {{"b.odin", B_REQUIRED}},
			config = {enable_lint_ignored_result = true},
		}
		test.expect_lint_diagnostics(t, &source, row.expected)
	}
}

// Hover in such a file shows the branch of the target that builds it, as its lints and semantic tokens do.
@(test)
hover_follows_when_local_of_excluded_file_target :: proc(t: ^testing.T) {
	source := test.Source {
		main  = excluded_when_source("k", "g", "f{*}()"),
		files = {{"b.odin", B_REQUIRED}},
	}
	test.expect_hover(t, &source, "test.f :: proc() -> int")
}

// References from the call find the declaration in the branch of the target that builds the file, and the call too.
@(test)
references_follow_when_local_of_excluded_file_target :: proc(t: ^testing.T) {
	source := test.Source {
		main  = excluded_when_source("k", "g", "f{*}()"),
		files = {{"b.odin", B_REQUIRED}},
	}
	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 5, character = 2}, end = {line = 5, character = 3}}},
			{range = {start = {line = 9, character = 1}, end = {line = 9, character = 2}}},
		},
	)
}

// A file built only by another OS than the host, whose `when` declares `f` as target_callee on that OS and as
// host_callee elsewhere, and calls `f` on line 9 through `call`.
@(private = "file")
excluded_when_source :: proc(target_callee, host_callee, call: string) -> string {
	other_os, other_enum := "windows", "Windows"
	when ODIN_OS == .Windows do other_os, other_enum = "linux", "Linux"
	return fmt.tprintf(
		"#+build %s\npackage test\n\nh :: proc() {{\n\twhen ODIN_OS == .%s {{\n\t\tf :: %s\n\t}} else {{\n\t\tf :: %s\n\t}}\n\t%s\n}}\n",
		other_os,
		other_enum,
		target_callee,
		host_callee,
		call,
	)
}

@(private = "file")
B_REQUIRED :: "package test\n\n@(require_results)\ng :: proc() -> int { return 1 }\n\nk :: proc() -> int { return 1 }\n"

// A file that several targets build is linted for each of them when a name it calls has platform variants: here
// freebsd_amd64 and netbsd_amd64 build `x.odin`, and either one's `g` may require its results. A diagnostic that
// both targets report comes once.
@(test)
ignored_result_reports_variant_of_each_target_that_builds_the_file :: proc(t: ^testing.T) {
	Row :: struct {
		freebsd, netbsd: string,
		expected:        []test.LintExpect,
	}
	plain :: "package test\n\ng :: proc() -> int { return 1 }\n"
	required :: "package test\n\n@(require_results)\ng :: proc() -> int { return 1 }\n"
	rows := []Row {
		{plain, plain, {}},
		{required, plain, {{4, "ignored-result"}}},
		{plain, required, {{4, "ignored-result"}}},
		{required, required, {{4, "ignored-result"}}},
	}
	for row in rows {
		source := test.Source {
			main = "#+build freebsd, netbsd\npackage test\n\nh :: proc() {\n\tg()\n}\n",
			files = {{"x_freebsd.odin", row.freebsd}, {"x_netbsd.odin", row.netbsd}},
			config = {enable_lint_ignored_result = true},
		}
		test.expect_lint_diagnostics(t, &source, row.expected)
	}
}
