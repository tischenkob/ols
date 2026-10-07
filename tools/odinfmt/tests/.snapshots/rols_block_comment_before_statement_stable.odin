// The formatted output of rols_block_comment_before_statement formats to itself.
/* p */ package odinfmt_test

/* i */ import "core:fmt"
/* j */ foreign import lib "system:c"
/* k */ foreign lib {}
/* l */ #assert(true)

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
	for i := 0; /**/; i += 1 {
		g()
	}
	for i := 0; i < x /**/; i += 1 {
		g()
	}
}
