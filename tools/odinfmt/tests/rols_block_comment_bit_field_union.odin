// Corpus validation follow-up: a block comment before a bit_field field or a union member on its line stays before it.
package odinfmt_test

B :: bit_field u8 {
	/* a */ a: u8 | 4, /* b */ b: u8 | 4,
}

U :: union {
	/* a */ int,
	f32, /* b */ string,
}
