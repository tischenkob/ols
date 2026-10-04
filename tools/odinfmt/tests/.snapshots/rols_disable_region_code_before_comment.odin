package odinfmt_test

g :: proc() {
	x := 1 // odinfmt:disable
	y   :=   2
	// odinfmt:enable
	z := 3
	_, _, _ = x, y, z
}
