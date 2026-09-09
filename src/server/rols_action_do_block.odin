#+private file

package server

import "core:odin/ast"
import "core:strings"

// Converts the body of an if, for or when between `{ stmt }` and `do stmt`, and the else of an
// if or when with it. The compiler wants `else do` on the line after a `do` body.
@(private = "package")
add_do_block_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_do_block {
		return
	}

	stmt: ^ast.Node
	body, else_stmt: ^ast.Stmt
	if if_stmt := find_if_stmt_at_position(ctx.document.ast.decls[:], ctx.range.start); if_stmt != nil {
		stmt, body, else_stmt = if_stmt, if_stmt.body, if_stmt.else_stmt
	} else {
		function := ctx.position_context.function
		if function == nil || function.body == nil {
			return
		}
		#reverse for at in nodes_at({function.body}, ctx.range.start) {
			#partial switch n in at.node.derived {
			case ^ast.For_Stmt:
				stmt, body = n, n.body
			case ^ast.Range_Stmt:
				stmt, body = n, n.body
			case ^ast.When_Stmt:
				stmt, body, else_stmt = n, n.body, n.else_stmt
			case:
				continue
			}
			if body == nil || ctx.range.start >= body.pos.offset {
				return
			}
			break
		}
	}
	if stmt == nil {
		return
	}
	block, is_block := body.derived.(^ast.Block_Stmt)
	if !is_block {
		return
	}
	else_block: ^ast.Block_Stmt
	if else_stmt != nil {
		else_block, _ = else_stmt.derived.(^ast.Block_Stmt)
	}

	src := ctx.document.ast.src
	ind := get_line_indentation(src, stmt.pos.offset)
	head := strings.trim_right_space(src[stmt.pos.offset:block.open.offset])
	if block.uses_do {
		head = strings.trim_right_space(strings.trim_suffix(head, "do"))
	}

	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, head)
	if block.uses_do || (else_block != nil && else_block.uses_do) {
		unit := indent_unit(src, ind, own_line_stmt(block, else_block))
		strings.write_byte(&sb, ' ')
		write_braces(&sb, src, block, ind, unit)
		if else_stmt != nil {
			strings.write_string(&sb, " else ")
			if else_block != nil {
				write_braces(&sb, src, else_block, ind, unit)
			} else {
				strings.write_string(&sb, node_text(src, else_stmt))
			}
		}
		append_replace_range(ctx, stmt.pos.offset, stmt.end.offset, "Convert to block", strings.to_string(sb))
		return
	}

	if stmt.pos.line != block.open.line || !is_do_candidate(src, block) {
		return
	}
	if else_stmt != nil && (else_block == nil || !is_do_candidate(src, else_block)) {
		return
	}
	strings.write_string(&sb, " do ")
	strings.write_string(&sb, node_text(src, block.stmts[0]))
	if else_block != nil {
		strings.write_byte(&sb, '\n')
		strings.write_string(&sb, ind)
		strings.write_string(&sb, "else do ")
		strings.write_string(&sb, node_text(src, else_block.stmts[0]))
	}
	append_replace_range(ctx, stmt.pos.offset, stmt.end.offset, "Convert to do", strings.to_string(sb))
}

// One statement on one line, no comments, and not a construct that has a body of its own.
is_do_candidate :: proc(src: string, block: ^ast.Block_Stmt) -> bool {
	if block.uses_do || len(block.stmts) != 1 {
		return false
	}
	stmt := block.stmts[0]
	if stmt.pos.line != stmt.end.line || has_comments_around(src, block, stmt) {
		return false
	}
	#partial switch _ in stmt.derived {
	case ^ast.Block_Stmt,
	     ^ast.If_Stmt,
	     ^ast.For_Stmt,
	     ^ast.Range_Stmt,
	     ^ast.Unroll_Range_Stmt,
	     ^ast.Switch_Stmt,
	     ^ast.Type_Switch_Stmt,
	     ^ast.When_Stmt:
		return false
	}
	return true
}

write_braces :: proc(sb: ^strings.Builder, src: string, block: ^ast.Block_Stmt, ind, unit: string) {
	strings.write_byte(sb, '{')
	if lines := block_lines(src, block, ind, unit); len(lines) > 0 {
		strings.write_byte(sb, '\n')
		strings.write_string(sb, lines)
	}
	strings.write_byte(sb, '\n')
	strings.write_string(sb, ind)
	strings.write_byte(sb, '}')
}

own_line_stmt :: proc(blocks: ..^ast.Block_Stmt) -> ^ast.Node {
	for block in blocks {
		if block != nil && !block.uses_do && len(block.stmts) > 0 {
			return block.stmts[0]
		}
	}
	return nil
}
