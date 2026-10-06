// The formatted output of rols_block_comment_bit_field_union formats to itself.
package odinfmt_test

B :: bit_field u8 {
	/* a */ a: u8 | 4,
	/* b */ b: u8 | 4,
}

U :: union {
	/* a */ int,
	f32,
	/* b */ string,
}
