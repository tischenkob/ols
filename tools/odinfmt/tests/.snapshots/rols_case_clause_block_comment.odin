// Corpus: core odin/parser/parser.odin:3321 on the S17 rerun, see docs/corpus-validation.md.
// Fails until a block comment after a case clause list stays on the clause line and the output is stable.
package odinfmt_test

main :: proc() {
	switch x {
	case .Colon, .Comma /*matrix index*/:
		a()
	}
}
