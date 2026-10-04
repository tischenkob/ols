package odinfmt_test

callee :: proc(a, b: int) {}

f :: proc() {
	callee(1, 2)
	// odinfmt:disable
	callee(   1,2)
	// odinfmt:enable
	callee(3, 4)
}
