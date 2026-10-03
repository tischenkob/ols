package p

Float :: f32
conv :: proc($T: typeid) -> int {
	when T == Float {
		return 1
	} else {
		return 0
	}
}
