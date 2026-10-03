package p

S :: struct { arr: [4]int }
f :: proc(s: ^S) {
	r: arr = s.arr[:2]
	_ = r
}
