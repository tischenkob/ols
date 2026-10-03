package p

f :: proc(fd: union{int, f32}) {
	handle: int
	//odinfmt:disable
	switch h in fd {
	case int: handle = h
	case f32: handle = 1
	} //odinfmt:enable
	_ = handle
}
