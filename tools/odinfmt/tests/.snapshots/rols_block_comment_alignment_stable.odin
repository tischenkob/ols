// The formatted output of rols_block_comment_alignment formats to itself.
package odinfmt_test

S :: struct {
	/* a */ x:               int,
	longer_than_the_comment: int,
	/* b */ y:               int,
}

E :: enum {
	/* a */ A      = 1,
	LONGER_THAN_IT = 2,
}

B :: bit_field u8 {
	/* a */ a:   u8 | 4,
	longer_name: u8 | 4,
}

f :: proc() {
	s := S {
		/* a */ x               = 1,
		longer_than_the_comment = 2,
		y                       = 3,
	}
}
