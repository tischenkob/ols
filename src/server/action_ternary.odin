#+private file

package server

import "core:odin/ast"
import "core:strings"

@(private = "package")
add_ternary_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_ternary {
		return
	}
	add_to_ternary(ctx)
	add_to_if_else(ctx)
}

add_to_ternary :: proc(ctx: ^ActionContext) {
	if_stmt := find_if_stmt_at_position(ctx.document.ast.decls[:], ctx.range.start)
	if if_stmt == nil || if_stmt.init != nil || if_stmt.label != nil || if_stmt.body == nil || if_stmt.else_stmt == nil {
		return
	}
	src := ctx.document.ast.src
	then_stmt, then_ok := single_stmt(src, if_stmt.body)
	else_stmt, else_ok := single_stmt(src, if_stmt.else_stmt)
	if !then_ok || !else_ok {
		return
	}

	head: string
	a, b: ^ast.Expr
	#partial switch t in then_stmt.derived {
	case ^ast.Assign_Stmt:
		e, ok := else_stmt.derived.(^ast.Assign_Stmt)
		if !ok || !is_single_assign(t) || !is_single_assign(e) {
			return
		}
		if strip_space(node_text(src, t.lhs[0])) != strip_space(node_text(src, e.lhs[0])) {
			return
		}
		head = strings.concatenate({node_text(src, t.lhs[0]), " = "}, context.temp_allocator)
		a, b = t.rhs[0], e.rhs[0]
	case ^ast.Return_Stmt:
		e, ok := else_stmt.derived.(^ast.Return_Stmt)
		if !ok || len(t.results) != 1 || len(e.results) != 1 {
			return
		}
		head = "return "
		a, b = t.results[0], e.results[0]
	case:
		return
	}

	text := strings.concatenate(
		{head, ternary_operand(src, a), " if ", ternary_operand(src, if_stmt.cond), " else ", ternary_operand(src, b)},
		context.temp_allocator,
	)
	append_replace_range(ctx, if_stmt.pos.offset, if_stmt.end.offset, "Convert to ternary", text)
}

// The one statement of a block that holds nothing else, comments included.
single_stmt :: proc(src: string, stmt: ^ast.Stmt) -> (^ast.Stmt, bool) {
	block, ok := stmt.derived.(^ast.Block_Stmt)
	if !ok || len(block.stmts) != 1 {
		return nil, false
	}
	inner := block.stmts[0]
	if strings.trim_space(block_inner_text(src, block)) != node_text(src, inner) {
		return nil, false
	}
	return inner, true
}

is_single_assign :: proc(assign: ^ast.Assign_Stmt) -> bool {
	return assign.op.kind == .Eq && len(assign.lhs) == 1 && len(assign.rhs) == 1
}

// A ternary inside a generated ternary is parenthesised, since nesting binds right and reads badly.
ternary_operand :: proc(src: string, expr: ^ast.Expr) -> string {
	text := node_text(src, expr)
	#partial switch _ in expr.derived {
	case ^ast.Ternary_If_Expr, ^ast.Ternary_When_Expr, ^ast.Or_Else_Expr:
		return strings.concatenate({"(", text, ")"}, context.temp_allocator)
	}
	return text
}

add_to_if_else :: proc(ctx: ^ActionContext) {
	function := ctx.position_context.function
	if function == nil || function.body == nil {
		return
	}
	nodes := nodes_at({function.body}, ctx.range.start)

	ternary: ^ast.Ternary_If_Expr
	parent: ^ast.Node
	#reverse for at in nodes {
		if t, ok := at.node.derived.(^ast.Ternary_If_Expr); ok {
			ternary, parent = t, at.parent
			break
		}
	}
	if ternary == nil {
		return
	}
	if _, is_paren := parent.derived.(^ast.Paren_Expr); is_paren {
		parent = parent_of(nodes, parent)
	}
	if parent == nil {
		return
	}

	src := ctx.document.ast.src
	stmt: ^ast.Node = parent
	head, decl_text: string
	#partial switch p in parent.derived {
	case ^ast.Assign_Stmt:
		if !is_single_assign(p) || !holds(p.rhs[0], ternary) {
			return
		}
		head = strings.concatenate({node_text(src, p.lhs[0]), " = "}, context.temp_allocator)
	case ^ast.Return_Stmt:
		if len(p.results) != 1 || !holds(p.results[0], ternary) {
			return
		}
		head = "return "
	case ^ast.Value_Decl:
		if !p.is_mutable || p.type != nil || len(p.names) != 1 || len(p.values) != 1 || !holds(p.values[0], ternary) {
			return
		}
		name, is_ident := p.names[0].derived.(^ast.Ident)
		if !is_ident {
			return
		}
		// Locals are gathered up to the cursor only, so re-gather at the declaration end to
		// resolve the name.
		pc := ctx.position_context^
		pc.position = p.end.offset
		pc.nested_position = p.end.offset
		clear_locals(ctx.ast_context)
		get_locals(ctx.ast_context, &pc)
		type_text, ok := local_type_text(ctx, name)
		if !ok {
			return
		}
		decl_text = strings.concatenate({name.name, ": ", type_text}, context.temp_allocator)
		head = strings.concatenate({name.name, " = "}, context.temp_allocator)
	case:
		return
	}

	ind := get_line_indentation(src, stmt.pos.offset)
	sb := strings.builder_make(context.temp_allocator)
	if decl_text != "" {
		strings.write_string(&sb, decl_text)
		strings.write_byte(&sb, '\n')
		strings.write_string(&sb, ind)
	}
	strings.write_string(&sb, "if ")
	strings.write_string(&sb, node_text(src, unparen_once(ternary.cond)))
	strings.write_string(&sb, " {\n")
	strings.write_string(&sb, ind)
	strings.write_byte(&sb, '\t')
	strings.write_string(&sb, head)
	strings.write_string(&sb, node_text(src, unparen_once(ternary.x)))
	strings.write_byte(&sb, '\n')
	strings.write_string(&sb, ind)
	strings.write_string(&sb, "} else {\n")
	strings.write_string(&sb, ind)
	strings.write_byte(&sb, '\t')
	strings.write_string(&sb, head)
	strings.write_string(&sb, node_text(src, unparen_once(ternary.y)))
	strings.write_byte(&sb, '\n')
	strings.write_string(&sb, ind)
	strings.write_byte(&sb, '}')

	append_replace_range(ctx, stmt.pos.offset, stmt.end.offset, "Convert to if/else", strings.to_string(sb))
}

// Whether expr is the ternary, through at most one pair of parentheses.
holds :: proc(expr: ^ast.Expr, ternary: ^ast.Ternary_If_Expr) -> bool {
	expr := expr
	if paren, ok := expr.derived.(^ast.Paren_Expr); ok {
		expr = paren.expr
	}
	t, ok := expr.derived.(^ast.Ternary_If_Expr)
	return ok && t == ternary
}

parent_of :: proc(nodes: []Node_At, node: ^ast.Node) -> ^ast.Node {
	for at in nodes {
		if at.node == node {
			return at.parent
		}
	}
	return nil
}

// Strips one pair of parentheses unless they guard a nested ternary.
unparen_once :: proc(expr: ^ast.Expr) -> ^ast.Expr {
	paren, ok := expr.derived.(^ast.Paren_Expr)
	if !ok {
		return expr
	}
	#partial switch _ in paren.expr.derived {
	case ^ast.Ternary_If_Expr, ^ast.Ternary_When_Expr:
		return expr
	}
	return paren.expr
}
