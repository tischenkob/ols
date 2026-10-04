package tests

import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "src:cli"
import "src:common"
import "src:server"

// A temp directory holding files, each a name and a text.
@(private = "file")
fixture :: proc(t: ^testing.T, files: [][2]string) -> (dir: string, ok: bool) {
	dir_err: os.Error
	dir, dir_err = os.make_directory_temp("", "rols_cli_*", context.temp_allocator)
	if !testing.expect_value(t, dir_err, nil) do return "", false
	for entry in files {
		file, _ := filepath.join({dir, entry[0]}, context.temp_allocator)
		if !testing.expect_value(t, os.write_entire_file(file, entry[1]), nil) do return dir, false
	}
	return dir, true
}

// A file for another target than the host: the name suffix selects it.
when ODIN_OS == .Windows {
	@(private = "file")
	OTHER_OS :: "linux"
} else {
	@(private = "file")
	OTHER_OS :: "windows"
}

@(test)
cli_relative_inside_reads_dotdot_as_a_whole_segment :: proc(t: ^testing.T) {
	for file in ([]string{"/ws/a.odin", "/ws/..x.odin", "/ws/pkg/..y/b.odin", "/ws/.hidden"}) {
		rel, inside := cli.relative_inside("/ws", file)
		testing.expectf(t, inside, "%s lies in /ws but relative_inside says %q is outside", file, rel)
	}
	rel, inside := cli.relative_inside("/ws", "/ws/..x.odin")
	testing.expect_value(t, rel, "..x.odin")
	for file in ([]string{"/other/a.odin", "/ws/../a.odin", "/a.odin", "/ws/.."}) {
		rel, inside = cli.relative_inside("/ws", file)
		testing.expectf(t, !inside, "%s lies outside /ws but relative_inside says %q is inside", file, rel)
	}
}

@(test)
cli_find_tests_lists_only_what_odin_test_builds :: proc(t: ^testing.T) {
	test_file := proc(name: string, tags := "") -> string {
		return strings.concatenate({tags, "package p\n\nimport \"core:testing\"\n\n@(test)\n", name, " :: proc(t: ^testing.T) {}\n"}, context.temp_allocator)
	}
	other := strings.concatenate({"c_", OTHER_OS, ".odin"}, context.temp_allocator)
	dir, ok := fixture(
		t,
		{{"a.odin", test_file("t_host")}, {"b.odin", test_file("t_ignore", "#+build ignore\n")}, {other, test_file("t_other")}},
	)
	defer os.remove_all(dir)
	if !ok do return

	config: common.Config
	found := server.find_tests(dir, &config)
	if !testing.expect_value(t, len(found), 1) do return
	testing.expect_value(t, found[0].name, "t_host")
	testing.expect_value(t, found[0].pkg, "p")
}

@(test)
cli_find_symbols_reports_private_and_other_platform_declarations :: proc(t: ^testing.T) {
	other := strings.concatenate({"c_", OTHER_OS, ".odin"}, context.temp_allocator)
	dir, ok := fixture(
		t,
		{
			{"a.odin", "package p\n\n@(private)\nthing_hidden :: proc() {}\nthing_open :: proc() {}\n"},
			{"b.odin", "#+private file\npackage p\n\nthing_file :: 1\n"},
			{"d.odin", "#+build ignore\npackage p\n\nthing_ignored :: 1\n"},
			{other, "package p\n\nthing_other :: proc() {}\n"},
		},
	)
	defer os.remove_all(dir)
	if !ok do return

	config: common.Config
	append(&config.workspace_folders, common.WorkspaceFolder{uri = common.create_uri(dir, context.temp_allocator).uri})
	defer delete(config.workspace_folders)

	found := server.find_symbols("thing", &config)
	flags := make(map[string][2]bool, context.temp_allocator)
	for symbol in found {
		flags[symbol.name] = {symbol.private, symbol.otherPlatform}
	}
	testing.expect_value(t, len(found), 4)
	testing.expect_value(t, flags["thing_open"], [2]bool{false, false})
	testing.expect_value(t, flags["thing_hidden"], [2]bool{true, false})
	testing.expect_value(t, flags["thing_file"], [2]bool{true, false})
	testing.expect_value(t, flags["thing_other"], [2]bool{false, true})
	_, has_ignored := flags["thing_ignored"]
	testing.expect(t, !has_ignored, "a file that no target builds is left out")
}

@(test)
cli_signature_problem_names_the_cause_that_applies :: proc(t: ^testing.T) {
	text := `package p

body :: proc(a: int, b: int) {}
foreign_one :: proc(a: int) ---
poly :: proc(a: $T, b: int) {}
variadic :: proc(a: ..int) {}
defaulted :: proc(a: int, b: int = 1) {}
flagged :: proc(#any_int a: int, b: int) {}
@(export)
exported :: proc(a: int, b: int) {}
`
	// The parsed file is not freed.
	context.allocator = context.temp_allocator
	pkg := new(ast.Package)
	file := ast.File {
		fullpath = "/p/a.odin",
		src      = text,
		pkg      = pkg,
	}
	p := parser.Parser {
		flags = {.Optional_Semicolons},
	}
	if !testing.expect(t, parser.parse_file(&p, &file)) do return
	want := [][2]string {
		{"body", ""},
		{"foreign_one", "the procedure has no body"},
		{"poly", "the procedure is polymorphic or has a where clause"},
		{"variadic", "the procedure is variadic"},
		{"defaulted", "a parameter has a default value"},
		{"flagged", "a parameter has flags such as #any_int or using"},
		{"exported", "an attribute of the procedure fixes its signature"},
	}
	seen := 0
	for decl in server.top_level_value_decls(file) {
		name := decl.names[0].derived.(^ast.Ident).name
		lit := decl.values[0].derived.(^ast.Proc_Lit)
		for entry in want {
			if entry[0] == name {
				testing.expect_value(t, server.signature_problem(decl, lit), entry[1])
				seen += 1
			}
		}
	}
	testing.expect_value(t, seen, len(want))
}
