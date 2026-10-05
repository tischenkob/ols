package server

import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"

import "src:common"

// How the last `check` on this thread went, so a caller can tell "no errors" from "the checker did not
// run". failure is empty when every package check finished with output that parsed; ran is false when
// `check` returned before starting any process. The CLI's compile gate resets it before each check.
// error_files holds, per package check path, the files that its errors name; `check` makes it in its temp
// memory, and record_check_run keeps it.
Check_Run :: struct {
	ran:         bool,
	failure:     string,
	error_files: map[string][dynamic]string,
}

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
// means the check did not run.
record_check_run :: proc(path_count: int, processes: []CheckProcess, parsed: int) {
	defer clear(&failed_exits)
	check_run = {
		ran         = true,
		error_files = check_run.error_files,
	}
	with_output := 0
	started := 0
	for p in processes {
		if !p.rerun {
			started += 1
		}
		if !p.finished {
			check_run.failure = "`odin check` timed out"
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
