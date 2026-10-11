package tests

import "core:encoding/json"
import "core:testing"

import "src:server"

@(private = "file")
cancelled_id :: proc(t: ^testing.T, message: string) -> (server.RequestId, bool) {
	// The reader thread parses each message with integers on.
	value, err := json.parse_string(message, allocator = context.temp_allocator, parse_integers = true)
	testing.expect(t, err == nil)
	return server.cancelled_request_id(value.(json.Object))
}

@(test)
cancel_request_reads_the_id_from_params :: proc(t: ^testing.T) {
	id, ok := cancelled_id(t, `{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":777}}`)
	testing.expect(t, ok)
	testing.expect_value(t, id, server.RequestId(i64(777)))
}

@(test)
cancel_request_reads_a_string_id :: proc(t: ^testing.T) {
	id, ok := cancelled_id(t, `{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":"abc"}}`)
	testing.expect(t, ok)
	testing.expect_value(t, id, server.RequestId("abc"))
}

@(test)
cancel_request_without_an_id_cancels_nothing :: proc(t: ^testing.T) {
	_, ok := cancelled_id(t, `{"jsonrpc":"2.0","method":"$/cancelRequest"}`)
	testing.expect(t, !ok)

	_, ok = cancelled_id(t, `{"jsonrpc":"2.0","method":"$/cancelRequest","params":{}}`)
	testing.expect(t, !ok)
}
