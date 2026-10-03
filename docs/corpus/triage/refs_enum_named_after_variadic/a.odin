package p

Align :: enum { Start, Center }
row :: proc(children: ..int, align: Align = .Start) -> int { return len(children) }
main :: proc() {
	_ = row(1, 2, align = .Center)
}
