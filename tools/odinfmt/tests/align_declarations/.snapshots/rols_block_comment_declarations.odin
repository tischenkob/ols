// Corpus validation follow-up: with align_struct_declarations, a leading block comment counts toward the name's width.
package odinfmt_test

S :: struct {
	/* a */ x               : int,
	longer_than_the_comment : int,
	/* b */ y               : string,
}
