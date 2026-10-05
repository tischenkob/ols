package ols_testing

import "core:slice"
import "core:testing"

import "src:server"

// Expects exactly the imports named by `expected`, as written in their import declarations, to be unused.
expect_unused_imports :: proc(t: ^testing.T, src: ^Source, expected: []string) {
	setup(src)
	defer teardown(src)

	unused := server.find_unused_imports(src.document)
	got := make([]string, len(unused), context.temp_allocator)
	for imp, i in unused {
		got[i] = imp.base
	}
	testing.expectf(t, slice.equal(got, expected), "\nExpected unused imports %v but received %v", expected, got)
}
