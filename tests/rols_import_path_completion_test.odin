#+feature dynamic-literals

package tests

import "core:os"
import "core:path/filepath"
import "core:testing"

import test "src:testing"

// The alias walk skipped `build` (git-ignored or excluded), so import path completion must not offer it.
@(test)
import_path_completion_skips_directories_without_kept_packages :: proc(t: ^testing.T) {
	root, err := os.make_directory_temp("", "ols-import-path-*", context.temp_allocator)
	if !testing.expectf(t, err == nil, "failed to create temporary directory: %v", err) {
		return
	}
	defer os.remove_all(root)

	join :: proc(elems: ..string) -> string {
		joined, _ := filepath.join(elems, context.temp_allocator)
		return joined
	}
	for dir in ([]string{join(root, "kept"), join(root, "deep"), join(root, "deep", "inner"), join(root, "build")}) {
		if !testing.expect(t, os.make_directory(dir) == nil) {
			return
		}
	}

	packages := make([dynamic]test.Package, context.temp_allocator)
	append(&packages, test.Package{pkg = "kept", source = "package kept"})
	append(&packages, test.Package{pkg = "deep/inner", source = "package inner"})

	source := test.Source {
		main        = `package main

import "lib:{*}"
`,
		packages    = packages[:],
		collections = {"lib" = root},
	}

	test.expect_completion_labels(t, &source, "", {"kept", "deep"}, {"build"})
}
