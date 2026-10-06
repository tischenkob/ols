// Review of fu-10: the first-pass output of a `case` body line `x := 1; if c { a(); long_call(…) }` formats to itself.
package odinfmt_test

f :: proc() {
	switch v {
	case 1:
		x := 1
		if c {
			a()
			long_call(
				aaaaaaaaaaaaaa,
				bbbbbbbbbbbbbbbbbbbbbbbb,
				cccccccccccccccc,
			)
		}
	}
}
