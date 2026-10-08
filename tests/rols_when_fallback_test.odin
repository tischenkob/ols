#+feature dynamic-literals
package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:testing"

import "src:common"
import test "src:testing"

// Code in an inactive `when` block resolves names that another file declares only in an inactive block.
@(test)
hover_through_inactive_when_type_in_other_file :: proc(t: ^testing.T) {
	source := test.Source {
		main  = `package test

when FLAG {
	run :: proc(sim: ^Sim) {
		entry := &sim.items[0]
		entry.f{*} = 1
	}
}
`,
		files = {
			{"sim.odin", "package test\n\nwhen FLAG {\n\tSim :: struct {\n\t\titems: [4]S,\n\t}\n}\n"},
			{"s.odin", "package test\n\nFLAG :: #config(FLAG, false)\n\nS :: struct {\n\tf: int,\n}\n"},
		},
	}
	test.expect_hover(t, &source, "S.f: int")
}

// An active declaration wins over an inactive one of the same name, whichever file the index reads first.
@(test)
active_when_declaration_wins_over_inactive :: proc(t: ^testing.T) {
	inactive := "package test\n\nA_OFF :: false\n\nwhen A_OFF {\n\tX :: 1\n}\n"
	active := "package test\n\nB_ON :: true\n\nwhen B_ON {\n\tX :: 2\n}\n"
	main := "package test\n\nmain :: proc() {\n\ty := X{*}\n}\n"
	orders := [2][2]test.File{{{"a.odin", inactive}, {"b.odin", active}}, {{"b.odin", active}, {"a.odin", inactive}}}
	for files in orders {
		files := files
		source := test.Source {
			main  = main,
			files = files[:],
		}
		test.expect_hover(t, &source, "test.X :: 2")
	}
}

// Within one indexed file the active branch wins, whichever branch comes first.
@(test)
active_when_branch_wins_within_other_file :: proc(t: ^testing.T) {
	inactive_first := "package test\n\nC_OFF :: false\n\nwhen C_OFF {\n\tY :: 1\n} else {\n\tY :: 2\n}\n"
	active_first := "package test\n\nC_ON :: true\n\nwhen C_ON {\n\tY :: 2\n} else {\n\tY :: 1\n}\n"
	for other in ([2]string{inactive_first, active_first}) {
		source := test.Source {
			main  = "package test\n\nmain :: proc() {\n\ty := Y{*}\n}\n",
			files = {{"c.odin", other}},
		}
		test.expect_hover(t, &source, "test.Y :: 2")
	}
}

// Completion in active code does not offer a declaration that only an inactive `when` block holds.
@(test)
completion_skips_inactive_when_declaration :: proc(t: ^testing.T) {
	source := test.Source {
		main  = "package test\n\nmain :: proc() {\n\tfallb{*}\n}\n",
		files = {
			{
				"b.odin",
				`package test

B_OFF :: false

when B_OFF {
	fallback_only :: proc() {}
}

fallback_active :: proc() {}
`,
			},
		},
	}
	test.expect_completion_labels(t, &source, "", {"fallback_active"}, {"fallback_only"})
}

// The call-arity lint does not check a call against a declaration that only an inactive `when` block holds.
@(test)
lint_calls_skip_inactive_when_target :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\n\nmain :: proc() {\n\ttwo(1)\n}\n",
		files = {{"b.odin", "package test\n\nB_OFF :: false\n\nwhen B_OFF {\n\ttwo :: proc(a, b: int) {}\n}\n"}},
		config = {enable_lint_call_arity = true},
	}
	test.expect_lint_diagnostics(t, &source, {})
}

// A builtin wins over a declaration of the same name that only an inactive `when` block holds.
@(test)
builtin_wins_over_inactive_when_declaration :: proc(t: ^testing.T) {
	source := test.Source {
		main  = "package test\n\nmain :: proc() {\n\tm{*} := min(1, 0.5)\n}\n",
		files = {
			{
				"b.odin",
				"package test\n\nB_OFF :: false\n\nwhen B_OFF {\n\tmin :: proc(a, b: int) -> string { return \"\" }\n}\n",
			},
		},
	}
	test.expect_hover(t, &source, "test.m: f64")
}

// Reindexing either file, as a save does, keeps the active declaration over the inactive one.
@(test)
reindex_keeps_active_when_declaration :: proc(t: ^testing.T) {
	inactive := test.File{"a.odin", "package test\n\nA_OFF :: false\n\nwhen A_OFF {\n\tX :: 1\n}\n"}
	active := test.File{"b.odin", "package test\n\nB_ON :: true\n\nwhen B_ON {\n\tX :: 2\n}\n"}
	orders := [2][2]test.File{{inactive, active}, {active, inactive}}
	for files in orders {
		for reindexed in orders {
			files, reindexed := files, reindexed
			source := test.Source {
				main  = "package test\n\nmain :: proc() {\n\ty := X{*}\n}\n",
				files = files[:],
			}
			test.expect_hover_after_reindex(t, &source, reindexed[:], "test.X :: 2")
		}
	}
}

