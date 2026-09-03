#+private file

package server

import "core:odin/ast"
import "core:strings"

UNWRAP_TITLE :: "Unwrap block"

@(private = "package")
add_unwrap_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_unwrap {
		return
	}

	// An if whose head holds the cursor is the innermost candidate, so nothing enclosing it
	// is offered even when the if itself is refused.
	if if_stmt := find_if_stmt_at_position(ctx.document.ast.decls[:], ctx.range.start); if_stmt != nil {
		if if_stmt.label != nil || if_stmt.body == nil {
			return
		}
		if if_stmt.else_stmt != nil {
			add_remove_else(ctx, if_stmt)
		} else if if_stmt.init == nil {
			unwrap_body(ctx, if_stmt, if_stmt.body)
		}
		return
	}

	function := ctx.position_context.function
	if function == nil || function.body == nil {
		return
	}
	#reverse for at in nodes_at({function.body}, ctx.range.start) {
		#partial switch n in at.node.derived {
		case ^ast.Block_Stmt:
			if at.parent == nil {
				continue
			}
			#partial switch _ in at.parent.derived {
			case ^ast.Block_Stmt, ^ast.Case_Clause:
				unwrap_body(ctx, n, n)
				return
			}
		case ^ast.For_Stmt:
			if n.label == nil && n.body != nil && ctx.range.start < n.body.pos.offset && !has_dangling_branch(n.body) {
				unwrap_body(ctx, n, n.body)
			}
			return
		case ^ast.Range_Stmt:
			if n.label == nil && n.body != nil && ctx.range.start < n.body.pos.offset && !has_dangling_branch(n.body) {
				unwrap_body(ctx, n, n.body)
			}
			return
		}
	}
}

add_remove_else :: proc(ctx: ^ActionContext, if_stmt: ^ast.If_Stmt) {
	else_block, else_is_block := if_stmt.else_stmt.derived.(^ast.Block_Stmt)
	body, body_is_block := if_stmt.body.derived.(^ast.Block_Stmt)
	if !else_is_block || !body_is_block || body.uses_do || else_block.uses_do || len(body.stmts) == 0 {
		return
	}
	#partial switch last in body.stmts[len(body.stmts) - 1].derived {
	case ^ast.Return_Stmt:
	case ^ast.Branch_Stmt:
		if last.tok.kind != .Break && last.tok.kind != .Continue {
			return
		}
	case:
		return
	}

	src := ctx.document.ast.src
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, src[if_stmt.pos.offset:body.close.offset + 1])
	if inner := block_inner_text(src, else_block); len(inner) > 0 {
		ind := get_line_indentation(src, if_stmt.pos.offset)
		strings.write_byte(&sb, '\n')
		strings.write_string(&sb, reindent(inner, strings.concatenate({ind, "\t"}, context.temp_allocator), ind))
	}
	append_replace_range(ctx, if_stmt.pos.offset, if_stmt.end.offset, "Remove redundant else", strings.to_string(sb))
}

// Replaces stmt with the contents of body, one indentation level up. An empty body deletes
// the statement's lines.
unwrap_body :: proc(ctx: ^ActionContext, stmt: ^ast.Node, body: ^ast.Stmt) {
	block, is_block := body.derived.(^ast.Block_Stmt)
	if !is_block || block.uses_do {
		return
	}
	src := ctx.document.ast.src
	inner := block_inner_text(src, block)
	if len(inner) == 0 {
		edits := make([]TextEdit, 1, context.temp_allocator)
		edits[0] = delete_lines_edit(ctx, stmt.pos.line - 1, stmt.end.line - 1)
		append(ctx.actions, make_code_action(ctx, UNWRAP_TITLE, "refactor.rewrite", edits))
		return
	}
	ind := get_line_indentation(src, stmt.pos.offset)
	text := reindent(inner, strings.concatenate({ind, "\t"}, context.temp_allocator), ind)
	// The replacement starts after the statement's own indentation.
	append_replace_range(ctx, stmt.pos.offset, stmt.end.offset, UNWRAP_TITLE, strings.trim_prefix(text, ind))
}

// An unlabeled break or continue that targets the loop being unwrapped.
has_dangling_branch :: proc(body: ^ast.Stmt) -> bool {
	Data :: struct {
		dangling: bool,
		depth:    int, // loops and switches opened inside the body
		stack:    [dynamic]bool, // whether each open node counts toward depth
	}

	data := Data {
		stack = make([dynamic]bool, context.temp_allocator),
	}

	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil {
				if pop(&data.stack) {
					data.depth -= 1
				}
				return nil
			}
			if data.dangling {
				return nil
			}

			opens := false
			#partial switch n in node.derived {
			case ^ast.Proc_Lit:
				return nil
			case ^ast.Branch_Stmt:
				if n.label == nil && data.depth == 0 && (n.tok.kind == .Break || n.tok.kind == .Continue) {
					data.dangling = true
					return nil
				}
			case ^ast.For_Stmt, ^ast.Range_Stmt, ^ast.Unroll_Range_Stmt, ^ast.Switch_Stmt, ^ast.Type_Switch_Stmt:
				opens = true
				data.depth += 1
			}
			append(&data.stack, opens)
			return visitor
		},
	}

	ast.walk(&visitor, body)
	return data.dangling
}
