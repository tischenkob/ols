package p

parse :: proc(x: int) -> (ok: bool) {
	ok = false
	if x > 0 {
		return
	}
	ok = true
	return
}
