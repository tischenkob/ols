// Corpus validation follow-up: a block comment before a field that starts with a flag or `using` leads the field and its flags.
package odinfmt_test

p :: proc(x: int, /* b */ #any_int y: int) {}

S :: struct {
	x: int, /* b */ using t: U,
}

T :: struct {
	/* a */ using s: T,
	y: int,
}

V :: struct {
	/* c */ #subtype base: Base,
	z: int,
}
