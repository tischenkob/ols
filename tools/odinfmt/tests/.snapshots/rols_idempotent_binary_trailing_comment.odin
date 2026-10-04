// Corpus: core/rexcode/isa/arm32/immediates.odin:331. Trailing comments in a `|` chain moved one line down per pass.
package odinfmt_test

pack_neon_modimm_field :: #force_inline proc "contextless" (
	f: NEON_Imm_Form,
) -> u32 {
	a := u32(f.abcdefgh)
	return(
		((a >> 7) & 1) << 24 | // 'a' bit
		((a >> 4) & 0x7) << 16 | // 'bcd' bits
		(a & 0xF) | // 'efgh' bits
		u32(f.cmode) << 8 |
		u32(f.op) << 5 \
	)
}
