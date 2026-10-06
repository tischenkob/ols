// Corpus validation follow-up, see docs/corpus-validation.md.
// Fails until a one-line `if` or `for` block with `;` statements opens a normal block when it does not fit.
package odinfmt_test

f :: proc() {
	if ODIN_DEBUG {
		_, ok := g()
		assert(
			ok,
			"a long message a long message a long message a long message a long message a long",
		)
	}
	if y := h(); y > 0 {
		_, ok := g()
		assert(
			ok,
			"a long message a long message a long message a long message",
		)
	}
	for i in 0 ..< 3 {
		_, ok := g()
		assert(
			ok,
			"a long message a long message a long message a long message a long message",
		)
	}
	for i := 0; i < 10; i += 1 {
		_, ok := g()
		assert(
			ok,
			"a long message a long message a long message a long message",
		)
	}
	if x {a(); b()} else {c(); d()}
	for i in 0 ..< 3 {a(); b()}
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
