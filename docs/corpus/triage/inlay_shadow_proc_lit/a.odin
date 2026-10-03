package p

HP :: distinct int
f :: proc(handle: HP) -> HP {
	handle := proc(x: int) {}
	_ = handle
	return 0
}
