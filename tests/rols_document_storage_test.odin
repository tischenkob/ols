package tests

import "core:mem/virtual"
import "core:testing"
import "core:thread"

import "src:server"

// Parallel tests share the process. A reindex on one test's thread used to clear the symbol caches of another
// test's open documents, which made index_updates_preserve_and_invalidate_resolution_caches flaky.
@(test)
document_storage_is_private_to_each_thread :: proc(t: ^testing.T) {
	cache_arena: virtual.Arena
	_ = virtual.arena_init_growing(&cache_arena)
	defer virtual.arena_destroy(&cache_arena)

	previous_documents := server.document_storage.documents
	server.document_storage.documents = make(map[string]server.Document)
	defer {
		delete(server.document_storage.documents)
		server.document_storage.documents = previous_documents
	}
	server.document_storage.documents["cache"] = server.Document {
		symbol_cache_arena = &cache_arena,
	}
	document := &server.document_storage.documents["cache"]
	document.symbols = make(server.SymbolAndNodeMap, 1, virtual.arena_allocator(&cache_arena))

	other := thread.create_and_start(proc() {server.invalidate_document_symbol_caches()})
	thread.join(other)
	thread.destroy(other)

	_, cached := document.symbols.?
	testing.expect(t, cached, "Another thread's cache invalidation must not reach this thread's documents")
}
