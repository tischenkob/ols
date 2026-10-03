package p

f :: proc(got: int, d := 0) {
	_ = got
}

g :: proc() {
	f(1)
}
