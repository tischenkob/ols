package p

step :: proc() -> bool { return false }
f :: proc() {
	for step() {}
}
