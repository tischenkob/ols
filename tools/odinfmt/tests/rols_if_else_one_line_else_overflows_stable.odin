// The formatted output of rols_if_else_one_line_else_overflows formats to itself.
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
