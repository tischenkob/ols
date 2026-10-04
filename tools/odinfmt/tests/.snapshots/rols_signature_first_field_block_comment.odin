// Review of S19: a block comment on the line of the first parameter stays there, a comment above it stays above.
package odinfmt_test

h :: proc(
	 /* ctx */x: int, // c
	y: int,
) {}

i :: proc(
	// above
	x: int, // c
	y: int,
) {}
