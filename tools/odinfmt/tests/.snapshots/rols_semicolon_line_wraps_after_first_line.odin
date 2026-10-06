// Corpus validation follow-up: a `;` joined statement after the first line of a block wraps, and a middle one is measured in full.
package odinfmt_test

long_call :: proc(a, b, c, d: int) -> int {return a}

f :: proc(r: int) {
	switch r {
	case 1:
		x := 1
		a := 1
		long_call(
			aaaaaaaaaaaaaaaa,
			bbbbbbbbbbbbbbbbbb,
			cccccccccccccccccc,
			dddddddddddddddddd,
		)
		_ = x
	case 2:
		a := 1
		long_call(
			aaaaaaaaaaaaaaaa,
			bbbbbbbbbbbbbbbbbb,
			cccccccccccccccccc,
			dddddddddddddddddd,
		)
		b := 2
	}
}

g :: proc() {
	x := 1
	a := 1
	long_call(
		aaaaaaaaaaaaaaaa,
		bbbbbbbbbbbbbbbbbb,
		cccccccccccccccccc,
		dddddddddddddddddd,
	)
	a := 1
	long_call(
		aaaaaaaaaaaaaaaa,
		bbbbbbbbbbbbbbbbbb,
		cccccccccccccccccc,
		dddddddddddddddddd,
	)
	b := 2
}
