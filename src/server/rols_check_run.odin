package server

import "core:os"

// How the last `check` on this thread went, so a caller can tell "no errors" from "the checker did not
// run". failure is empty when every package check finished with output that parsed; ran is false when
// `check` returned before starting any process. The CLI's compile gate resets it before each check.
Check_Run :: struct {
	ran:     bool,
	failure: string,
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
		ran = true,
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
