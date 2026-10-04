// Corpus: Skald examples/55_node_graph/main.odin:94 on the S17 rerun, see docs/corpus-validation.md.
// Fails until a one-line struct keeps a single space before its trailing comment.
package odinfmt_test

EndWire :: struct { target: int } // -1 = cancel
