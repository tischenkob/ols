// The formatted output of rols_block_comment_field_flag formats to itself.
package odinfmt_test

p :: proc(
	x: int,
	/* b */ #any_int y: int,
) {}

S :: struct {
	x:       int,
	/* b */ using t: U,
}

T :: struct {
	/* a */ using s: T,
	y:       int,
}

V :: struct {
	/* c */ #subtype base: Base,
	z:    int,
}
