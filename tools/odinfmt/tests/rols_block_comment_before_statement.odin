// Corpus validation follow-up: a block comment before a statement or a declaration on its line keeps one space after it.
/* p */ package odinfmt_test

/* i */ import "core:fmt"
/* j */ foreign import lib "system:c"
/* k */ foreign lib {}
/* l */ #assert(true)

/* e */ G :: 1
/* f */ @(private) H :: 1

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
}
