package server

import "core:odin/ast"
import "core:strings"

import "src:common"

// A triple-quoted string drops the newline after its opening delimiter and the one before its closing line, and
// strips the closing line's indentation from every line. The fix indents the content to the line the literal starts
// on, so a raw string's leading or trailing newline survives as a blank first or last line and the value is unchanged.
// The compiler empties a line of only spaces and tabs, so a raw string with one, such as a closing backtick indented
// to the code, has no triple-quoted spelling.
lint_triple_quote :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_triple_quote do return

	lit, is_lit := node.derived.(^ast.Basic_Lit)
	if !is_lit || lit.tok.kind != .String do return
	text := lit.tok.text
	if len(text) < 2 || text[0] != '`' || strings.has_prefix(text, "```") do return
	content := text[1:len(text) - 1]
	if !strings.contains_rune(content, '\n') || strings.contains_rune(content, '\r') do return
	lines := strings.split(content, "\n", context.temp_allocator)
	for line in lines do if line != "" && strings.trim(line, " \t") == "" do return

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(lit, ctx.src),
			severity = .Hint,
			code = "triple-quote",
			message = "multiline raw string can use triple quotes",
		},
	)

	indent := get_line_indentation(ctx.src, lit.pos.offset)
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "```\n")
	for line in lines {
		if line != "" do strings.write_string(&sb, indent)
		strings.write_string(&sb, line)
		strings.write_byte(&sb, '\n')
	}
	strings.write_string(&sb, indent)
	strings.write_string(&sb, "```")
	append(
		&ctx.fixes,
		Lint_Fix {
			lit.pos.offset,
			lit.end.offset,
			"Use a triple-quoted raw string",
			strings.to_string(sb),
			"triple-quote",
		},
	)
}