// Code under a `when` that the host does not build calls the name another file declares for each platform. The
// index holds the host's declaration, so the resolving lints skip that code. The active call is still reported.
@(test)
resolving_lints_skip_inactive_when_branch :: proc(t: ^testing.T) {
	other_os := "Windows" when ODIN_OS != .Windows else "Linux"
	main := fmt.tprintf(
		`package test

when ODIN_OS == .%s {{
	run :: proc() {{
		open()
	}}
}}

check :: proc() {{
	open()
}}
`,
		other_os,
	)
	b := fmt.tprintf(
		`package test

Error :: enum {{ None, Bad }}

when ODIN_OS == .%s {{
	open :: proc() {{}}
}} else {{
	@(require_results)
	open :: proc() -> Error {{ return .None }}
}}
`,
		other_os,
	)
	source := test.Source {
		main = main,
		files = {{"b.odin", b}},
		config = {enable_lint_ignored_result = true},
	}
	test.expect_lint_diagnostics(t, &source, {{9, "ignored-result"}})
}

// In an inactive branch a name that another file declares only for that platform resolves to the fallback, and
// the lints that still run there judge by it: the deprecated lint reports the call, and the naming lint reads the
// poly struct as a type.
@(test)
lints_in_inactive_branch_judge_by_fallback :: proc(t: ^testing.T) {
	other_os := "Windows" when ODIN_OS != .Windows else "Linux"
	b := fmt.tprintf(
		`package test

when ODIN_OS == .%s {{
	@(deprecated = "use new")
	old :: proc() {{}}
	Item :: struct {{}}
	Small_Array :: struct($N: int, $T: typeid) {{
		data: [N]T,
	}}
}}
`,
		other_os,
	)
	main := fmt.tprintf(
		`package test

when ODIN_OS == .%s {{
	Small :: Small_Array(16, Item)
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
		config = {enable_lint_deprecated = true, enable_lint_naming = true},
	}
	test.expect_lint_diagnostics(t, &source, {{5, "deprecated"}})
}

// A file the host does not build is linted for the target that builds it: its calls resolve to that target's
// declarations, so the resolving lints judge them.
@(test)
resolving_lints_run_in_file_the_host_does_not_build :: proc(t: ^testing.T) {
	other_os := "windows" when ODIN_OS != .Windows else "linux"
	source := test.Source {
		main = fmt.tprintf(
			"#+build %s\npackage test\n\n@(require_results)\nown :: proc() -> int {{ return 1 }}\n\ncheck :: proc() {{\n\topen()\n\town()\n}}\n",
			other_os,
		),
		files = {
			{
				"b.odin",
				"package test\n\nError :: enum { None, Bad }\n\n@(require_results)\nopen :: proc() -> Error { return .None }\n",
			},
		},
		config = {enable_lint_ignored_result = true},
	}
	test.expect_lint_diagnostics(t, &source, {{7, "ignored-result"}, {8, "ignored-result"}})
}

// In a file the host does not build, a name that the target building it does not declare resolves to the host's
// declaration, which no lint judges: neither through the resolved map (ignored-result) nor through a callee that a
// lint resolves again (argument-count).
@(test)
resolving_lints_skip_host_declaration_in_excluded_file :: proc(t: ^testing.T) {
	other_os := "windows" when ODIN_OS != .Windows else "linux"
	host_os := "darwin" when ODIN_OS == .Darwin else ("windows" when ODIN_OS == .Windows else "linux")
	source := test.Source {
		main = fmt.tprintf(
			"#+build %s\npackage test\n\nimport \"p\"\n\npair :: proc(a, b: int) {{}}\n\ncheck :: proc() {{\n\tp.open()\n\tpair(p.open())\n}}\n",
			other_os,
		),
		packages = {
			{
				pkg = "p",
				files = {
					{
						"p.odin",
						fmt.tprintf(
							"#+build %s\npackage p\n\n@(require_results)\nopen :: proc() -> int {{ return 1 }}\n",
							host_os,
						),
					},
				},
			},
		},
		config = {enable_lint_ignored_result = true, enable_lint_call_arity = true},
	}
	test.expect_lint_diagnostics(t, &source, {})
}

// The `when` branches of a file the host does not build are evaluated for the target that builds it.
@(test)
resolving_lints_follow_when_of_excluded_file_target :: proc(t: ^testing.T) {
	other_os, other_enum := "windows", "Windows"
	when ODIN_OS == .Windows do other_os, other_enum = "linux", "Linux"
	source := test.Source {
		main = fmt.tprintf(
			"#+build %s\npackage test\n\ncheck :: proc() {{\n\twhen ODIN_OS == .%s {{\n\t\topen()\n\t}}\n\twhen ODIN_OS != .%s {{\n\t\topen()\n\t}}\n}}\n",
			other_os,
			other_enum,
			other_enum,
		),
		files = {{"b.odin", "package test\n\n@(require_results)\nopen :: proc() -> int { return 1 }\n"}},
		config = {enable_lint_ignored_result = true},
	}
	test.expect_lint_diagnostics(t, &source, {{5, "ignored-result"}})
}

// A constant of a file the host does not build that a `when` condition reads is folded for the target that builds it.
@(test)
resolving_lints_fold_constant_of_excluded_file_target :: proc(t: ^testing.T) {
	other_os, other_enum := "windows", "Windows"
	when ODIN_OS == .Windows do other_os, other_enum = "linux", "Linux"
	source := test.Source {
		main = fmt.tprintf(
			"#+build %s\npackage test\n\nIS_OTHER :: ODIN_OS == .%s\n\ncheck :: proc() {{\n\twhen IS_OTHER {{\n\t\topen()\n\t}}\n}}\n",
			other_os,
			other_enum,
		),
		files = {{"b.odin", "package test\n\n@(require_results)\nopen :: proc() -> int { return 1 }\n"}},
		config = {enable_lint_ignored_result = true},
	}
	test.expect_lint_diagnostics(t, &source, {{7, "ignored-result"}})
}

// A package that the `when` evaluation of a lint in a file the host does not build loads into the index is
// collected for the host, not for the target of that file. The parse of the file loads its import p, so only q, which
// the fold of p.ON reaches, loads during the lint.
@(test)
lint_of_excluded_file_builds_index_for_host :: proc(t: ^testing.T) {
	other_os, other_enum := "windows", "Windows"
	when ODIN_OS == .Windows do other_os, other_enum = "linux", "Linux"
	root, err := os.make_directory_temp("", "ols-r3d-index-*", context.temp_allocator)
	if !testing.expectf(t, err == nil, "failed to create temporary directory: %v", err) do return
	defer os.remove_all(root)
	root, err = os.get_absolute_path(root, context.temp_allocator)
	if !testing.expectf(t, err == nil, "failed to resolve temporary directory: %v", err) do return
	files := [2][2]string {
		{"p", "package p\n\nimport \"disk:q\"\n\nON :: q.ON\n"},
		{"q", fmt.tprintf("package q\n\nON :: true\n\nwhen ODIN_OS == .%s {{\n\tY :: 1\n}}\n", other_enum)},
	}
	for file in files {
		dir, _ := filepath.join({root, file[0]}, context.temp_allocator)
		path, _ := filepath.join({dir, "pkg.odin"}, context.temp_allocator)
		if !testing.expect(t, os.make_directory(dir) == nil) do return
		if !testing.expect(t, os.write_entire_file(path, transmute([]byte)file[1]) == nil) do return
	}
	q, _ := filepath.join({root, "q"}, context.temp_allocator)
	source := test.Source {
		main = fmt.tprintf(
			"#+build %s\npackage test\n\nimport \"disk:p\"\n\ncheck :: proc() {{\n\twhen p.ON {{\n\t\tx := 1\n\t\t_ = x\n\t}}\n}}\n",
			other_os,
		),
		collections = {"disk" = root},
	}
	test.expect_index_fallback_after_lint(t, &source, q, "Y", true)
}

// A fallback that an active declaration in another file hid takes the name back when a save drops that declaration.
@(test)
reindex_restores_hidden_fallback :: proc(t: ^testing.T) {
	active := test.File{"a.odin", "package test\n\nX :: 2\n"}
	fallback := test.File{"c.odin", "package test\n\nC_OFF :: false\n\nwhen C_OFF {\n\tX :: 1\n}\n"}
	orders := [2][2]test.File{{active, fallback}, {fallback, active}}
	// Reindexing the hidden fallback's own file first drops it and hides it again.
	saves := [2][]test.File{{{"a.odin", "package test\n"}}, {fallback, {"a.odin", "package test\n"}}}
	for files in orders {
		for reindexed in saves {
			files := files
			source := test.Source {
				main  = "package test\n\nmain :: proc() {\n\ty := X{*}\n}\n",
				files = files[:],
			}
			test.expect_hover_after_reindex(t, &source, reindexed, "test.X :: 1")
		}
	}
}

// A `when` condition reads another package's constant whose value names further constants of that package, or of
// a package it imports. A mutable global, a cycle of constants and a constant that does not fold make it unknown, so
// the `else` branch holds.
@(test)
when_condition_folds_names_in_other_package :: proc(t: ^testing.T) {
	other_false :: "package other\n\nX :: false\n"
	other_true :: "package other\n\nX :: true\n"
	Case :: struct {
		cfg:      string,
		other:    string,
		expected: string,
	}
	cases := [?]Case {
		{
			"package cfg\n\nBASE :: 2\nLEVEL :: BASE\nON :: LEVEL >= 2 && !OFF\nOFF :: false\n",
			other_false,
			"test.X :: 1",
		},
		{"package cfg\n\nON :: A\nA :: B\nB :: A\n", other_false, "test.X :: 2"},
		{"package cfg\n\nimport \"core:other\"\n\nON :: !MID\nMID :: other.X\n", other_false, "test.X :: 1"},
		{"package cfg\n\nimport \"core:other\"\n\nON :: !MID\nMID :: other.X\n", other_true, "test.X :: 2"},
		{"package cfg\n\nimport \"core:other\"\n\nON :: !MID\nMID :: other.Y\n", other_true, "test.X :: 2"},
		{"package cfg\n\nON :: !V\nV := true\n", other_false, "test.X :: 2"},
		{"package cfg\n\nON :: !A\nA :: B\nB :: A\n", other_false, "test.X :: 2"},
		{
			"package cfg\n\nimport \"core:other\"\n\nON :: !MID\nMID :: other.X\n",
			"package other\n\nimport \"core:cfg\"\n\nX :: cfg.MID\n",
			"test.X :: 2",
		},
	}
	for c in cases {
		source := test.Source {
			main = `package test

import "core:cfg"

when cfg.ON {
	X :: 1
} else {
	X :: 2
}

main :: proc() {
	y := X{*}
}
`,
			packages = {{pkg = "cfg", source = c.cfg}, {pkg = "other", source = c.other}},
			collections = {"core" = "test"},
		}
		test.expect_hover(t, &source, c.expected)
	}
}

// The siblings of a file that the host does not build, one for that file's OS and one for the host, as test files.
@(private = "file")
excluded_siblings :: proc(other_os: string) -> [2]test.File {
	return {
		{
			"errors_host.odin",
			fmt.tprintf("#+build !%s\npackage test\n\nerr :: proc() -> int {{ return 0 }}\n", other_os),
		},
		{fmt.tprintf("errors_%s.odin", other_os), "package test\n\nerr :: proc() -> string { return \"\" }\n"},
	}
}

// A call in a file that the host does not build, by tag or by name, reaches the declaration of its own target. A
// file that the host builds reaches the host's.
@(test)
hover_from_excluded_file_reaches_its_target :: proc(t: ^testing.T) {
	other_os := "linux" when ODIN_OS != .Linux else "windows"
	call := "package test\n\nf :: proc() {\n\ty := e{*}rr()\n}\n"
	Case :: struct {
		main:     test.File,
		expected: string,
	}
	cases := [3]Case {
		{{"main.odin", fmt.tprintf("#+build %s\n%s", other_os, call)}, "test.err :: proc() -> string"},
		{{fmt.tprintf("main_%s.odin", other_os), call}, "test.err :: proc() -> string"},
		{{"main.odin", call}, "test.err :: proc() -> int"},
	}
	for c in cases {
		files := make([dynamic]test.File, context.temp_allocator)
		append(&files, c.main)
		siblings := excluded_siblings(other_os)
		append(&files, ..siblings[:])
		source := test.Source {
			files = files[:],
		}
		test.expect_hover(t, &source, c.expected)
	}
}

// A save of a sibling that the host does not build reaches lookups from a file of the same target.
@(test)
hover_from_excluded_file_after_sibling_save :: proc(t: ^testing.T) {
	other_os := "linux" when ODIN_OS != .Linux else "windows"
	files := make([dynamic]test.File, context.temp_allocator)
	append(
		&files,
		test.File {
			"main.odin",
			fmt.tprintf("#+build %s\npackage test\n\nf :: proc() {{\n\ty := e{{*}}rr()\n}}\n", other_os),
		},
	)
	siblings := excluded_siblings(other_os)
	append(&files, ..siblings[:])
	source := test.Source {
		files = files[:],
	}
	saved := test.File{fmt.tprintf("errors_%s.odin", other_os), "package test\n\nerr :: proc() -> f64 { return 0 }\n"}
	test.expect_hover_after_reindex(t, &source, {saved}, "test.err :: proc() -> f64", hover_first = true)
}

// A selector from a file that the host does not build reaches the other package's declaration for that target.
@(test)
hover_from_excluded_file_into_other_package :: proc(t: ^testing.T) {
	other_os := "linux" when ODIN_OS != .Linux else "windows"
	source := test.Source {
		main = fmt.tprintf(
			"#+build %s\npackage test\n\nimport \"core:errs\"\n\nf :: proc() {{\n\ty := errs.e{{*}}rr()\n}}\n",
			other_os,
		),
		packages = {
			{
				pkg = "errs",
				files = {
					{
						"errors_host.odin",
						fmt.tprintf("#+build !%s\npackage errs\n\nerr :: proc() -> int {{ return 0 }}\n", other_os),
					},
					{
						fmt.tprintf("errors_%s.odin", other_os),
						"package errs\n\nerr :: proc() -> string { return \"\" }\n",
					},
				},
			},
		},
		collections = {"core" = "test"},
	}
	test.expect_hover(t, &source, "errs.err :: proc() -> string")
}

// A file that the host does not build still reaches a package whose files all build on the host.
@(test)
hover_from_excluded_file_into_host_package :: proc(t: ^testing.T) {
	other_os := "linux" when ODIN_OS != .Linux else "windows"
	source := test.Source {
		main = fmt.tprintf(
			"#+build %s\npackage test\n\nimport \"core:plain\"\n\nf :: proc() {{\n\tplain.r{{*}}un()\n}}\n",
			other_os,
		),
		packages = {{pkg = "plain", source = "package plain\n\nrun :: proc() {}\n"}},
		collections = {"core" = "test"},
	}
	test.expect_hover(t, &source, "plain.run :: proc()")
}

// The `when` of a file that both build is evaluated for the target of the file that the host does not build.
@(test)
hover_from_excluded_file_through_shared_when :: proc(t: ^testing.T) {
	other_os := "linux" when ODIN_OS != .Linux else "windows"
	other_enum := "Linux" when ODIN_OS != .Linux else "Windows"
	source := test.Source {
		files = {
			{
				"main.odin",
				fmt.tprintf("#+build %s\npackage test\n\nf :: proc() {{\n\ty := e{{*}}rr()\n}}\n", other_os),
			},
			{
				"errors.odin",
				fmt.tprintf(
					"package test\n\nwhen ODIN_OS == .%s {{\n\terr :: proc() -> string {{ return \"\" }}\n}} else {{\n\terr :: proc() -> int {{ return 0 }}\n}}\n",
					other_enum,
				),
			},
		},
	}
	test.expect_hover(t, &source, "test.err :: proc() -> string")
}

// A file that the host does not build sees no declaration of a sibling that its target does not build, and none
// that another file keeps private.
@(test)
hover_from_excluded_file_misses_other_targets_and_private :: proc(t: ^testing.T) {
	other_os := "linux" when ODIN_OS != .Linux else "windows"
	main := test.File {
		"main.odin",
		fmt.tprintf("#+build %s\npackage test\n\nf :: proc() {{\n\ty := e{{*}}rr()\n}}\n", other_os),
	}
	siblings := [2]test.File {
		{
			"errors_host.odin",
			fmt.tprintf("#+build !%s\npackage test\n\nerr :: proc() -> int {{ return 0 }}\n", other_os),
		},
		{
			fmt.tprintf("errors_%s.odin", other_os),
			"package test\n\n@(private = \"file\")\nerr :: proc() -> string { return \"\" }\n",
		},
	}
	files := [3]test.File{main, siblings[0], siblings[1]}
	source := test.Source {
		files = files[:],
	}
	test.expect_hover_after_reindex(t, &source, {}, "")
}

// The removal of a sibling that the host does not build reaches lookups from a file of the same target: with no
// declaration of that target left in the package, the index answers.
@(test)
hover_from_excluded_file_after_sibling_removal :: proc(t: ^testing.T) {
	other_os := "linux" when ODIN_OS != .Linux else "windows"
	files := make([dynamic]test.File, context.temp_allocator)
	append(
		&files,
		test.File {
			"main.odin",
			fmt.tprintf("#+build %s\npackage test\n\nf :: proc() {{\n\ty := e{{*}}rr()\n}}\n", other_os),
		},
	)
	siblings := excluded_siblings(other_os)
	append(&files, ..siblings[:])
	source := test.Source {
		files = files[:],
	}
	removed := []string{fmt.tprintf("errors_%s.odin", other_os)}
	test.expect_hover_after_reindex(t, &source, {}, "test.err :: proc() -> int", hover_first = true, removed = removed)
}

// Completion in a file that the host does not build lists the declarations of its own target, and the builtins.
@(test)
completion_in_excluded_file_lists_its_target :: proc(t: ^testing.T) {
	other_os := "linux" when ODIN_OS != .Linux else "windows"
	for prefix in ([2]string{"er", "le"}) {
		files := make([dynamic]test.File, context.temp_allocator)
		append(
			&files,
			test.File {
				"main.odin",
				fmt.tprintf("#+build %s\npackage test\n\nf :: proc() {{\n\t%s{{*}}\n}}\n", other_os, prefix),
			},
		)
		siblings := excluded_siblings(other_os)
		append(&files, ..siblings[:])
		source := test.Source {
			files = files[:],
		}
		if prefix == "er" {
			test.expect_completion_docs(
				t,
				&source,
				"",
				{"test.err :: proc() -> string"},
				{"test.err :: proc() -> int"},
			)
		} else {
			test.expect_completion_labels(t, &source, "", {"len"})
		}
	}
}

// A selector into a package of which the target builds no file that declares something reaches the index.
@(test)
hover_from_excluded_file_into_package_its_target_does_not_build :: proc(t: ^testing.T) {
	other_os := "linux" when ODIN_OS != .Linux else "windows"
	source := test.Source {
		main = fmt.tprintf(
			"#+build %s\npackage test\n\nimport \"core:errs\"\n\nf :: proc() {{\n\ty := errs.e{{*}}rr()\n}}\n",
			other_os,
		),
		packages = {
			{
				pkg = "errs",
				files = {
					{
						"errors_host.odin",
						fmt.tprintf("#+build !%s\npackage errs\n\nerr :: proc() -> int {{ return 0 }}\n", other_os),
					},
				},
			},
		},
		collections = {"core" = "test"},
	}
	test.expect_hover(t, &source, "errs.err :: proc() -> int")
}

// Two OS names other than the host's, as `when ODIN_OS == .Name` spells them.
@(private = "file")
other_oses :: proc() -> (a, b: string) {
	when ODIN_OS == .Windows {
		return "Darwin", "Linux"
	} else when ODIN_OS == .Linux {
		return "Windows", "Darwin"
	} else {
		return "Windows", "Linux"
	}
}

// Two files that declare T for the OSes a and b, each under a constant of its own file, as in
// `IS_A :: ODIN_OS == .A` and `when IS_A { T :: struct { a: int } }`.
@(private = "file")
fallback_pair :: proc(a, b: string) -> (file_a, file_b: test.File) {
	decl := "package test\n\nIS_%s :: ODIN_OS == .%s\n\nwhen IS_%s {{\n\tT :: struct {{ %s: int }}\n}}\n"
	return {"a.odin", fmt.tprintf(decl, "A", a, "A", "a")}, {"b.odin", fmt.tprintf(decl, "B", b, "B", "b")}
}

// Code under `when ODIN_OS == .B` reaches the declaration that B builds, though the index keeps the fallback of
// another OS from the file that it read first.
@(test)
hover_in_inactive_branch_reaches_its_targets_fallback :: proc(t: ^testing.T) {
	a, b := other_oses()
	file_a := test.File {
		"a.odin",
		fmt.tprintf("package test\n\nwhen ODIN_OS == .%s {{\n\tT :: struct {{ a: int }}\n}}\n", a),
	}
	file_b := test.File {
		"b.odin",
		fmt.tprintf("package test\n\nwhen ODIN_OS == .%s {{\n\tT :: struct {{ b: int }}\n}}\n", b),
	}
	orders := [2][2]test.File{{file_a, file_b}, {file_b, file_a}}
	for files in orders {
		files := files
		source := test.Source {
			main  = fmt.tprintf(
				"package test\n\nwhen ODIN_OS == .%s {{\n\tf :: proc(t: T) -> int {{\n\t\treturn t.b{{*}}\n\t}}\n}}\n",
				b,
			),
			files = files[:],
		}
		test.expect_hover(t, &source, "T.b: int")
	}
}

// Go to definition from code under `when ODIN_OS == .B` lands on the declaration that B builds.
@(test)
definition_in_inactive_branch_reaches_its_targets_fallback :: proc(t: ^testing.T) {
	a, b := other_oses()
	source := test.Source {
		main  = fmt.tprintf("package test\n\nwhen ODIN_OS == .%s {{\n\tf :: proc(t: T{{*}}) {{}}\n}}\n", b),
		files = {
			{"a.odin", fmt.tprintf("package test\n\nwhen ODIN_OS == .%s {{\n\tT :: struct {{ a: int }}\n}}\n", a)},
			{
				"b.odin",
				fmt.tprintf("package test\n\n// b\nwhen ODIN_OS == .%s {{\n\tT :: struct {{ b: int }}\n}}\n", b),
			},
		},
	}
	location := common.Location {
		range = {start = {line = 4, character = 1}, end = {line = 4, character = 2}},
	}
	test.expect_definition_locations(t, &source, {location})
}

// Of two fallbacks of one name in one file, code under `when ODIN_OS == .B` reaches the one of B's branch.
@(test)
hover_in_inactive_branch_reaches_same_file_fallback :: proc(t: ^testing.T) {
	a, b := other_oses()
	source := test.Source {
		main  = fmt.tprintf(
			"package test\n\nwhen ODIN_OS == .%s {{\n\tf :: proc(t: T) -> int {{\n\t\treturn t.b{{*}}\n\t}}\n}}\n",
			b,
		),
		files = {
			{
				"c.odin",
				fmt.tprintf(
					"package test\n\nwhen ODIN_OS == .%s {{\n\tT :: struct {{ a: int }}\n}} else when ODIN_OS == .%s {{\n\tT :: struct {{ b: int }}\n}}\n",
					a,
					b,
				),
			},
		},
	}
	test.expect_hover(t, &source, "T.b: int")
}

// A branch condition and the fallbacks it picks between read a constant that another file of the package declares.
@(test)
hover_in_inactive_branch_reads_constant_of_other_file :: proc(t: ^testing.T) {
	a, b := other_oses()
	source := test.Source {
		main  = "package test\n\nwhen IS_B {\n\tf :: proc(t: T) -> int {\n\t\treturn t.b{*}\n\t}\n}\n",
		files = {
			{"a.odin", "package test\n\nwhen IS_A {\n\tT :: struct { a: int }\n}\n"},
			{"b.odin", "package test\n\nwhen IS_B {\n\tT :: struct { b: int }\n}\n"},
			{"consts.odin", fmt.tprintf("package test\n\nIS_A :: ODIN_OS == .%s\nIS_B :: ODIN_OS == .%s\n", a, b)},
		},
	}
	test.expect_hover(t, &source, "T.b: int")
}

// Code under a branch that the host takes keeps the host's declaration over the fallbacks of other OSes.
@(test)
hover_in_host_branch_keeps_host_declaration :: proc(t: ^testing.T) {
	a, b := other_oses()
	host := fmt.tprint(ODIN_OS)
	source := test.Source {
		main  = fmt.tprintf(
			"package test\n\nwhen ODIN_OS == .%s {{\n\tf :: proc(t: T) -> int {{\n\t\treturn t.h{{*}}\n\t}}\n}}\n",
			host,
		),
		files = {
			{"a.odin", fmt.tprintf("package test\n\nwhen ODIN_OS == .%s {{\n\tT :: struct {{ a: int }}\n}}\n", a)},
			{
				"b.odin",
				fmt.tprintf(
					"package test\n\nwhen ODIN_OS == .%s {{\n\tT :: struct {{ b: int }}\n}} else when ODIN_OS == .%s {{\n\tT :: struct {{ h: int }}\n}}\n",
					b,
					host,
				),
			},
		},
	}
	test.expect_hover(t, &source, "T.h: int")
}

// An ODIN_ARCH branch keeps the host's OS: code under it reaches the fallback of the host's OS for that
// architecture, not that of the first OS that builds the file.
@(test)
hover_in_inactive_arch_branch_keeps_host_os :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		host_os, other_os, arch := "windows", "linux", "i386"
	} else when ODIN_OS == .Linux {
		host_os, other_os, arch := "linux", "windows", "arm64"
	} else {
		host_os, other_os, arch := "darwin", "windows", "amd64"
	}
	decl := "package test\n\nwhen ODIN_ARCH == .%s {{\n\tT :: struct {{ %s: int }}\n}}\n"
	source := test.Source {
		main  = fmt.tprintf(
			"package test\n\nwhen ODIN_ARCH == .%s {{\n\tf :: proc(t: T) -> int {{\n\t\treturn t.h{{*}}\n\t}}\n}}\n",
			arch,
		),
		files = {
			{fmt.tprintf("t_%s.odin", other_os), fmt.tprintf(decl, arch, "o")},
			{fmt.tprintf("t_%s.odin", host_os), fmt.tprintf(decl, arch, "h")},
		},
	}
	test.expect_hover(t, &source, "T.h: int")
}

// A `when` in a procedure body places the names under it like one at file scope.
@(test)
hover_in_inactive_branch_of_procedure_body :: proc(t: ^testing.T) {
	a, b := other_oses()
	source := test.Source {
		main  = fmt.tprintf(
			"package test\n\nf :: proc() {{\n\twhen ODIN_OS == .%s {{\n\t\tv: T\n\t\tx := v.b{{*}}\n\t}}\n}}\n",
			b,
		),
		files = {
			{"a.odin", fmt.tprintf("package test\n\nwhen ODIN_OS == .%s {{\n\tT :: struct {{ a: int }}\n}}\n", a)},
			{"b.odin", fmt.tprintf("package test\n\nwhen ODIN_OS == .%s {{\n\tT :: struct {{ b: int }}\n}}\n", b)},
		},
	}
	test.expect_hover(t, &source, "T.b: int")
}

// The package `posix` of the selector tests, which declares pid_t for two OSes other than the host's.
@(private = "file")
posix_package :: proc(a, b: string) -> test.Package {
	return {
		pkg = "posix",
		source = fmt.tprintf(
			"package posix\n\nwhen ODIN_OS == .%s {{\n\tpid_t :: struct {{ a: int }}\n}} else when ODIN_OS == .%s {{\n\tpid_t :: struct {{ b: int }}\n}}\n",
			a,
			b,
		),
	}
}

// A selector into another package under `when ODIN_OS == .B` reaches the declaration that B builds.
@(test)
hover_selector_in_inactive_branch_reaches_its_targets_fallback :: proc(t: ^testing.T) {
	a, b := other_oses()
	source := test.Source {
		main = fmt.tprintf(
			"package test\n\nimport \"core:posix\"\n\nwhen ODIN_OS == .%s {{\n\tf :: proc(p: posix.pid_t) -> int {{\n\t\treturn p.b{{*}}\n\t}}\n}}\n",
			b,
		),
		packages = {posix_package(a, b)},
		collections = {"core" = "test"},
	}
	test.expect_hover(t, &source, "pid_t.b: int")
}

// Go to definition on a selector into another package under `when ODIN_OS == .B` lands on B's declaration.
@(test)
definition_selector_in_inactive_branch_reaches_its_targets_fallback :: proc(t: ^testing.T) {
	a, b := other_oses()
	source := test.Source {
		main = fmt.tprintf(
			"package test\n\nimport \"core:posix\"\n\nwhen ODIN_OS == .%s {{\n\tf :: proc(p: posix.pi{{*}}d_t) {{}}\n}}\n",
			b,
		),
		packages = {posix_package(a, b)},
		collections = {"core" = "test"},
	}
	location := common.Location {
		range = {start = {line = 5, character = 1}, end = {line = 5, character = 6}},
	}
	test.expect_definition_locations(t, &source, {location})
}

// A `when` nested in an `if` of a procedure body places the names under it like one at file scope.
@(test)
hover_in_inactive_branch_nested_in_if :: proc(t: ^testing.T) {
	a, b := other_oses()
	source := test.Source {
		main  = fmt.tprintf(
			"package test\n\nf :: proc() {{\n\tif true {{\n\t\twhen ODIN_OS == .%s {{\n\t\t\tv: T\n\t\t\tx := v.b{{*}}\n\t\t}}\n\t}}\n}}\n",
			b,
		),
		files = {
			{"a.odin", fmt.tprintf("package test\n\nwhen ODIN_OS == .%s {{\n\tT :: struct {{ a: int }}\n}}\n", a)},
			{"b.odin", fmt.tprintf("package test\n\nwhen ODIN_OS == .%s {{\n\tT :: struct {{ b: int }}\n}}\n", b)},
		},
	}
	test.expect_hover(t, &source, "T.b: int")
}

// In a file that the host does not build, an ODIN_ARCH branch is judged on that file's target, not on the host.
@(test)
hover_in_inactive_arch_branch_of_excluded_file :: proc(t: ^testing.T) {
	when ODIN_OS == .Linux {
		file_os, x, y := "windows", "arm64", "i386"
	} else {
		file_os, x, y := "linux", "i386", "arm64"
	}
	source := test.Source {
		main  = fmt.tprintf(
			"#+build %s\npackage test\n\nwhen ODIN_ARCH == .%s {{\n\tf :: proc(t: T) -> int {{\n\t\treturn t.b{{*}}\n\t}}\n}}\n",
			file_os,
			y,
		),
		files = {
			{
				"c.odin",
				fmt.tprintf(
					"package test\n\nwhen ODIN_ARCH == .%s {{\n\tT :: struct {{ a: int }}\n}} else when ODIN_ARCH == .%s {{\n\tT :: struct {{ b: int }}\n}}\n",
					x,
					y,
				),
			},
		},
	}
	test.expect_hover(t, &source, "T.b: int")
}

// Code under `when IS_B`, where the open file declares `IS_B :: ODIN_OS == .B` through another constant, reaches
// the declaration that B builds, in either order of the files that declare the fallbacks.
@(test)
hover_in_constant_branch_reaches_its_targets_fallback :: proc(t: ^testing.T) {
	a, b := other_oses()
	file_a, file_b := fallback_pair(a, b)
	orders := [2][2]test.File{{file_a, file_b}, {file_b, file_a}}
	for files in orders {
		files := files
		source := test.Source {
			main  = fmt.tprintf(
				"package test\n\nON_B :: (IS_OTHER)\nIS_OTHER :: ODIN_OS == .%s\n\nwhen ON_B {{\n\tf :: proc(t: T) -> int {{\n\t\treturn t.b{{*}}\n\t}}\n}}\n",
				b,
			),
			files = files[:],
		}
		test.expect_hover(t, &source, "T.b: int")
	}
}

// A cycle of constants in a `when` condition leaves the branch unknown, so the first fallback stays.
@(test)
hover_in_cyclic_constant_branch_keeps_first_fallback :: proc(t: ^testing.T) {
	a, _ := other_oses()
	source := test.Source {
		main  = "package test\n\nX :: Y || X\nY :: !X && X\n\nwhen X {\n\tf :: proc(t: T) -> int {\n\t\treturn t.a{*}\n\t}\n}\n",
		files = {
			{"a.odin", fmt.tprintf("package test\n\nwhen ODIN_OS == .%s {{\n\tT :: struct {{ a: int }}\n}}\n", a)},
		},
	}
	test.expect_hover(t, &source, "T.a: int")
}

// A field type of a struct that another file declares under `when ODIN_OS == .B` reaches the declaration that B
// builds, in either order of the files that declare the fallbacks.
@(test)
hover_field_type_of_other_files_branch_reaches_its_targets_fallback :: proc(t: ^testing.T) {
	a, b := other_oses()
	file_a, file_b := fallback_pair(a, b)
	file_c := test.File {
		"c.odin",
		fmt.tprintf("package test\n\nwhen ODIN_OS == .%s {{\n\tS :: struct {{ t: T }}\n}}\n", b),
	}
	orders := [2][3]test.File{{file_a, file_b, file_c}, {file_b, file_a, file_c}}
	for files in orders {
		files := files
		source := test.Source {
			main  = fmt.tprintf(
				"package test\n\nwhen ODIN_OS == .%s {{\n\tf :: proc(s: S) -> int {{\n\t\treturn s.t.b{{*}}\n\t}}\n}}\n",
				b,
			),
			files = files[:],
		}
		test.expect_hover(t, &source, "T.b: int")
	}
}
