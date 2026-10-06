package server

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "src:common"

// Line and column are 1-based, the column in bytes.
Test_Proc :: struct {
	name, file: string,
	line, col:  int,
	pkg:        string, // the name in the `package` clause, which `odin test` prefixes to the test name
}

// Every @(test) procedure of the package at dir, or of one .odin file, in file then line order. Only the
// files that `odin test` builds count: not `#+build ignore`, and not those that name or tag another target
// than the one of checker_args, else the host. A file named as the target counts whatever its name says, since
// `odin test FILE -file` reads only its tags. A test in a `when` branch that the target does not take (see
// inactive_when_decls, evaluated for the `-target:` of checker_args when it has one) does not count either.
find_tests :: proc(target: string, config: ^common.Config) -> []Test_Proc {
	// The parsed files are not freed.
	context.allocator = context.temp_allocator
	saved_target := set_when_target(config.checker_args)
	defer restore_when_target(saved_target)
	files := []string{target}
	// `odin test FILE -file` builds the file alone, so only a directory brings the constants of other files.
	pkg: ^When_Package
	if os.is_directory(target) {
		files, _ = filepath.glob(fmt.tprintf("%s/*.odin", target), context.temp_allocator)
		pkg = new_clone(When_Package{files = files, allocator = context.temp_allocator})
	}

	tests := make([dynamic]Test_Proc, context.temp_allocator)
	built_on := base_target(config.checker_args)
	for file in files {
		data, err := os.read_entire_file(file, context.temp_allocator)
		if err != nil do continue
		builds :=
			builds_on(file, string(data), built_on) if pkg != nil else tags_build_on(file, string(data), built_on)
		if !builds do continue
		// Only the syntax tree counts: parse_package_file would also index the packages the file imports.
		parsed := parse_syntax(file, string(data)) or_continue
		inactive := inactive_when_decls(&parsed, pkg)
		for decl, attributes in top_level_decls(parsed) {
			if decl in inactive || !slice.contains(attribute_names(attributes), "test") do continue
			for name in decl.names {
				append(&tests, Test_Proc{node_to_string(name), file, name.pos.line, name.pos.column, parsed.pkg_name})
			}
		}
	}
	slice.sort_by(tests[:], proc(a, b: Test_Proc) -> bool {
		return a.file < b.file if a.file != b.file else a.line < b.line
	})
	return tests[:]
}

// The odin test command line for dir, with the collections, defines and checker args of config, plain
// output, and names as -define:ODIN_TEST_NAMES when given.
test_command :: proc(dir: string, names: string, config: ^common.Config) -> []string {
	cmd := make([dynamic]string, context.temp_allocator)
	append(&cmd, config.odin_command if config.odin_command != "" else "odin", "test", dir)
	for k, v in config.collections {
		if k == "" || k == "core" || k == "vendor" || k == "base" do continue
		append(&cmd, strings.concatenate({"-collection:", k, "=", v}, context.temp_allocator))
	}
	for k, v in config.profile.defines {
		append(&cmd, strings.concatenate({"-define:", k, "=", v}, context.temp_allocator))
	}
	append(&cmd, ..split_checker_args(config.checker_args))
	append(&cmd, "-define:ODIN_TEST_FANCY=false")
	// odin test writes the binary into the cwd otherwise.
	if tmp, err := os.temp_directory(context.temp_allocator); err == nil {
		append(&cmd, fmt.tprintf("-out:%s/%s_test", tmp, filepath.base(dir)))
	}
	if names != "" {
		append(&cmd, strings.concatenate({"-define:ODIN_TEST_NAMES=", names}, context.temp_allocator))
	}
	// odin rejects a repeated flag; the last copy wins, so our -out and -define flags beat checker_args.
	return dedupe_flags(cmd[:])
}
