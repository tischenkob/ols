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
}

// Every @(test) procedure of the package at dir, or of one .odin file, in file then line order.
find_tests :: proc(target: string, config: ^common.Config) -> []Test_Proc {
	files := []string{target}
	if os.is_directory(target) {
		files, _ = filepath.glob(fmt.tprintf("%s/*.odin", target), context.temp_allocator)
	}

	tests := make([dynamic]Test_Proc, context.temp_allocator)
	for file in files {
		if skip_file(filepath.base(file)) do continue
		data, err := os.read_entire_file(file, context.temp_allocator)
		if err != nil do continue
		document := parse_package_file({file, string(data)}, config) or_continue
		for decl, attributes in top_level_decls(document.ast) {
			if !slice.contains(attribute_names(attributes), "test") do continue
			for name in decl.names {
				append(&tests, Test_Proc{node_to_string(name), file, name.pos.line, name.pos.column})
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
	for arg in strings.split(config.checker_args, " ", context.temp_allocator) {
		if arg != "" do append(&cmd, arg)
	}
	append(&cmd, "-define:ODIN_TEST_FANCY=false")
	// odin test writes the binary into the cwd otherwise.
	if tmp, err := os.temp_directory(context.temp_allocator); err == nil {
		append(&cmd, fmt.tprintf("-out:%s/%s_test", tmp, filepath.base(dir)))
	}
	if names != "" {
		append(&cmd, strings.concatenate({"-define:ODIN_TEST_NAMES=", names}, context.temp_allocator))
	}
	return cmd[:]
}
