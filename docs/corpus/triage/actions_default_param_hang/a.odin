package p

mk :: proc(a := 2) -> int {
	return a
}
f :: proc() {
	_ = mk(3)
}
