// The formatted output of rols_block_comment_after_line_comment formats to itself.
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
