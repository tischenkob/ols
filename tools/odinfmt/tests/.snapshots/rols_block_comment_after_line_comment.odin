// Corpus validation follow-up: a block comment that follows a line comment group on the next line stays before its item.
package odinfmt_test

S :: struct {
	// line
	/* b */ x: int,
	y:         int,
}

f :: proc(
	// line
	/* b */ x: int,
	y: int,
) {}

g :: proc() {
	call(
		// line
		/* b */ x,
		y,
	)
}
