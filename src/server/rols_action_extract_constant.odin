#+private file

package server

import "core:odin/ast"
import "core:slice"
import "core:strings"

@(private = "package")
add_extract_constant_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_extract_constant {
		return
	}
	function := ctx.position_context.function
	if function == nil || function.body == nil {
		return
	}

	src := ctx.document.ast.src
	start, end := trim_range(src, ctx.range.start, ctx.range.end)

	list, found := find_stmt_list_at(function.body, start, end)
	if !found || list.first != list.last {
		return
	}
	stmt := list.stmts[list.first]
	if stmt.pos.offset > start || end > stmt.end.offset {
		return
	}
	if decl, is_decl := stmt.derived.(^ast.Value_Decl); is_decl && !decl.is_mutable {
		return
	}

	// The selection must match one expression; the cursor takes the outermost constant around it.
	expr: ^ast.Expr
	parent: ^ast.Node
	for at in nodes_at({stmt}, start) {
		if start != end && (at.node.pos.offset != start || at.node.end.offset != end) {
			continue
		}
		if _, is_ident := at.node.derived.(^ast.Ident); is_ident {
			continue
		}
		if is_constant(ctx, at.node) {
			expr, parent = cast(^ast.Expr)at.node, at.parent
			break
		}
	}
	if expr == nil || parent == nil {
		return
	}

	name := fresh_name(ctx, const_name(ctx, expr, parent), expr.pos)

	at := decl_start(ctx, stmt.pos.offset)
	for at > 0 && src[at - 1] != '\n' {
		at -= 1
	}

	edits := make([]TextEdit, 2, context.temp_allocator)
	edits[0] = {
		range   = range_of(ctx, at, at),
		newText = strings.concatenate({name, " :: ", node_text(src, expr), "\n\n"}, context.temp_allocator),
	}
	edits[1] = {
		range   = range_of(ctx, expr.pos.offset, expr.end.offset),
		newText = name,
	}
	append(ctx.actions, make_code_action(ctx, "Extract constant", "refactor.extract", edits))
}

@(private = "package")
is_constant :: proc(ctx: ^ActionContext, node: ^ast.Node) -> bool {
	#partial switch n in node.derived {
	case ^ast.Basic_Lit:
		return true
	case ^ast.Paren_Expr:
		return is_constant(ctx, n.expr)
	case ^ast.Unary_Expr:
		#partial switch n.op.kind {
		case .Sub, .Add, .Not, .Xor:
			return n.expr != nil && is_constant(ctx, n.expr)
		}
	case ^ast.Binary_Expr:
		#partial switch n.op.kind {
		case .Range_Half, .Range_Full, .Ellipsis, .In, .Not_In:
			return false
		}
		return is_constant(ctx, n.left) && is_constant(ctx, n.right)
	case ^ast.Comp_Lit:
		if n.type == nil || !is_constant(ctx, n.type) {
			return false
		}
		for elem in n.elems {
			value := elem
			if field, is_field := elem.derived.(^ast.Field_Value); is_field {
				value = field.value
			}
			if !is_constant(ctx, value) {
				return false
			}
		}
		return true
	case ^ast.Ident:
		// Resolving a global turns locals off and leaves them off.
		ctx.ast_context.use_locals = true
		symbol, ok := resolve_type_identifier(ctx.ast_context, n^)
		return ok && symbol.flags & {.Local, .Mutable, .Parameter} == {}
	}
	return false
}

// The parameter, variable or compared name the expression feeds, upper-cased.
@(private = "package")
const_name :: proc(ctx: ^ActionContext, expr: ^ast.Expr, parent: ^ast.Node) -> string {
	base := ""
	#partial switch p in parent.derived {
	case ^ast.Call_Expr:
		base = param_name(ctx, p, slice.linear_search(p.args, expr) or_else -1)
	case ^ast.Field_Value:
		base = final_name(p.field)
	case ^ast.Value_Decl:
		if len(p.names) == 1 && slice.contains(p.values, expr) {
			base = final_name(p.names[0])
		}
	case ^ast.Assign_Stmt:
		if len(p.lhs) == 1 && slice.contains(p.rhs, expr) {
			base = final_name(p.lhs[0])
		}
	case ^ast.Binary_Expr:
		#partial switch p.op.kind {
		case .Cmp_Eq, .Not_Eq, .Lt, .Gt, .Lt_Eq, .Gt_Eq:
			other := final_name(p.left == expr ? p.right : p.left)
			if other != "" {
				base = strings.concatenate({other, "_VALUE"}, context.temp_allocator)
			}
		}
	}
	if base == "" || base == "_" {
		return "CONSTANT"
	}
	return strings.to_upper(base, context.temp_allocator)
}

param_name :: proc(ctx: ^ActionContext, call: ^ast.Call_Expr, index: int) -> string {
	resolved, ok := resolve_entire_file(ctx.document)[uintptr(call.expr)]
	if !ok || index < 0 {
		return ""
	}
	callee := resolved.symbol.value.(SymbolProcedureValue) or_else {}
	i := index
	for field in callee.arg_types {
		if i < len(field.names) {
			return final_name(field.names[i])
		}
		i -= len(field.names)
	}
	return ""
}

// Start of the top-level declaration containing offset, including its doc comment and attributes.
decl_start :: proc(ctx: ^ActionContext, offset: int) -> int {
	for decl in ctx.document.ast.decls {
		if offset < decl.pos.offset || decl.end.offset < offset {
			continue
		}
		at := decl.pos.offset
		if value_decl, ok := decl.derived.(^ast.Value_Decl); ok {
			if value_decl.docs != nil {
				at = min(at, value_decl.docs.pos.offset)
			}
			for attribute in value_decl.attributes {
				at = min(at, attribute.pos.offset)
			}
		}
		return at
	}
	return offset
}
