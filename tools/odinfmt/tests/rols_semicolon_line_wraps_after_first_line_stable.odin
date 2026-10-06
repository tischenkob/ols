// The formatted output of rols_semicolon_line_wraps_after_first_line formats to itself.
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
