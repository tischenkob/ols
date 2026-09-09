#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:strconv"
import "core:strings"

@(private = "package")
add_literal_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_literal {
		return
	}
	#reverse for at in nodes_at(ctx.document.ast.decls[:], ctx.range.start) {
		lit, is_lit := at.node.derived.(^ast.Basic_Lit)
		if !is_lit {
			continue
		}
		#partial switch lit.tok.kind {
		case .String:
			add_string_actions(ctx, lit)
		case .Integer:
			add_integer_actions(ctx, lit)
		}
		return
	}
}

replace_lit :: proc(ctx: ^ActionContext, lit: ^ast.Basic_Lit, title, text: string) {
	append_replace_range(ctx, lit.pos.offset, lit.end.offset, title, text)
}

add_string_actions :: proc(ctx: ^ActionContext, lit: ^ast.Basic_Lit) {
	text := lit.tok.text
	if len(text) < 2 {
		return
	}
	body := text[1:len(text) - 1]

	if text[0] == '`' {
		// A raw string may span lines; an interpreted one may not.
		if strings.contains_any(body, "\n\r") {
			return
		}
		escaped, _ := strings.replace_all(body, `\`, `\\`, context.temp_allocator)
		escaped, _ = strings.replace_all(escaped, `"`, `\"`, context.temp_allocator)
		replace_lit(ctx, lit, "Convert to interpreted string", fmt.tprintf(`"%s"`, escaped))
		return
	}

	if strings.contains(body, "`") {
		return
	}
	sb := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(body); i += 1 {
		if body[i] != '\\' {
			strings.write_byte(&sb, body[i])
			continue
		}
		if i + 1 >= len(body) || (body[i + 1] != '"' && body[i + 1] != '\\') {
			return
		}
		i += 1
		strings.write_byte(&sb, body[i])
	}
	replace_lit(ctx, lit, "Convert to raw string", fmt.tprintf("`%s`", strings.to_string(sb)))
}

add_integer_actions :: proc(ctx: ^ActionContext, lit: ^ast.Basic_Lit) {
	text := lit.tok.text
	grouped := strings.contains(text, "_")
	digits, _ := strings.replace_all(text, "_", "", context.temp_allocator)

	base := 10
	prefixed := false
	if len(digits) > 2 && digits[0] == '0' {
		switch digits[1] {
		case 'x', 'X':
			base, prefixed = 16, true
		case 'b', 'B':
			base, prefixed = 2, true
		case 'o', 'O':
			base, prefixed = 8, true
		case 'd', 'D':
			base, prefixed = 10, true
		}
	}
	if prefixed {
		digits = digits[2:]
	}
	value, ok := strconv.parse_u64_of_base(digits, base)
	if !ok {
		return
	}

	if base != 16 {
		replace_lit(ctx, lit, "Convert to hexadecimal", render(fmt.tprintf("0x%x", value), 4, grouped))
	}
	if base != 10 || prefixed {
		replace_lit(ctx, lit, "Convert to decimal", render(fmt.tprintf("%d", value), 3, grouped))
	}
	if base != 2 {
		replace_lit(ctx, lit, "Convert to binary", render(fmt.tprintf("0b%b", value), 4, grouped))
	}

	if base == 10 && !prefixed && len(digits) >= 5 {
		if grouped {
			replace_lit(ctx, lit, "Remove digit separators", digits)
		} else {
			replace_lit(ctx, lit, "Add digit separators", render(digits, 3, true))
		}
	}
}

// Puts a `_` every `size` digits, counting from the right and leaving any `0x`-style prefix alone.
render :: proc(literal: string, size: int, grouped: bool) -> string {
	prefix, digits := "", literal
	if len(literal) > 2 && literal[0] == '0' && !('0' <= literal[1] && literal[1] <= '9') {
		prefix, digits = literal[:2], literal[2:]
	}
	if !grouped || len(digits) <= size {
		return literal
	}
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, prefix)
	head := len(digits) % size
	if head == 0 {
		head = size
	}
	strings.write_string(&sb, digits[:head])
	for i := head; i < len(digits); i += size {
		strings.write_byte(&sb, '_')
		strings.write_string(&sb, digits[i:i + size])
	}
	return strings.to_string(sb)
}
