// Corpus validation follow-up: a leading block comment counts toward the width that aligns a field, a value or a bit_field name.
package odinfmt_test

S :: struct {
	/* a */ x: int,
	longer_than_the_comment: int,
	/* b */ y: int,
}

E :: enum {
	/* a */ A = 1,
	LONGER_THAN_IT = 2,
}

B :: bit_field u8 {
	/* a */ a: u8 | 4,
	longer_name: u8 | 4,
}

f :: proc() {
	s := S {
		/* a */ x = 1,
		longer_than_the_comment = 2,
		y = 3,
	}
}
