// Corpus validation follow-up: a block comment before the first item on its line stays before the item, with one space after it.
package odinfmt_test

S :: struct {
	/* a */ x: int,
	longer: int,
}

E :: enum {
	/* a */ A,
	B,
}

f :: proc() {
	long_call(/* a */ aaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbbbb, cccccccccccccccccccccccccc)
	v := /* a */ x
	arr := [?]int{/* a */ 1, 2}
}
