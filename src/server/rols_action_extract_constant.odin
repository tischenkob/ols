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
	src := ctx.document.ast.src
	start, end := trim_selection(src, ctx.range.start, ctx.range.end)

	stmt: ^ast.Stmt
	if function := ctx.position_context.function; function != nil {
		if function.body == nil {
			return
		}
		list, found := find_stmt_list_at(function.body, start, end)
		if !found || list.first != list.last {
			return
		}
		stmt = list.stmts[list.first]
		if stmt.pos.offset > start || end > stmt.end.offset {
			return
		}
	} else {
		stmt = package_initializer_at(ctx, start, end)
		if stmt == nil {
			return
		}
	}
	if decl, is_decl := stmt.derived.(^ast.Value_Decl); is_decl && !decl.is_mutable {
		return
	}

	at := decl_start(ctx, stmt.pos.offset)
	for at > 0 && src[at - 1] != '\n' {
		at -= 1
	}

	for candidate in constants_at(ctx, stmt, start, end) {
		if _, is_ident := candidate.node.derived.(^ast.Ident); is_ident {
			continue
		}
		expr := cast(^ast.Expr)candidate.node
		name := fresh_name(ctx, const_name(ctx, expr, candidate.parent), expr.pos)

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
}

// The package-level `:=` declaration whose initializer holds [start, end]. It serves as the statement.
package_initializer_at :: proc(ctx: ^ActionContext, start, end: int) -> ^ast.Stmt {
	for root in ctx.document.ast.decls {
		decl, is_decl := root.derived.(^ast.Value_Decl)
		if !is_decl || !decl.is_mutable {
			continue
		}
		for value in decl.values {
			if value.pos.offset <= start && end <= value.end.offset {
				return decl
			}
		}
	}
	return nil
}

// The selected constant expression, the smallest one around an inexact selection, or the constant
// expressions around the cursor, innermost first. A cursor or an inexact selection skips names and
// parentheses, which repeat the expression inside them.
@(private = "package")
constants_at :: proc(ctx: ^ActionContext, stmt: ^ast.Stmt, start, end: int) -> []Node_At {
	found := make([dynamic]Node_At, context.temp_allocator)
	exact := selects_exact_node(stmt, start, end)
	#reverse for at in nodes_at({stmt}, start) {
		if len(found) == MAX_EXTRACT_WIDTHS {
			break
		}
		if at.parent == nil {
			continue
		}
		if at.node.end.offset < end || (exact && (at.node.pos.offset != start || at.node.end.offset != end)) {
			continue
		}
		#partial switch _ in at.node.derived {
		case ^ast.Ident, ^ast.Paren_Expr:
			if !exact {
				continue
			}
		}
		if is_constant(ctx, at.node) {
			append(&found, at)
			if start != end && !exact {
				break
			}
		}
	}
	return found[:]
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
	case ^ast.Selector_Expr:
		return is_constant_selector(ctx, n)
	case ^ast.Call_Expr:
		if callee, is_name := n.expr.derived.(^ast.Ident); is_name {
			switch callee.name {
			case "size_of", "align_of", "offset_of":
				return is_builtin_proc(ctx, callee) && len(n.args) > 0 && nameable_at_package(ctx, n.args[0])
			}
		}
		return len(n.args) == 1 && is_constant_type(ctx, n.expr) && is_constant(ctx, n.args[0])
	case ^ast.Type_Cast:
		return n.tok.kind == .Cast && is_constant_type(ctx, n.type) && is_constant(ctx, n.expr)
	}
	return false
}

// A package constant or an enum member, reached by names that package scope can write.
is_constant_selector :: proc(ctx: ^ActionContext, selector: ^ast.Selector_Expr) -> bool {
	if !nameable_at_package(ctx, selector.expr) {
		return false
	}
	ctx.ast_context.use_locals = true
	base, base_ok := resolve_type_expression(ctx.ast_context, selector.expr)
	if !base_ok {
		return false
	}
	#partial switch v in base.value {
	case SymbolEnumValue:
		return slice.contains(v.names, selector.field.name)
	case SymbolPackageValue:
		ctx.ast_context.use_locals = true
		symbol, ok := resolve_type_expression(ctx.ast_context, selector)
		return ok && symbol.type == .Constant && .Mutable not_in symbol.flags
	}
	return false
}

// A type that a constant converts to at compile time.
is_constant_type :: proc(ctx: ^ActionContext, type: ^ast.Expr) -> bool {
	#partial switch _ in type.derived {
	case ^ast.Ident, ^ast.Selector_Expr:
	case:
		return false
	}
	if !nameable_at_package(ctx, type) {
		return false
	}
	ctx.ast_context.use_locals = true
	symbol, ok := resolve_type_expression(ctx.ast_context, type)
	if !ok || .Mutable in symbol.flags || symbol.type == .Variable || symbol.type == .Constant {
		return false
	}
	#partial switch v in symbol.value {
	case SymbolBasicValue:
		switch v.ident.name {
		case "any", "rawptr", "typeid":
			return false
		}
		return true
	case SymbolEnumValue:
		return true
	}
	return false
}

// The compiler's own procedure, not something this package or a local declares under its name.
is_builtin_proc :: proc(ctx: ^ActionContext, callee: ^ast.Ident) -> bool {
	ctx.ast_context.use_locals = true
	symbol, ok := resolve_type_identifier(ctx.ast_context, callee^)
	return !ok || (symbol.pkg != ctx.ast_context.document_package && .Local not_in symbol.flags)
}

// The constant goes to package scope, so every name inside must mean the same thing there. A local, a parameter, a
// poly parameter or an implicit selector does not.
nameable_at_package :: proc(ctx: ^ActionContext, root: ^ast.Node) -> bool {
	Data :: struct {
		ctx: ^ActionContext,
		ok:  bool,
	}
	data := Data{ctx, true}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil || !data.ok {
				return nil
			}
			#partial switch n in node.derived {
			case ^ast.Ident:
				data.ctx.ast_context.use_locals = true
				symbol, ok := resolve_type_identifier(data.ctx.ast_context, n^)
				data.ok = ok && symbol.flags & {.Local, .Parameter} == {}
				return nil
			case ^ast.Selector_Expr:
				// The field name is no name in scope.
				ast.walk(visitor, n.expr)
				return nil
			case ^ast.Implicit_Selector_Expr, ^ast.Field_Value, ^ast.Poly_Type:
				data.ok = false
				return nil
			}
			return visitor
		},
	}
	ast.walk(&visitor, root)
	return data.ok
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
