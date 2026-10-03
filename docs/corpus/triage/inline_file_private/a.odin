package p

@(private = "file")
norm :: proc(v: int) -> int { return v }
draw :: proc(x: int, y: int) {
	_ = norm(x)
	_ = y
}
