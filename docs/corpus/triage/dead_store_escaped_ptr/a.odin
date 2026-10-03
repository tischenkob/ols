package p

Holder :: struct { p: ^int }
read :: proc(h: ^Holder) -> int { return h.p^ }
f :: proc() -> int {
	x: int
	h := Holder{p = &x}
	x = 5
	a := read(&h)
	x = 6
	return a + read(&h)
}
