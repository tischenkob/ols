// Corpus: core sys/posix/arpa_inet.odin:47 on the S17 rerun, see docs/corpus-validation.md.
// Fails until trailing comments on foreign procedure parameters stay on their own parameter lines.
package odinfmt_test

foreign lib {
	inet_pton :: proc(
		af: AF, // INET or INET6
		dst: rawptr, // either
	) -> pton_result ---
}
