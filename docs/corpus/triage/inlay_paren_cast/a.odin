package p

f :: proc(p: rawptr) {
	x := (^int)(p)
	_ = x
}
