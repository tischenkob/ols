package server

import "base:runtime"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "src:common"

// How the last `check` on this thread went, so a caller can tell "no errors" from "the checker did not
// run". failure is empty when every package check finished with output that parsed; ran is false when
// `check` returned before starting any process. The CLI's compile gate resets it before each check.
// error_files holds, per package check path, the files that its errors name; `check` makes it in its temp
// memory, and record_check_run keeps it. windows_sdk tells that odin refused a Windows target on another host.
Check_Run :: struct {
	ran:         bool,
	failure:     string,
	error_files: map[string][dynamic]string,
	windows_sdk: bool,
}

// The failure of a check that ran out of its time budget.
CHECK_TIMED_OUT :: "`odin check` timed out"

@(thread_local)
check_run: Check_Run

// Processes of the running check that exited non-zero, until record_check_run reads them.
@(private = "file", thread_local)
failed_exits: [dynamic]os.Process

// Called by `check` as each process exits.
note_check_exit :: proc(process: os.Process, exit_code: int) {
	if exit_code != 0 {
		append(&failed_exits, process)
	}
}

// Called by `check` once its processes are done or killed. parsed counts the outputs that unmarshalled.
// odin exits non-zero with its JSON when the code has errors, so only a failing exit without output
// means the check did not run. A restart that a signal killed again fails the same way.
record_check_run :: proc(path_count: int, processes: []CheckProcess, parsed: int) {
	defer clear(&failed_exits)
	check_run = {
		ran         = true,
		error_files = check_run.error_files,
	}
	with_output := 0
	started := 0
	for p in processes {
		// A run that a signal killed with no output was restarted, and the restart counts instead.
		if p.crashed {
			continue
		}
		if !p.rerun {
			started += 1
		}
		if !p.finished {
			check_run.failure = CHECK_TIMED_OUT
			return
		}
		if len(p.buffer) > 0 {
			with_output += 1
			continue
		}
		for failed in failed_exits {
			if failed.pid == p.process.pid {
				check_run.failure = "`odin check` did not run: it exited with an error and printed nothing"
				return
			}
		}
	}
	if started < path_count {
		check_run.failure = "`odin check` could not start; is odin on PATH or odin_command set?"
	} else if parsed < with_output {
		check_run.failure = "`odin check` printed output that is not its JSON error list"
		// odin prints a plain message instead of JSON when it refuses the command line, such as a Windows
		// target on another host, so the failure quotes its first line.
		for p in processes {
			text := strings.trim_space(string(p.buffer[:]))
			if p.crashed || text == "" || strings.has_prefix(text, "{") {
				continue
			}
			line, _, _ := strings.partition(text, "\n")
			// Since odin dev-2026-10, odin asks for -windows-sdk-root to target Windows on another host, and
			// only `odin build` takes that flag.
			check_run.windows_sdk = strings.contains(line, "-windows-sdk-root")
			hint :=
				"; odin check cannot target Windows on this host, so drop the Windows -target: from checker_args" if check_run.windows_sdk else ""
			check_run.failure = strings.concatenate(
				{check_run.failure, ": ", strings.trim_space(line), hint},
				context.temp_allocator,
			)
			break
		}
	}
}

// Called by `check` as each output parses: adds the files that the errors of output name to the error files
// of the check path, spelled as `check` spells diagnostic paths. An error without a position names no file.
note_error_files :: proc(check_path: string, output: Json_Errors) {
	files := check_run.error_files[check_path]
	for e in output.errors {
		if e.pos.file == "" {
			continue
		}
		file := e.pos.file
		when ODIN_OS == .Windows {
			file = common.get_case_sensitive_path(file, context.temp_allocator)
			file, _ = filepath.replace_separators(file, '/', context.temp_allocator)
		}
		if slice.contains(files[:], file) ||
		   map_diagnostic_severity(e.type, strings.join(e.msgs, "\n", context.temp_allocator)) != .Error {
			continue
		}
		if files == nil {
			files = make([dynamic]string, context.temp_allocator)
		}
		append(&files, file)
	}
	check_run.error_files[check_path] = files
}

// Shows the user the failure of the last editor `check` in a window/showMessage, which the server otherwise only
// logs. shown holds the failure last shown, in the heap allocator: a failure shows once until a check succeeds
// or fails otherwise. A timeout is left to the log, since the next check can finish in time.
report_check_failure :: proc(writer: ^Writer, shown: ^string) {
	failure := check_run.failure
	if failure == CHECK_TIMED_OUT || failure == shown^ {
		return
	}
	delete(shown^, runtime.heap_allocator())
	shown^ = strings.clone(failure, runtime.heap_allocator())
	if failure == "" {
		return
	}
	notification := Notification {
		jsonrpc = "2.0",
		method = "window/showMessage",
		params = NotificationLoggingParams{type = .Error, message = failure},
	}
	send_notification(notification, writer)
}
