package p

ErrorProc :: proc()
set_cb :: proc(cb: ErrorProc) -> ErrorProc { return cb }
f :: proc() { set_cb(nil) }
