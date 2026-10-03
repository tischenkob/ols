package p

conv :: proc(p: rawptr, $T: typeid) -> T { return (^T)(p)^ }
outer :: proc($A: typeid, p: rawptr) -> A {
	x := conv(p, A)
	return x
}
