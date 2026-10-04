package tests

import "core:slice"
import "core:testing"

import "src:common"
import "src:server"

@(private = "file")
error :: proc(line: int, message: string, type := "error") -> server.Json_Error {
	msgs := make([]string, 1, context.temp_allocator)
	msgs[0] = message
	return {type = type, pos = {file = "/p/a.odin", line = line, column = 3}, msgs = msgs}
}

@(test)
style_syntax_error_stays_as_a_warning_beside_the_rerun_errors :: proc(t: ^testing.T) {
	comma := error(11, "Syntax Error: Expected a comma, got a newline", "warning")
	first := server.Json_Errors{1, {comma}}
	rerun := server.Json_Errors{1, {error(13, "Cannot convert")}}
	merged := server.merge_style_rerun(first, rerun)
	testing.expect_value(t, merged.error_count, 2)
	testing.expect_value(t, len(merged.errors), 2)
	testing.expect_value(t, merged.errors[0].msgs[0], "Cannot convert")
	testing.expect_value(t, merged.errors[1].msgs[0], comma.msgs[0])
	testing.expect_value(t, merged.errors[1].type, server.STYLE_ERROR_TYPE)
	diagnostics := []server.DiagnosticSeverity {
		server.map_diagnostic_severity(comma.type, comma.msgs[0]),
		server.check_error_severity(merged.errors[1], comma.msgs[0], &server.Hard_Unused_Cache{}),
	}
	testing.expect_value(t, diagnostics[0], server.DiagnosticSeverity.Error)
	testing.expect_value(t, diagnostics[1], server.DiagnosticSeverity.Warning)
}

@(test)
real_syntax_error_in_both_runs_is_reported_once_as_an_error :: proc(t: ^testing.T) {
	real := error(4, "Syntax Error: Expected '}', got EOF")
	comma := error(11, "Syntax Error: Expected a comma, got a newline", "warning")
	merged := server.merge_style_rerun({2, {real, comma}}, {1, {real}})
	testing.expect_value(t, len(merged.errors), 2)
	testing.expect_value(t, merged.errors[0].type, "error")
	testing.expect_value(t, merged.errors[1].type, server.STYLE_ERROR_TYPE)
}

@(test)
clean_rerun_turns_every_style_error_into_a_warning :: proc(t: ^testing.T) {
	comma := error(11, "Syntax Error: Expected a comma, got a newline", "warning")
	tabs := error(12, "With '-vet-tabs', tabs must be used for indentation", "warning")
	merged := server.merge_style_rerun({2, {comma, tabs}}, {})
	testing.expect_value(t, len(merged.errors), 2)
	testing.expect_value(t, merged.errors[0].type, server.STYLE_ERROR_TYPE)
	testing.expect_value(t, merged.errors[1].type, server.STYLE_ERROR_TYPE)
}

@(test)
a_stopping_error_asks_for_the_rerun :: proc(t: ^testing.T) {
	testing.expect(t, server.has_stopping_error({1, {error(1, "Syntax Error: x")}}))
	testing.expect(t, server.has_stopping_error({1, {error(1, "With '-vet-tabs', tabs must be used for indentation", "warning")}}))
	testing.expect(t, !server.has_stopping_error({1, {error(1, "Cannot convert")}}))
	testing.expect(t, !server.has_stopping_error({}))
}

@(test)
rerun_command_drops_only_the_style_flags :: proc(t: ^testing.T) {
	config := common.Config {
		enable_checker_vet_style     = true,
		enable_checker_vet_semicolon = true,
		enable_checker_vet_tabs      = true,
		enable_checker_vet_cast      = true,
		checker_args                 = "-strict-style -vet",
	}
	cmd := server.check_command("pkg/", nil, &config)
	testing.expect(t, server.style_flags_on(cmd))
	rerun := server.without_style_flags(cmd)
	testing.expect(t, !server.style_flags_on(rerun))
	testing.expect(t, slice.contains(rerun, "-vet-cast"))
	testing.expect(t, slice.contains(rerun, "-vet"))
	testing.expect(t, slice.contains(rerun, "-json-errors"))
	testing.expect(t, !server.style_flags_on(server.check_command("pkg/", nil, &common.Config{})))
}

@(test)
tabs_error_beside_a_style_syntax_error_stays_as_a_warning :: proc(t: ^testing.T) {
	tabs := error(5, "With '-vet-tabs', tabs must be used for indentation", "warning")
	comma := error(11, "Syntax Error: Expected a comma, got a newline", "warning")
	merged := server.merge_style_rerun({2, {tabs, comma}}, {1, {error(13, "Cannot convert")}})
	testing.expect_value(t, len(merged.errors), 3)
	testing.expect_value(t, merged.errors[1].msgs[0], tabs.msgs[0])
	testing.expect_value(t, merged.errors[1].type, server.STYLE_ERROR_TYPE)
}
