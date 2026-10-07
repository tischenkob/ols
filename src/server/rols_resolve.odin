package server

import "core:odin/ast"
import "core:slice"

// The parameter that the call argument at index binds to: by name for `name = value`, else by position. The
// positional arguments of `x->f(...)` start after the receiver parameter.
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
	if selector, is_selector := call.expr.derived.(^ast.Selector_Expr);
	   is_selector && selector.op.kind == .Arrow_Right {
		return get_proc_arg_type_from_index(value, index + 1)
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
// Each return type resolves in the package of its member.
top_candidates_agree :: proc(ast_context: ^AstContext, candidates: []Candidate) -> bool {
	top := get_top_candiate(candidates) or_return
	a := top.symbol.value.(SymbolProcedureValue) or_return
	resolve_return :: proc(ast_context: ^AstContext, member: Symbol, expr: ^ast.Expr) -> (Symbol, bool) {
		set_ast_package_from_symbol_scoped(ast_context, member)
		return resolve_type_expression(ast_context, expr)
	}
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
			as, aok := resolve_return(ast_context, top.symbol, at)
			bs, bok := resolve_return(ast_context, candidate.symbol, bt)
			if !aok || !bok || !is_symbol_same_typed(ast_context, as, bs) {
				return false
			}
		}
	}
	return true
}

// The parameters a call must pass: those without a default value that are not variadic.
proc_required_arg_count :: proc(procedure: SymbolProcedureValue) -> int {
	required := 0
	for field in procedure.arg_types {
		if _, is_variadic := proc_field_type_for_call(field); !is_variadic && field.default_value == nil {
			required += max(1, len(field.names))
		}
	}
	return required
}

// The values a call of procedure passes as arguments: one per result name, and one for an #optional_ok procedure.
proc_result_value_count :: proc(procedure: SymbolProcedureValue) -> int {
	if procedure.tags & {.Optional_Ok, .Optional_Allocator_Error} != {} {
		return min(1, len(procedure.return_types))
	}
	count := 0
	for field in procedure.return_types {
		count += max(1, len(field.names))
	}
	return count
}

// Whether `expand_call_args` knows how many values each argument passes. A bad expression leaves the count unknown.
call_arg_counts_known :: proc(call_args: []CallArg) -> bool {
	for arg in call_args {
		if arg.bad_expr {
			return false
		}
	}
	return true
}

// How `resolve_function_overload` picks among the members of a group, recorded with each cached result.
OverloadMode :: enum u8 {
	// The in-progress marker of a call, which hits in every mode and so guards against recursion.
	Pending,
	// One member, for the result of the call. A tie between members whose results differ picks none.
	Specific,
	// Every candidate, as an aggregate when several fit.
	All,
	// One member, for its parameter at `overload_arg_index`. A tie between members whose parameters differ there
	// yields every tied member as an aggregate, which only completion accepts.
	Member,
}

// `resolve_specific_overload` asks for one member. The call that `overload_arg_call` names wants it for a
// parameter, any other call, such as `f()` in `f()()` or a call in an argument, for its result.
overload_mode :: proc(ast_context: ^AstContext, call_expr: ^ast.Call_Expr) -> OverloadMode {
	if should_resolve_all_proc_overload_possibilities(ast_context, call_expr) {
		return .All
	}
	if !ast_context.resolve_specific_overload {
		return .Specific
	}
	return call_expr != nil && call_expr == ast_context.overload_arg_call ? .Member : .Specific
}

// The members of the candidates that share the top score, and whether they take the same type at the argument
// at index of call. Each parameter type resolves in the package of its member. A parameter type that contains a
// poly parameter counts as equal, as in `top_candidates_agree`.
tied_candidates_at_arg :: proc(
	ast_context: ^AstContext,
	candidates: []Candidate,
	call: ast.Call_Expr,
	index: int,
) -> (
	tied: []Symbol,
	agree: bool,
) {
	top, has_top := get_top_candiate(candidates)
	if !has_top {
		return nil, true
	}
	param_type :: proc(member: Symbol, call: ast.Call_Expr, index: int) -> ^ast.Expr {
		value, is_proc := member.value.(SymbolProcedureValue)
		if !is_proc {
			return nil
		}
		field, has_field := get_call_arg_field(value, call, index)
		if !has_field {
			return nil
		}
		return field.type != nil ? field.type : field.default_value
	}
	resolve_param :: proc(ast_context: ^AstContext, member: Symbol, expr: ^ast.Expr) -> (Symbol, bool) {
		set_ast_package_from_symbol_scoped(ast_context, member)
		return resolve_type_expression(ast_context, expr)
	}
	members := make([dynamic]Symbol, context.temp_allocator)
	agree = true
	at := param_type(top.symbol, call, index)
	for candidate in candidates {
		if candidate.score != top.score do continue
		append(&members, candidate.symbol)
		bt := param_type(candidate.symbol, call, index)
		if !agree || at == bt {
			continue
		}
		if at == nil || bt == nil {
			agree = false
			continue
		}
		if expr_contains_poly(at) || expr_contains_poly(bt) {
			continue
		}
		as, aok := resolve_param(ast_context, top.symbol, at)
		bs, bok := resolve_param(ast_context, candidate.symbol, bt)
		agree = aok && bok && is_symbol_same_typed(ast_context, as, bs)
	}
	return members[:], agree
}

// Whether ident lies in the top-level declaration of the file that holds local. Locals come from the procedure
// or enum at the cursor, so a name in another top-level declaration, such as the initializer of a global that
// the procedure uses, never names one. Calls inside such an initializer turn `use_locals` back on, so
// `resolve_global_identifier` alone does not keep them out. A name from another file, or a synthesized one,
// is not checked. A declaration inside a top-level `when` counts as top-level.
in_local_top_level_decl :: proc(file: ast.File, local: DocumentLocal, ident: ast.Ident) -> bool {
	if ident.pos.file == "" || ident.pos.file != file.fullpath {
		return true
	}
	return top_level_decl_at(file.decls[:], ident.pos.offset) == top_level_decl_at(file.decls[:], local.lhs.pos.offset)
}

// The last statement of stmts that starts at or before offset, or nil before the first one. When that statement
// is a `when` and offset lies in one of its branch bodies, the statement comes from that body instead.
// End offsets decide only the branch: a declaration that is still being typed can end before its body does.
@(private = "file")
top_level_decl_at :: proc(stmts: []^ast.Stmt, offset: int) -> ^ast.Stmt {
	starts_at_or_before :: proc(stmt: ^ast.Stmt, offset: int) -> slice.Ordering {
		return stmt.pos.offset <= offset ? .Less : .Greater
	}
	after, _ := slice.binary_search_by(stmts, offset, starts_at_or_before)
	if after == 0 {
		return nil
	}
	stmt := stmts[after - 1]
	if w, is_when := stmt.derived.(^ast.When_Stmt); is_when {
		branch := w.body
		if w.else_stmt != nil && offset >= w.else_stmt.pos.offset {
			branch = w.else_stmt
		}
		#partial switch b in branch.derived {
		case ^ast.Block_Stmt:
			if b.pos.offset <= offset && offset < b.end.offset {
				return top_level_decl_at(b.stmts, offset)
			}
		case ^ast.When_Stmt:
			return top_level_decl_at({branch}, offset)
		}
	}
	return stmt
}
