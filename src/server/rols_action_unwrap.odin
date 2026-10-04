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

// Replaces stmt with the contents of body, one indentation level up. An empty body deletes
// the statement's lines.
unwrap_body :: proc(ctx: ^ActionContext, stmt: ^ast.Node, body: ^ast.Stmt) {
	block, is_block := body.derived.(^ast.Block_Stmt)
	if !is_block || block.uses_do || loop_variable_used(stmt, block) {
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

// A loop header declares names that the body may use, and unwrapping deletes the header.
loop_variable_used :: proc(stmt: ^ast.Node, body: ^ast.Block_Stmt) -> bool {
	names := make([dynamic]string, context.temp_allocator)
	#partial switch n in stmt.derived {
	case ^ast.Range_Stmt:
		for val in n.vals {
			val := val
			// `for &v in xs` stores &v.
			if unary, is_unary := val.derived.(^ast.Unary_Expr); is_unary {
				val = unary.expr
			}
			if ident, ok := val.derived.(^ast.Ident); ok {
				append(&names, ident.name)
			}
		}
		append_decl_names(&names, n.init)
	case ^ast.For_Stmt:
		append_decl_names(&names, n.init)
	}
	return len(names) > 0 && mentions_any(body, ..names[:])
}

// A return, break, continue, fallthrough or goto in the body would leave the statements after
// the unwrapped statement, or after it in the body, unreachable. Without a known enclosing list the
// edit is refused.
unwrap_leaves_dead_code :: proc(ctx: ^ActionContext, stmt: ^ast.Node, block: ^ast.Block_Stmt) -> bool {
	outer := enclosing_stmts(ctx, stmt)
	if outer == nil {
		return true
	}
	followed := outer[len(outer) - 1].pos.offset != stmt.pos.offset
	for inner, i in block.stmts {
		terminates := false
		#partial switch _ in inner.derived {
		case ^ast.Return_Stmt, ^ast.Branch_Stmt:
			terminates = true
		}
		if terminates && (followed || i < len(block.stmts) - 1) {
			return true
		}
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
