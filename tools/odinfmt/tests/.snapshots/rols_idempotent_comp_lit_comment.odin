// Corpus: Skald zone_test.odin, see docs/corpus-validation.md.
package odinfmt_test

Input :: struct {
	pos: [2]int,
}

f :: proc() {
	input: Input
	input = Input {
		pos = {9, 9},
	} // far away
	_ = input
}
