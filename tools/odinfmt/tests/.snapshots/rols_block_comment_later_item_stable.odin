// The formatted output of rols_block_comment_later_item formats to itself.
package odinfmt_test

S :: struct {
	x: int,
	/* b */ y: int,
}

E :: enum {
	A,
	/* b */ B,
}

U :: union {
	int,
	/* b */ f32,
}

f :: proc(
	x: int,
	/* b */ y: int,
) {}

g :: proc() {
	long_call(
		aaaaaaaaaaaaaaaaaaaaaaa,
		/* b */ bbbbbbbbbbbbbbbbbbbbbbbbbb,
		cccccccccccccccccccccccccc,
	)
	arr := [?]int {
		1,
		/* b */ 2,
	}
	a := b + /* c */ c
	d := e + /* f */ f
}
