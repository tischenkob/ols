// Corpus validation follow-up: a one-line `if` or `when` with `;` statements in both blocks breaks both blocks when the line does not fit.
package odinfmt_test

f :: proc() {
	if x {
		a()
		b()
	} else {
		c()
		long_call(aaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbb, cccccccccccccccc)
	}
	if x {
		c()
		long_call(aaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbb, cccccccccccccccc)
	} else {
		a()
		b()
	}
	when X {
		a()
		b()
	} else {
		c()
		long_call(aaaaaaaaaaaaaa, bbbbbbbbbbbbbbbbbbbbbbbb, cccccccccc)
	}
	if x {a(); b()} else {c(); d()}
}
