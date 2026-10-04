package tests

import "core:strings"
import "core:testing"

import "src:server"

@(test)
check_vet_findings_are_warnings :: proc(t: ^testing.T) {
	messages := [?]string {
		"Declaration of 'x' shadows declaration at line 8",
		"Unneeded cast of 'z' to identical type 'int'",
		"Unneeded transmute of 'transmute(string)s' to identical type 'string'",
	}
	for message in messages {
		testing.expect_value(t, server.map_diagnostic_severity("error", message), server.DiagnosticSeverity.Warning)
	}
}

@(test)
check_unused_variable_is_an_error_without_a_known_source :: proc(t: ^testing.T) {
	// A file that cannot be parsed keeps the error.
	cache := make(server.Hard_Unused_Cache, context.temp_allocator)
	error := server.Json_Error {
		type = "error",
		pos  = {file = "missing.odin", offset = 5},
	}
	testing.expect_value(
		t,
		server.check_error_severity(error, "'x' declared but not used", &cache),
		server.DiagnosticSeverity.Error,
	)
}

// Names that odin rejects without any vet flag (checked with plain `odin check`), then the names that only
// -vet-unused-variables reports.
@(private = "file")
UNUSED_SOURCE :: `package p
hard_if :: proc(c: bool) { if c { hard_if_x := 1 } }
hard_do :: proc(c: bool) { if c do hard_do_x := 1 }
hard_else :: proc(c: bool) { if c { } else if c { } else { hard_else_x := 1 } }
hard_for :: proc() { for { hard_for_x := 1 } }
hard_range :: proc() { for i in 0..<2 { hard_range_x := 1 } }
vet_block :: proc() { { vet_block_x := 1 } }
vet_two :: proc(c: bool) { if c { vet_two_x := 1; vet_two_y := 2 } }
vet_switch :: proc(c: int) { switch c { case 1: vet_switch_x := 1 } }
vet_proc :: proc() { vet_proc_x := 1 }
vet_param :: proc(vet_param_x: int) { }
`

@(test)
check_unused_variable_severity_follows_the_source :: proc(t: ^testing.T) {
	offsets, parsed := server.hard_unused_offsets(UNUSED_SOURCE)
	testing.expect(t, parsed)
	cache := make(server.Hard_Unused_Cache, context.temp_allocator)
	cache["p.odin"] = {offsets, true}
	names := [?]struct {
		name:     string,
		severity: server.DiagnosticSeverity,
	} {
		{"hard_if_x", .Error},
		{"hard_do_x", .Error},
		{"hard_else_x", .Error},
		{"hard_for_x", .Error},
		{"hard_range_x", .Error},
		{"vet_block_x", .Warning},
		{"vet_two_x", .Warning},
		{"vet_two_y", .Warning},
		{"vet_switch_x", .Warning},
		{"vet_proc_x", .Warning},
		{"vet_param_x", .Warning},
	}
	for n in names {
		error := server.Json_Error {
			type = "error",
			pos  = {file = "p.odin", offset = strings.index(UNUSED_SOURCE, n.name)},
		}
		message := strings.concatenate({"'", n.name, "' declared but not used"}, context.temp_allocator)
		testing.expect_value(t, server.check_error_severity(error, message, &cache), n.severity)
	}
}

@(test)
check_type_errors_stay_errors :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		server.map_diagnostic_severity("error", "Cannot assign value 'x' of type 'int' to 'string'"),
		server.DiagnosticSeverity.Error,
	)
	testing.expect_value(
		t,
		server.map_diagnostic_severity("warning", "Syntax Error: With '-vet-tabs', tabs must be used for indentation"),
		server.DiagnosticSeverity.Error,
	)
}
