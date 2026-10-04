// Corpus: core/testing/runner.odin:424. Comments above the first argument and between the operands of a `+` chain moved.
package odinfmt_test

f :: proc() {
	s := fmt.aprintf(
		// first comment
		A + "%i" + B +
		// second comment
		// third comment
		"%s",
		// the next argument
		1 + len(x),
	)
}
