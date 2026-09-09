package server

import "core:fmt"
import "core:odin/ast"
import "core:unicode/utf8"

import "src:common"

// Scans the raw token text: a backslash-u escape reads as ASCII, so only a literal rune is reported.
lint_invisible :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_invisible_characters do return

	lit, is_lit := node.derived.(^ast.Basic_Lit)
	if !is_lit || lit.tok.kind != .String do return

	for r, i in lit.tok.text {
		if !is_invisible(r) do continue
		offset := lit.tok.pos.offset + i
		append(
			diags,
			Diagnostic {
				range = {
					start = common.get_relative_token_position(offset, ctx.document.text, 0),
					end = common.get_relative_token_position(offset + utf8.rune_size(r), ctx.document.text, 0),
				},
				severity = .Warning,
				code = "invisible-character",
				message = fmt.tprintf("string contains invisible character U+%04X", i32(r)),
			},
		)
	}
}

@(private = "file")
is_invisible :: proc(r: rune) -> bool {
	switch r {
	case 0x200B ..= 0x200F, 0x2028 ..= 0x202E, 0x2060 ..= 0x2064, 0xFEFF:
		return true
	case 0x00 ..= 0x1F:
		return r != '\t' && r != '\n' && r != '\r'
	}
	return false
}
