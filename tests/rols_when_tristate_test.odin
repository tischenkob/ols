#+feature dynamic-literals
package tests

import "core:fmt"
import "core:testing"

import test "src:testing"

// Code that the host builds does not reach a declaration that only a `when` branch holds whose known condition
// rules it out on the host, as odin reports `Undeclared name` there.
@(test)
active_code_misses_declaration_the_host_rules_out :: proc(t: ^testing.T) {
	other := "package test\n\nwhen ODIN_OS == .Freestanding {\n\tFREESTANDING :: 1\n}\n"
	sources := [?]test.Source {
		{main = "package test\n\nmain :: proc() {\n\tx := FREESTAND{*}ING\n}\n", files = {{"b.odin", other}}},
		{
			main = "package test\n\nwhen ODIN_OS == .Freestanding {\n\tFREESTANDING :: 1\n}\n\nmain :: proc() {\n\tx := FREESTAND{*}ING\n}\n",
		},
		{
			main = "package test\n\nIS_FREESTANDING :: ODIN_OS == .Freestanding\n\nwhen IS_FREESTANDING {\n\tFREESTANDING :: 1\n}\n\nmain :: proc() {\n\tx := FREESTAND{*}ING\n}\n",
		},
		{
			main = "package test\n\nimport \"core:plat\"\n\nmain :: proc() {\n\tx := plat.FREESTAND{*}ING\n}\n",
			packages = {
				{pkg = "plat", source = "package plat\n\nwhen ODIN_OS == .Freestanding {\n\tFREESTANDING :: 1\n}\n"},
			},
			collections = {"core" = "test"},
		},
	}
	for &source in sources {
		test.expect_no_hover(t, &source)
	}
}

// A branch whose condition reads a name that the `when` evaluator does not know may be the one that the build
// takes, so code that the host builds still reaches its declaration. A condition that one known operand decides, or
// a `#config` value that no define sets, is known.
@(test)
active_code_reaches_declaration_of_unknown_branch :: proc(t: ^testing.T) {
	Case :: struct {
		condition: string,
		reachable: bool,
	}
	cases := [?]Case {
		{"ODIN_DEBUG", true},
		{"UNDECLARED_FLAG", true},
		{"ODIN_OS == .Freestanding || ODIN_DEBUG", true},
		{"!ODIN_DEBUG && ODIN_OS != .Freestanding && false", false},
		{"ODIN_DEBUG && ODIN_OS == .Freestanding", false},
		{"FLAG", false},
	}
	for c in cases {
		source := test.Source {
			main  = "package test\n\nmain :: proc() {\n\tx := MAY{*}BE\n}\n",
			files = {
				{
					"b.odin",
					fmt.tprintf(
						"package test\n\nFLAG :: #config(FLAG, false)\n\nwhen %s {{\n\tMAYBE :: 1\n}}\n",
						c.condition,
					),
				},
			},
		}
		if c.reachable {
			test.expect_hover(t, &source, "test.MAYBE :: 1")
		} else {
			test.expect_no_hover(t, &source)
		}
	}
}

// Of several fallbacks of one name, one in a branch that the host may take keeps the name reachable, in the same
// file or in another one, whichever the index reads first.
@(test)
active_code_reaches_name_with_one_possible_fallback :: proc(t: ^testing.T) {
	ruled_out := test.File{"a.odin", "package test\n\nwhen ODIN_OS == .Freestanding {\n\tX :: 1\n}\n"}
	possible := test.File{"b.odin", "package test\n\nwhen ODIN_DEBUG {\n\tX :: 1\n}\n"}
	orders := [2][2]test.File{{ruled_out, possible}, {possible, ruled_out}}
	for files in orders {
		files := files
		source := test.Source {
			main  = "package test\n\nmain :: proc() {\n\ty := X{*}\n}\n",
			files = files[:],
		}
		test.expect_hover(t, &source, "test.X :: 1")
	}
	same_file := test.Source {
		main  = "package test\n\nmain :: proc() {\n\ty := X{*}\n}\n",
		files = {
			{
				"c.odin",
				"package test\n\nwhen ODIN_OS == .Freestanding {\n\tX :: 1\n} else when ODIN_DEBUG {\n\tX :: 1\n}\n",
			},
		},
	}
	test.expect_hover(t, &same_file, "test.X :: 1")
}

// A constant of another package that a `when` condition reads is unknown when it reads a name that the package
// does not declare or a builtin that the editor does not seed, so the branch stays possible. A constant that folds
// to a known false rules the branch out.
@(test)
when_condition_reads_unknown_constant_of_other_package :: proc(t: ^testing.T) {
	Case :: struct {
		cfg:       string,
		reachable: bool,
	}
	cases := [?]Case {
		{"package cfg\n\nON :: ODIN_DEBUG\n", true},
		{"package cfg\n\nON :: UNDECLARED\n", true},
		{"package cfg\n\nON :: !MID\nMID :: UNDECLARED\n", true},
		{"package cfg\n\nON :: ODIN_OS == .Freestanding || ODIN_DEBUG\n", true},
		{"package cfg\n\nON :: ODIN_OS == .Freestanding\n", false},
		{"package cfg\n\nON :: ODIN_OS == .Freestanding && ODIN_DEBUG\n", false},
	}
	for c in cases {
		source := test.Source {
			main = `package test

import "core:cfg"

when cfg.ON {
	X :: 1
}

main :: proc() {
	y := X{*}
}
`,
			packages = {{pkg = "cfg", source = c.cfg}},
			collections = {"core" = "test"},
		}
		if c.reachable {
			test.expect_hover(t, &source, "test.X :: 1")
		} else {
			test.expect_no_hover(t, &source)
		}
	}
}
