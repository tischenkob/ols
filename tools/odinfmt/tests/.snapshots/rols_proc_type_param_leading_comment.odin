// Corpus: core text/match/strlib.odin:763 on the S17 rerun, see docs/corpus-validation.md.
// Fails until a comment above the first parameter of a procedure type stays above it.
package odinfmt_test

Gsub_Proc :: proc(
	// first
	data: rawptr,
	// second
	word: string,
)
