// The formatted output of rols_block_comment_first_item formats to itself.
package odinfmt_test

S :: struct {
	/* a */ x: int,
	longer: int,
}

E :: enum {
	/* a */ A,
	B,
}

f :: proc() {
	long_call(
		/* a */ aaaaaaaaaaaaaaaaaaaaaaa,
		bbbbbbbbbbbbbbbbbbbbbbbbbb,
		cccccccccccccccccccccccccc,
	)
	v := /* a */ x
	arr := [?]int {
		/* a */ 1,
		2,
	}
}
