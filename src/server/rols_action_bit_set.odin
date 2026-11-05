#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:slice"

// `.A in flags` and `flags & {.A} != {}`, `.A not_in flags` and `flags & {.A} == {}`, for one member.
@(private = "package")
add_bit_set_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_bit_set {
		return
	}
	nodes := nodes_at(ctx.document.ast.decls[:], ctx.range.start)
	#reverse for at in nodes {
		if _, is_proc := at.node.derived.(^ast.Proc_Lit); is_proc {
			return
		}
		bin := at.node.derived.(^ast.Binary_Expr) or_continue
		if ctx.range.end > bin.end.offset {
			continue
		}
		#partial switch bin.op.kind {
		case .In, .Not_In:
			if add_to_intersection(ctx, at.parent, bin) {
				return
			}
		case .Cmp_Eq, .Not_Eq:
			if add_to_membership(ctx, nodes, bin) {
				return
			}
		}
	}
}

add_to_intersection :: proc(ctx: ^ActionContext, parent: ^ast.Node, bin: ^ast.Binary_Expr) -> bool {
	if !is_member(ctx, bin.left) || !is_bit_set(ctx, bin.right) {
		return false
	}
	src := ctx.document.ast.src
	text := fmt.tprintf(
		"%s & {{%s}} %s {{}}",
		node_text(src, bin.right),
		node_text(src, bin.left),
		bin.op.kind == .In ? "!=" : "==",
	)
	// `in` binds tighter than a comparison, and `!=` does not.
	if outer, is_binary := parent.derived.(^ast.Binary_Expr);
	   is_binary && outer.op.kind != .Cmp_And && outer.op.kind != .Cmp_Or {
		text = fmt.tprintf("(%s)", text)
	}
	title := bin.op.kind == .In ? "Convert to set intersection" : "Convert to empty intersection"
	append_replace_range(ctx, bin.pos.offset, bin.end.offset, title, text)
	return true
}

add_to_membership :: proc(ctx: ^ActionContext, nodes: []Node_At, bin: ^ast.Binary_Expr) -> bool {
	inter, is_binary := bin.left.derived.(^ast.Binary_Expr)
	if !is_binary || inter.op.kind != .And {
		return false
	}
	empty, empty_ok := bin.right.derived.(^ast.Comp_Lit)
	set, set_ok := inter.right.derived.(^ast.Comp_Lit)
	if !empty_ok || !set_ok || len(empty.elems) != 0 || len(set.elems) != 1 {
		return false
	}
	if !is_member(ctx, set.elems[0]) || !is_bit_set(ctx, inter.left) || in_loop_header(nodes, bin) {
		return false
	}
	src := ctx.document.ast.src
	op := bin.op.kind == .Not_Eq ? "in" : "not_in"
	text := fmt.tprintf("%s %s %s", node_text(src, set.elems[0]), op, node_text(src, inter.left))
	title := bin.op.kind == .Not_Eq ? "Convert to in" : "Convert to not_in"
	append_replace_range(ctx, bin.pos.offset, bin.end.offset, title, text)
	return true
}

// `in` in the header of a `for` reads as a range, and in a `switch` as a type switch.
in_loop_header :: proc(nodes: []Node_At, bin: ^ast.Binary_Expr) -> bool {
	for at in nodes {
		body: ^ast.Stmt
		#partial switch s in at.node.derived {
		case ^ast.For_Stmt:
			body = s.body
		case ^ast.Range_Stmt:
			body = s.body
		case ^ast.Switch_Stmt:
			body = s.body
		case:
			continue
		}
		if body != nil && bin.pos.offset < body.pos.offset {
			return true
		}
	}
	return false
}

// A bit set literal takes a constant, so a member is `.A` or `Enum.A`, not a value that holds one.
is_member :: proc(ctx: ^ActionContext, expr: ^ast.Expr) -> bool {
	#partial switch n in expr.derived {
	case ^ast.Implicit_Selector_Expr:
		return true
	case ^ast.Selector_Expr:
		if n.op.kind != .Period || n.field == nil {
			return false
		}
		reset_ast_context(ctx.ast_context)
		symbol, ok := resolve_type_expression(ctx.ast_context, n.expr)
		if !ok || symbol.flags & {.Mutable, .Parameter, .Local} != {} {
			return false
		}
		value, is_enum := symbol.value.(SymbolEnumValue)
		return is_enum && slice.contains(value.names, n.field.name)
	}
	return false
}

is_bit_set :: proc(ctx: ^ActionContext, expr: ^ast.Expr) -> bool {
	reset_ast_context(ctx.ast_context)
	symbol, ok := resolve_type_expression(ctx.ast_context, expr)
	if !ok || symbol.pointers > 0 {
		return false
	}
	_, is_set := symbol.value.(SymbolBitSetValue)
	return is_set
}
