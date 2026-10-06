#+build !windows
package server

import "core:os"
import "core:sys/posix"

// Whether process has exited, and the signal that killed it, 0 when it exited normally. core:os stores a
// killed child's signal number in exit_code like an exit status, so `check` asks before os.process_wait
// reaps the child. The peek leaves the child waitable.
child_exit_signal :: proc(process: os.Process) -> (signal: int, exited: bool) {
	info: posix.siginfo_t
	for {
		if posix.waitid(.P_PID, posix.id_t(process.pid), &info, {.EXITED, .NOWAIT, .NOHANG}) == 0 {
			break
		}
		if posix.errno() != .EINTR {
			// os.process_wait reports the error itself.
			return 0, true
		}
	}
	if info.si_signo == nil {
		return 0, false
	}
	#partial switch info.si_code.chld {
	case .KILLED, .DUMPED:
		return int(info.si_status), true
	}
	return 0, true
}
