package tests

import "base:runtime"
import "core:strings"
import "core:testing"

import "src:cli"
import "src:server"

@(private = "file")
finished_with :: proc(output: string) -> server.CheckProcess {
	buffer := make([dynamic]u8, context.temp_allocator)
	append(&buffer, output)
	return {finished = true, buffer = buffer}
}

@(private = "file")
capture_write :: proc(ctx: rawptr, data: []byte) -> (int, int) {
	append((^[dynamic]u8)(ctx), ..data)
	return len(data), 0
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
		"`odin check` printed output that is not its JSON error list: -windows-sdk-root:<path> must be used to target Windows; odin check cannot target Windows on this host, so drop the Windows -target: from checker_args",
	)
	testing.expect(t, server.check_run.windows_sdk, "odin's refusal of a Windows target is flagged")

	server.record_check_run(1, []server.CheckProcess{finished_with("Unknown flag for 'odin check': 'x'\n")}, 0)
	testing.expect_value(
		t,
		server.check_run.failure,
		"`odin check` printed output that is not its JSON error list: Unknown flag for 'odin check': 'x'",
	)
	testing.expect(t, !server.check_run.windows_sdk, "another refusal is not flagged")
}

@(test)
json_that_does_not_parse_keeps_the_plain_failure :: proc(t: ^testing.T) {
	processes := []server.CheckProcess{finished_with("{\"errors\": [")}
	server.record_check_run(1, processes, 0)
	testing.expect_value(t, server.check_run.failure, "`odin check` printed output that is not its JSON error list")
}

// The compile gate skips an extra target or variant check that odin refused for want of -windows-sdk-root, and
// keeps the check on the current target, which then refuses the edit.
@(test)
gate_skips_a_windows_check_that_odin_refuses :: proc(t: ^testing.T) {
	checks := []cli.Gate_Check {
		{dirs = {"/w"}},
		{target = "windows_amd64", dirs = {"/w"}},
		{args = "-target:windows_i386", dirs = {"/w"}},
	}
	reasons := make([dynamic]string, context.temp_allocator)
	server.check_run = {
		ran         = true,
		failure     = "refused",
		windows_sdk = true,
	}
	testing.expect(t, !cli.skip_refused_windows_check(&checks[0], &reasons), "the current target is never skipped")
	testing.expect_value(t, len(checks[0].dirs), 1)
	testing.expect(t, cli.skip_refused_windows_check(&checks[1], &reasons))
	testing.expect_value(t, len(checks[1].dirs), 0)
	testing.expect(t, cli.skip_refused_windows_check(&checks[2], &reasons))
	testing.expect_value(t, len(checks[2].dirs), 0)

	// A skipped check runs no odin after the write either.
	errors, reason, ok := cli.check_errors(checks[1:])
	testing.expectf(t, ok, "check_errors failed: %s", reason)
	testing.expect_value(t, len(errors), 0)

	other := cli.Gate_Check {
		target = "js_wasm32",
		dirs   = {"/w"},
	}
	server.check_run.windows_sdk = false
	testing.expect(t, !cli.skip_refused_windows_check(&other, &reasons), "another failure still refuses")
}

// The editor check shows a failure to the user once, until a check succeeds, and leaves a timeout to the log.
@(test)
editor_check_shows_a_failure_once :: proc(t: ^testing.T) {
	captured: [dynamic]u8
	defer delete(captured)
	writer := server.make_writer(capture_write, &captured)
	shown: string
	defer delete(shown, runtime.heap_allocator())
	failure := "`odin check` printed output that is not its JSON error list: -windows-sdk-root:<path> must be used to target Windows"

	server.check_run = {
		ran     = true,
		failure = failure,
	}
	server.report_check_failure(&writer, &shown)
	text := string(captured[:])
	testing.expectf(t, strings.contains(text, `"method": "window/showMessage"`), "no showMessage in %q", text)
	testing.expectf(t, strings.contains(text, "-windows-sdk-root:<path> must be used"), "no odin text in %q", text)
	testing.expectf(t, strings.contains(text, `"type": 1`), "not an error message: %q", text)

	// A report consumes the run, so a later check that returns before it records a run, such as a save in
	// a skipped package, does not report the failure again from freed temp memory.
	testing.expect(t, !server.check_run.ran, "the report consumes the run")
	testing.expect_value(t, server.check_run.failure, "")
	clear(&captured)
	server.report_check_failure(&writer, &shown)
	testing.expect_value(t, len(captured), 0)

	delete(shown, runtime.heap_allocator())
	shown = ""
	server.check_run = {
		failure = failure,
	}
	server.report_check_failure(&writer, &shown)
	testing.expect_value(t, len(captured), 0)

	server.check_run = {
		ran = true,
	}
	server.report_check_failure(&writer, &shown)
	testing.expect_value(t, len(captured), 0)

	server.check_run = {
		ran     = true,
		failure = server.CHECK_TIMED_OUT,
	}
	server.report_check_failure(&writer, &shown)
	testing.expect_value(t, len(captured), 0)

	server.check_run = {
		ran     = true,
		failure = failure,
	}
	server.report_check_failure(&writer, &shown)
	testing.expect(t, len(captured) > 0, "a failure after a clean check shows again")
}
