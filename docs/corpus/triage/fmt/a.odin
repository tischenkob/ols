package p

Input :: struct { pos: [2]int }
f :: proc() {
	input: Input
	input = Input{pos = {9, 9}} // far away
	_ = input
}
