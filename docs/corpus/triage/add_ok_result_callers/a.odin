package p

get :: proc(x: int) -> (int, bool) {
	return x, true
}
use :: proc() {
	v := get(1)
	_ = v
}
