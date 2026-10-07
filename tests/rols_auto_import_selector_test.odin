#+feature dynamic-literals

package tests

import "core:testing"

import "src:server"
import test "src:testing"

@(private = "file")
mem_packages :: proc() -> []test.Package {
	packages := make([dynamic]test.Package, context.temp_allocator)
	append(
		&packages,
		test.Package {
			pkg = "mem",
			source = `package mem
		copy :: proc(dst, src: rawptr, len: int) -> rawptr { return dst }
	`,
		},
	)
	return packages[:]
}

@(test)
auto_import_selector_lists_members_with_import :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package main

main :: proc() {
	mem.{*}
}
`,
		packages = mem_packages(),
		collections = {"core" = "test"},
		config = {enable_auto_import = true},
	}

	test.expect_completion_edits(
		t,
		&source,
		".",
		"copy",
		nil,
		{{newText = "import \"core:mem\"\n", range = {start = {line = 2}, end = {line = 2}}}},
	)
}

@(test)
auto_import_selector_to_bottom :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package main

import "core:fmt"

main :: proc() {
	mem.{*}
}
`,
		packages = mem_packages(),
		collections = {"core" = "test"},
		config = {enable_auto_import = true, enable_add_import_to_bottom = true},
	}

	test.expect_completion_edits(
		t,
		&source,
		".",
		"copy",
		nil,
		{{newText = "\nimport \"core:mem\"", range = {start = {line = 7}, end = {line = 7}}}},
	)
}

@(test)
auto_import_selector_disabled :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package main

main :: proc() {
	mem.{*}
}
`,
		packages = mem_packages(),
		collections = {"core" = "test"},
	}

	test.expect_completion_labels(t, &source, ".", {})
}

@(test)
auto_import_selector_imported_package_adds_nothing :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package main

import "core:mem"

main :: proc() {
	mem.{*}
}
`,
		packages = mem_packages(),
		collections = {"core" = "test"},
		config = {enable_auto_import = true},
	}

	test.expect_completion_edits(
		t,
		&source,
		".",
		"copy",
		server.TextEdit {
			range = {start = {line = 5, character = 5}, end = {line = 5, character = 5}},
			newText = "copy",
		},
		nil,
	)
}

@(test)
auto_import_selector_local_shadows_package :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package main

Arena :: struct {
	used: int,
}

main :: proc() {
	mem: Arena
	mem.{*}
}
`,
		packages = mem_packages(),
		collections = {"core" = "test"},
		config = {enable_auto_import = true},
	}

	test.expect_completion_edits(
		t,
		&source,
		".",
		"used",
		server.TextEdit {
			range = {start = {line = 8, character = 5}, end = {line = 8, character = 5}},
			newText = "used",
		},
		nil,
	)
}

@(test)
auto_import_selector_prefers_core :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package main

main :: proc() {
	mem.{*}
}
`,
		packages = mem_packages(),
		collections = {"core" = "test", "vendor" = "test"},
		config = {enable_auto_import = true},
	}

	test.expect_completion_edits(
		t,
		&source,
		".",
		"copy",
		nil,
		{{newText = "import \"core:mem\"\n", range = {start = {line = 2}, end = {line = 2}}}},
	)
}

@(test)
auto_import_selector_unresolved_local_shadows_package :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package main

main :: proc() {
	mem: Arenaa
	mem.{*}
}
`,
		packages = mem_packages(),
		collections = {"core" = "test"},
		config = {enable_auto_import = true},
	}

	test.expect_completion_labels(t, &source, ".", {})
}

@(test)
auto_import_selector_aliased_import_adds_nothing :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package main

import m "core:mem"

main :: proc() {
	mem.{*}
}
`,
		packages = mem_packages(),
		collections = {"core" = "test"},
		config = {enable_auto_import = true},
	}

	test.expect_completion_labels(t, &source, ".", {})
}
