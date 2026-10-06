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

p1 :: proc(/* a */ #any_int n: int) {}
p2 :: proc(/* a */ using s: ^S) {}
p3 :: proc(/* a */ #no_alias q: ^int) {}
p4 :: proc "c" (/* a */ #c_vararg args: ..any) {}
p5 :: proc(/* a */ #by_ptr s: S) {}

f :: proc() {
	long_call(/* a */ aaaaaaaaaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbbbb, cccccccccccccccccccccccccc)
	v := /* a */ x
	arr := [?]int{/* a */ 1, 2}
}
