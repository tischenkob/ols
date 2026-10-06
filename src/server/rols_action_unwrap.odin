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
	// The lookup above skips an `else if`, whose head is then the innermost candidate.
	#reverse for at in nodes_at({function.body}, ctx.range.start) {
		inner, is_if := at.node.derived.(^ast.If_Stmt)
		if !is_if do continue
		if at.parent != nil && inner.body != nil && ctx.range.start < inner.body.pos.offset {
			if outer, is_outer := at.parent.derived.(^ast.If_Stmt); is_outer && outer.else_stmt == inner {
				unwrap_else_if(ctx, inner)
				return
			}
		}
		break
	}
	#reverse for at in nodes_at({function.body}, ctx.range.start) {
		n, is_block := at.node.derived.(^ast.Block_Stmt)
		if !is_block || at.parent == nil do continue
		#partial switch _ in at.parent.derived {
		case ^ast.Block_Stmt, ^ast.Case_Clause:
			unwrap_body(ctx, n, n)
			return
		}
	}
}

add_remove_else :: proc(ctx: ^ActionContext, if_stmt: ^ast.If_Stmt) {
	parents := make([dynamic]^ast.Node, context.temp_allocator)
	for at in nodes_at(ctx.document.ast.decls[:], if_stmt.pos.offset) {
		if at.node == if_stmt {
			break
		}
		if at.node.end.offset >= if_stmt.end.offset {
			append(&parents, at.node)
		}
	}
	// The same eligibility check and text as the simplify rule, so the two cannot drift.
	s, ok := redundant_else(ctx.document.ast.src, if_stmt, parents[:])
	if !ok {
		return
	}
	append_replace_range(ctx, s.start, s.end, s.title, s.text)
}

// Turns `else if c {X}` into `else {X}`. The body stays a block, so no declaration moves and no
// statement after it changes reachability.
unwrap_else_if :: proc(ctx: ^ActionContext, if_stmt: ^ast.If_Stmt) {
	if if_stmt.label != nil || if_stmt.init != nil || if_stmt.else_stmt != nil {
		return
	}
	block, is_block := if_stmt.body.derived.(^ast.Block_Stmt)
	if !is_block || block.uses_do {
		return
	}
	append_replace_range(ctx, if_stmt.pos.offset, block.pos.offset, UNWRAP_TITLE, "")
}

// Replaces stmt with the contents of body, one indentation level up. An empty body deletes
// the statement's lines.
unwrap_body :: proc(ctx: ^ActionContext, stmt: ^ast.Node, body: ^ast.Stmt) {
	block, is_block := body.derived.(^ast.Block_Stmt)
	if !is_block || block.uses_do {
		return
	}
	if unwrap_redeclares(ctx, stmt, block) || unwrap_leaves_dead_code(ctx, stmt, block) {
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
	first: ^ast.Node
	if len(block.stmts) > 0 {
		first = block.stmts[0]
	}
	ind := get_line_indentation(src, stmt.pos.offset)
	text := reindent(inner, strings.concatenate({ind, indent_unit(src, ind, first)}, context.temp_allocator), ind)
	// The replacement starts after the statement's own indentation.
	append_replace_range(ctx, stmt.pos.offset, stmt.end.offset, UNWRAP_TITLE, strings.trim_prefix(text, ind))
}

// Unwrapping hoists the block's own declarations into the enclosing statement list, where a
// declaration of the same name, before or after the block, would become a redeclaration.
unwrap_redeclares :: proc(ctx: ^ActionContext, stmt: ^ast.Node, block: ^ast.Block_Stmt) -> bool {
	outer := enclosing_stmts(ctx, stmt)
	for inner in block.stmts {
		decl, is_decl := inner.derived.(^ast.Value_Decl)
		if !is_decl {
			continue
		}
		for name in decl.names {
			ident, is_ident := name.derived.(^ast.Ident)
			if !is_ident || ident.name == "_" {
				continue
			}
			for sibling in outer {
				if sibling.pos.offset == stmt.pos.offset {
					continue
				}
				other, is_other := sibling.derived.(^ast.Value_Decl)
				if !is_other {
					continue
				}
				for other_name in other.names {
					if id, ok := other_name.derived.(^ast.Ident); ok && id.name == ident.name {
						return true
					}
				}
			}
		}
	}
	return false
}

// A statement that ends the flow in the body would leave the statements after the unwrapped
// statement, or after it in the body, unreachable. Without a known enclosing list the edit is refused.
unwrap_leaves_dead_code :: proc(ctx: ^ActionContext, stmt: ^ast.Node, block: ^ast.Block_Stmt) -> bool {
	outer := enclosing_stmts(ctx, stmt)
	if outer == nil {
		return true
	}
	followed := outer[len(outer) - 1].pos.offset != stmt.pos.offset
	for inner, i in block.stmts {
		if ends_flow(ctx.document, inner) && (followed || i < len(block.stmts) - 1) {
			return true
		}
	}
	return false
}

// A return, branch, panic or diverging call, or a block or `if` whose every path ends in one. A callee
// that does not resolve to a procedure counts when it is a selector named `exit`, such as `os.exit(1)`.
// Counting too much only refuses the edit.
ends_flow :: proc(document: ^Document, stmt: ^ast.Stmt) -> bool {
	if terminates(stmt) {
		return true
	}
	#partial switch s in stmt.derived {
	case ^ast.Expr_Stmt:
		call := s.expr.derived.(^ast.Call_Expr) or_return
		if resolved, found := resolve_entire_file(document)[uintptr(call.expr)]; found && !resolved.is_unresolved {
			if callee, is_proc := resolved.symbol.value.(SymbolProcedureValue); is_proc {
				return callee.diverging
			}
		}
		callee := call.expr.derived.(^ast.Selector_Expr) or_return
		return callee.field != nil && callee.field.name == "exit"
	case ^ast.Block_Stmt:
		return s.label == nil && len(s.stmts) > 0 && ends_flow(document, s.stmts[len(s.stmts) - 1])
	case ^ast.If_Stmt:
		return s.else_stmt != nil && ends_flow(document, s.body) && ends_flow(document, s.else_stmt)
	}
	return false
}

// The statement list stmt is a direct member of.
enclosing_stmts :: proc(ctx: ^ActionContext, stmt: ^ast.Node) -> []^ast.Stmt {
	for at in nodes_at(ctx.document.ast.decls[:], stmt.pos.offset) {
		stmts: []^ast.Stmt
		#partial switch n in at.node.derived {
		case ^ast.Block_Stmt:
			stmts = n.stmts
		case ^ast.Case_Clause:
			stmts = n.body
		}
		for s in stmts {
			if s.pos.offset == stmt.pos.offset {
				return stmts
			}
		}
	}
	return nil
}
