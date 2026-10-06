package server

import "core:os"

// Windows has no signals: exited is true and os.process_wait decides alone.
child_exit_signal :: proc(process: os.Process) -> (signal: int, exited: bool) {
	return 0, true
}
