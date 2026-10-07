package tests

import "core:testing"

import "src:common"
import "src:server"
import test "src:testing"

// The test runner reuses a pool thread, and with it the thread-local index, for later tests. A map that free_index
// deletes but leaves in place keeps the allocator of the test that set it up, which the runner resets and hands to
// another test. A later lookup or insert then writes into that test's memory.
@(test)
free_index_leaves_no_freed_maps :: proc(t: ^testing.T) {
	source := test.Source {
		main = "package test\n{*}",
	}
	// with_document builds the index under the harness lock, so indexing never races a test that edits collections.
	test.with_document(t, &source, proc(t: ^testing.T, _: ^test.Source, _: common.Range) {
		server.free_index()

		testing.expect(t, server.build_cache.loaded_pkgs == nil, "free_index must clear the loaded packages")
		testing.expect(t, server.indexer.index.collection.packages == nil, "free_index must clear the index packages")
		testing.expect(
			t,
			server.indexer.index.collection.allocator.procedure == nil,
			"free_index must drop the allocator of the index",
		)
	})
}
