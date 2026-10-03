package p

g: int
read_g :: proc() -> int { return g }
f :: proc() -> int {
	prev := g
	g = 1
	x := read_g()
	g = prev
	return x
}
