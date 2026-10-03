package tests

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
check_unused_variable_stays_an_error :: proc(t: ^testing.T) {
	// Odin prints this text for a block-declared variable without any vet flag, and that is a compile error.
	testing.expect_value(
		t,
		server.map_diagnostic_severity("error", "'x' declared but not used"),
		server.DiagnosticSeverity.Error,
	)
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
