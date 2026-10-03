package server

import "core:odin/ast"

// The parameter that the call argument at index binds to: by name for `name = value`, else by position.
get_call_arg_field :: proc(value: SymbolProcedureValue, call: ast.Call_Expr, index: int) -> (^ast.Field, bool) {
	if index < 0 || index >= len(call.args) {
		return nil, false
	}
	if field_value, is_named := call.args[index].derived.(^ast.Field_Value); is_named {
		ident, is_ident := field_value.field.derived.(^ast.Ident)
		if !is_ident {
			return nil, false
		}
		return get_proc_arg_type_from_name(value, ident.name)
	}
	return get_proc_arg_type_from_index(value, index)
}

// True when the innermost comp literal at the cursor starts inside the call's parentheses, so an implicit
// selector there belongs to the literal and not to a parameter of the call. `comp_lit` is the innermost one,
// `parent_comp_lit` the outermost.
comp_lit_inside_call :: proc(position_context: ^DocumentPositionContext) -> bool {
	call := position_context.call
	comp_lit := position_context.comp_lit
	return call != nil && comp_lit != nil && comp_lit.pos.offset > call.pos.offset
}

// Whether local is a name that `get_locals_using` stored for a `using`: its rhs is `lhs.name`.
is_using_local :: proc(local: DocumentLocal) -> bool {
	selector, is_selector := local.rhs.derived.(^ast.Selector_Expr)
	return is_selector && selector.expr == local.lhs
}

// The field behind a local that `get_locals_using` stored for a name brought in by `using`.
resolve_location_using_field :: proc(ast_context: ^AstContext, local: DocumentLocal) -> (symbol: Symbol, ok: bool) {
	is_using_local(local) or_return
	symbol = resolve_location_selector(ast_context, local.rhs.derived.(^ast.Selector_Expr)) or_return
	symbol.flags -= {.Local}
	return symbol, true
}

// Whether local is a `$A: typeid` parameter, whose name stands for a type.
is_typeid_local :: proc(local: DocumentLocal) -> bool {
	#partial switch type in local.rhs.derived {
	case ^ast.Typeid_Type, ^ast.Poly_Type:
		return true
	case ^ast.Ident:
		return type.name == "typeid"
	}
	return false
}
