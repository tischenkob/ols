// Corpus validation follow-up: a block comment before a statement or a declaration on its line keeps one space after it.
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
