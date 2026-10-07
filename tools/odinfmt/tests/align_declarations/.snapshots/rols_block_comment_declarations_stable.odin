// The formatted output of rols_block_comment_declarations formats to itself.
package odinfmt_test

S :: struct {
	/* a */ x               : int,
	longer_than_the_comment : int,
	/* b */ y               : string,
}

T :: struct {
	/* a long comment */ x : int,
	longer                 : int,
}
