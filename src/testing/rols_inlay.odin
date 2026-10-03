package ols_testing

import "base:runtime"
import "core:slice"
import "core:testing"

import "src:common"
import "src:server"

// rols: the file symbol cache outlives the request that built it. Release the temp memory that the
// resolve used, as the server does after a request, and overwrite it. Then check a hint label survived.
// Only the resolve is scoped, so the document path and files that setup put in temp memory stay valid.
expect_inlay_hints_after_temp_free :: proc(t: ^testing.T, src: ^Source, label: string) {
	setup(src)
	defer teardown(src)

	guard := runtime.default_temp_allocator_temp_begin()
	symbols_and_nodes := server.resolve_entire_file(src.document)
	runtime.default_temp_allocator_temp_end(guard)

	junk := make([]byte, 1 << 20, context.temp_allocator)
	slice.fill(junk, 0xAA)

	range := common.Range {
		end = {line = 9000000},
	}
	hints, ok := server.get_inlay_hints(src.document, range, symbols_and_nodes, &src.config)
	testing.expect(t, ok, "get_inlay_hints failed")

	for hint in hints {
		if hint.label == label do return
	}
	testing.expectf(t, false, "No hint labelled %q among %d hints", label, len(hints))
}
