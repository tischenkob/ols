// The formatted output of rols_block_comment_before_statement formats to itself.
package odinfmt_test

/* e */ G :: 1
/* f */ @(private)
H :: 1

f :: proc() {
	/* a */ x := 1
	y := 2; /* b */ z := 3
	/* c */ g()
	if x > 0 /* d */ {
		g()
	}
	for i := 0;; /**/ i += 1 {
		g()
	}
}
