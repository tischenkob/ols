package odinfmt_test

long_call :: proc(a, b, c, d: int) -> int {return a}

f :: proc(r: int) {
	aaaaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbb, cccccccccccccccccc, dddddddddddddddddd :=
		1, 2, 3, 4
	switch r {
	case 0:
		a := 1
		long_call(
			aaaaaaaaaaaaaaaa,
			bbbbbbbbbbbbbbbbbb,
			cccccccccccccccccc,
			dddddddddddddddddd,
		)
		b := 2
		_, _ = a, b
	}
}
