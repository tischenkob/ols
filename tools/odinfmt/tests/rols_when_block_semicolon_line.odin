// Corpus: tina src/io_backend_windows.odin:622 on the S17 rerun, see docs/corpus-validation.md.
// Fails until a one-line `when` block with `;` statements opens a normal block and wraps its over-width call.
package odinfmt_test

f :: proc() {
	when ODIN_DEBUG { _, ok := g(); assert(ok, "a long message a long message a long message a long message a long message a long message") }
}
