package tests

import "core:testing"

import "src:server"

@(private = "file")
finished_with :: proc(output: string) -> server.CheckProcess {
	buffer := make([dynamic]u8, context.temp_allocator)
	append(&buffer, output)
	return {finished = true, buffer = buffer}
}

@(test)
output_that_is_not_json_is_named_in_the_failure :: proc(t: ^testing.T) {
	processes := []server.CheckProcess {
		finished_with("-windows-sdk-root:<path> must be used to target Windows\nmore\n"),
	}
	server.record_check_run(1, processes, 0)
	testing.expect_value(
		t,
		server.check_run.failure,
		"`odin check` printed output that is not its JSON error list: -windows-sdk-root:<path> must be used to target Windows",
	)
}

@(test)
json_that_does_not_parse_keeps_the_plain_failure :: proc(t: ^testing.T) {
	processes := []server.CheckProcess{finished_with("{\"errors\": [")}
	server.record_check_run(1, processes, 0)
	testing.expect_value(t, server.check_run.failure, "`odin check` printed output that is not its JSON error list")
}
