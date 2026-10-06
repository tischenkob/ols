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

// Whether the candidates that share the top score return the same types, so picking any of them gives the
// same call result. Return types that contain a poly parameter count as equal, as in `proc_symbols_compatible`.
top_candidates_agree :: proc(ast_context: ^AstContext, candidates: []Candidate, top: Candidate) -> bool {
	a := top.symbol.value.(SymbolProcedureValue) or_return
	for candidate in candidates {
		if candidate.score != top.score do continue
		b := candidate.symbol.value.(SymbolProcedureValue) or_continue
		a_returns := get_proc_return_value_count(a.return_types)
		if a_returns != get_proc_return_value_count(b.return_types) {
			return false
		}
		for i in 0 ..< a_returns {
			at := get_proc_return_type_from_index(a.return_types, i)
			bt := get_proc_return_type_from_index(b.return_types, i)
			if at == bt || expr_contains_poly(at) || expr_contains_poly(bt) {
				continue
			}
			as, aok := resolve_type_expression(ast_context, at)
			bs, bok := resolve_type_expression(ast_context, bt)
			if !aok || !bok || !is_symbol_same_typed(ast_context, as, bs) {
				return false
			}
		}
	}
	return true
}

// How `resolve_function_overload` picks among the members of a group, recorded with each cached result.
OverloadMode :: enum u8 {
	// One member, for the result of the call. A tie between members whose results differ picks none.
	Specific,
	// Every candidate, as an aggregate when several fit.
	All,
	// One member, for its parameters (`resolve_specific_overload`). A tie picks the first.
	Member,
}

overload_mode :: proc(ast_context: ^AstContext, call_expr: ^ast.Call_Expr) -> OverloadMode {
	if should_resolve_all_proc_overload_possibilities(ast_context, call_expr) {
		return .All
	}
	return ast_context.resolve_specific_overload ? .Member : .Specific
}

// Whether ident lies in the top-level declaration of the file that holds local. Locals come from the procedure
// or enum at the cursor, so a name in another top-level declaration, such as the initializer of a global that
// the procedure uses, never names one. Calls inside such an initializer turn `use_locals` back on, so
// `resolve_global_identifier` alone does not keep them out. A name from another file, or a synthesized one,
// is not checked.
in_local_top_level_decl :: proc(file: ast.File, local: DocumentLocal, ident: ast.Ident) -> bool {
	if local.lhs == nil || ident.pos.file == "" || ident.pos.file != file.fullpath {
		return true
	}
	return top_level_decl_index(file, ident.pos.offset) == top_level_decl_index(file, local.lhs.pos.offset)
}

// The index of the last top-level declaration that starts at or before offset, or -1 before the first one.
// End offsets are not used: a declaration that is still being typed can end before its body does.
@(private = "file")
top_level_decl_index :: proc(file: ast.File, offset: int) -> int {
	lo, hi := 0, len(file.decls)
	for lo < hi {
		mid := (lo + hi) / 2
		if file.decls[mid].pos.offset <= offset {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	return lo - 1
}
