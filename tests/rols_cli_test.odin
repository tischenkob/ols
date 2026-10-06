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

// A file for another target than the host: the name suffix selects it. OTHER_OS_MEMBER spells it in ODIN_OS.
when ODIN_OS == .Windows {
	@(private = "file")
	OTHER_OS :: "linux"
	@(private = "file")
	OTHER_OS_MEMBER :: "Linux"
} else {
	@(private = "file")
	OTHER_OS :: "windows"
	@(private = "file")
	OTHER_OS_MEMBER :: "Windows"
}

// A file of package p with the @(test) procedure name, after the tag lines tags.
@(private = "file")
test_file :: proc(name: string, tags := "") -> string {
	return strings.concatenate(
		{tags, "package p\n\nimport \"core:testing\"\n\n@(test)\n", name, " :: proc(t: ^testing.T) {}\n"},
		context.temp_allocator,
	)
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

// odin test FILE -file ignores the name of the file but not its #+build tags.
@(test)
cli_find_tests_reads_a_named_file_by_its_tags_only :: proc(t: ^testing.T) {
	named := strings.concatenate({"x_", OTHER_OS, ".odin"}, context.temp_allocator)
	tagged := strings.concatenate({"#+build ", OTHER_OS, "\n"}, context.temp_allocator)
	dir, ok := fixture(t, {{named, test_file("t_named")}, {"y.odin", test_file("t_tagged", tagged)}})
	defer os.remove_all(dir)
	if !ok do return

	config: common.Config
	found := server.find_tests(strings.concatenate({dir, "/", named}, context.temp_allocator), &config)
	if testing.expect_value(t, len(found), 1) do testing.expect_value(t, found[0].name, "t_named")
	testing.expect_value(
		t,
		len(server.find_tests(strings.concatenate({dir, "/", "y.odin"}, context.temp_allocator), &config)),
		0,
	)
	testing.expect_value(t, len(server.find_tests(dir, &config)), 0)
}

// The identifier scan before the parse keeps the matches of the fuzzy matcher: across segments, in any case,
// and in a non-ASCII name.
@(test)
cli_find_symbols_scan_keeps_fuzzy_matches :: proc(t: ^testing.T) {
	dir, ok := fixture(
		t,
		{
			{"a.odin", "package p\n\nThing_Open :: proc() {}\n"},
			{"b.odin", "package p\n\nother :: 1\n"},
			{"c.odin", "package p\n\ngr\u00f6\u00dfe_wert :: 1\n"},
		},
	)
	defer os.remove_all(dir)
	if !ok do return

	config: common.Config
	append(&config.workspace_folders, common.WorkspaceFolder{uri = common.create_uri(dir, context.temp_allocator).uri})
	defer delete(config.workspace_folders)

	for query in ([]string{"thop", "THING open", "thing_open"}) {
		found := server.find_symbols(query, &config)
		if testing.expectf(t, len(found) == 1, "%q found %v", query, found) {
			testing.expect_value(t, found[0].name, "Thing_Open")
		}
	}
	found := server.find_symbols("gr\u00f6\u00dfe", &config)
	if testing.expect_value(t, len(found), 1) do testing.expect_value(t, found[0].name, "gr\u00f6\u00dfe_wert")
	testing.expect_value(t, len(server.find_symbols("zzqq", &config)), 0)
}

// With a -target: in checker_args, find and tests evaluate ODIN_OS for that target, and leave the target of the
// `when` evaluation as it was.
@(test)
cli_find_evaluates_when_for_the_checker_target :: proc(t: ^testing.T) {
	text := strings.concatenate(
		{
			"package p\n\nimport \"core:testing\"\n\nwhen ODIN_OS == .",
			OTHER_OS_MEMBER,
			" {\n\tthing_there :: 1\n\t@(test)\n\tt_there :: proc(t: ^testing.T) {}\n} else {\n",
			"\tthing_here :: 1\n\t@(test)\n\tt_here :: proc(t: ^testing.T) {}\n}\n",
		},
		context.temp_allocator,
	)
	dir, ok := fixture(t, {{"a.odin", text}})
	defer os.remove_all(dir)
	if !ok do return

	config: common.Config
	append(&config.workspace_folders, common.WorkspaceFolder{uri = common.create_uri(dir, context.temp_allocator).uri})
	defer delete(config.workspace_folders)

	marks := proc(config: ^common.Config) -> map[string]bool {
		marks := make(map[string]bool, context.temp_allocator)
		for symbol in server.find_symbols("thing", config) do marks[symbol.name] = symbol.otherPlatform
		return marks
	}
	host := marks(&config)
	testing.expect_value(t, host["thing_there"], true)
	testing.expect_value(t, host["thing_here"], false)

	config.checker_args = strings.concatenate({"-target:", OTHER_OS, "_amd64"}, context.temp_allocator)
	other := marks(&config)
	testing.expect_value(t, other["thing_there"], false)
	testing.expect_value(t, other["thing_here"], true)
	found := server.find_tests(dir, &config)
	if testing.expect_value(t, len(found), 1) do testing.expect_value(t, found[0].name, "t_there")
	_, still_set := server.when_target.?
	testing.expect(t, !still_set, "find_symbols and find_tests restore the target of the when evaluation")
}

// A directory named on the command line that the filter skips keeps its subdirectories.
@(test)
cli_package_dirs_below_a_filtered_start_keep_their_subdirectories :: proc(t: ^testing.T) {
	dir, ok := fixture(t, {{"a.odin", "package p\n"}})
	defer os.remove_all(dir)
	if !ok do return
	build := strings.concatenate({dir, "/", "build"}, context.temp_allocator)
	sub := strings.concatenate({build, "/", "sub"}, context.temp_allocator)
	if !testing.expect_value(t, os.make_directory_all(sub), nil) do return
	for file in ([]string{strings.concatenate({build, "/", "b.odin"}, context.temp_allocator), strings.concatenate({sub, "/", "x.odin"}, context.temp_allocator)}) {
		if !testing.expect_value(t, os.write_entire_file(file, "package x\n"), nil) do return
	}

	config := common.Config {
		workspace_exclude = {"build"},
	}
	// The walker reports the subdirectories with symlinks resolved, such as /private/var on macOS.
	dirs := server.package_dirs_below(build, dir, &config)
	has_sub := false
	for found in dirs do has_sub ||= strings.has_suffix(found, "/build/sub")
	testing.expectf(t, len(dirs) == 2 && has_sub, "%v", dirs)
	testing.expect_value(t, len(server.package_dirs_below(dir, dir, &config)), 1)
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
