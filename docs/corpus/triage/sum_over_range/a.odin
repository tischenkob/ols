package p

total :: proc() -> int {
	t := 0
	for i in 1 ..= 10 {
		t += i
	}
	return t
}
