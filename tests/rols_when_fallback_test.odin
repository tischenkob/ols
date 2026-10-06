#+feature dynamic-literals
package tests

import "core:fmt"
import "core:testing"

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

// A fallback that an active declaration in another file hid takes the name back when a save drops that declaration.
@(test)
reindex_restores_hidden_fallback :: proc(t: ^testing.T) {
	active := test.File{"a.odin", "package test\n\nX :: 2\n"}
	fallback := test.File{"c.odin", "package test\n\nC_OFF :: false\n\nwhen C_OFF {\n\tX :: 1\n}\n"}
	orders := [2][2]test.File{{active, fallback}, {fallback, active}}
	for files in orders {
		files := files
		source := test.Source {
			main  = "package test\n\nmain :: proc() {\n\ty := X{*}\n}\n",
			files = files[:],
		}
		test.expect_hover_after_reindex(t, &source, {{"a.odin", "package test\n"}}, "test.X :: 1")
	}
}

// A `when` condition reads another package's constant whose value names further constants of that package. A cycle
// of constants folds to unknown instead of recursing.
@(test)
when_condition_folds_names_in_other_package :: proc(t: ^testing.T) {
	cases := [2][2]string {
		{"package cfg\n\nBASE :: 2\nLEVEL :: BASE\nON :: LEVEL >= 2 && !OFF\nOFF :: false\n", "test.X :: 1"},
		{"package cfg\n\nON :: A\nA :: B\nB :: A\n", "test.X :: 2"},
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
			packages = {{pkg = "cfg", source = c[0]}},
			collections = {"core" = "test"},
		}
		test.expect_hover(t, &source, c[1])
	}
}
