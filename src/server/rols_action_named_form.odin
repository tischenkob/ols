#+private file

package server

import "core:odin/ast"
import "core:strings"

// `Foo{1, 2}` and `Foo{x = 1, y = 2}`, `f(1, 2)` and `f(a = 1, b = 2)`. The text keeps its order, so the values evaluate
// in the same order.
@(private = "package")
add_named_form_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_named_form {
		return
	}
	add_literal_form(ctx)
	add_call_form(ctx)
}

add_literal_form :: proc(ctx: ^ActionContext) {
	lit := ctx.position_context.comp_lit
	if lit == nil || len(lit.elems) == 0 {
		return
	}
	reset_ast_context(ctx.ast_context)
	symbol: Symbol
	resolved: bool
	if lit.type != nil {
		symbol, resolved = resolve_type_expression(ctx.ast_context, lit.type)
	} else {
		symbol, resolved = resolve_comp_literal(ctx.ast_context, ctx.position_context)
	}
	if !resolved {
		return
	}
	value, is_struct := symbol.value.(SymbolStructValue)
	if !is_struct || len(value.usings) > 0 || len(lit.elems) != len(value.names) {
		return
	}
	for name, i in value.names {
		if name == "_" || value.from_usings[i] != -1 {
			return
		}
	}

	named := 0
	for elem in lit.elems {
		if _, is_named := elem.derived.(^ast.Field_Value); is_named {
			named += 1
		}
	}
	edits := make([dynamic]TextEdit, context.temp_allocator)
	switch named {
	case 0:
		for elem, i in lit.elems {
			append(&edits, name_edit(ctx, elem, value.names[i]))
		}
		append(ctx.actions, make_code_action(ctx, "Convert to named fields", "refactor.rewrite", edits[:]))
	case len(lit.elems):
		for elem, i in lit.elems {
			field := elem.derived.(^ast.Field_Value)
			ident, is_ident := field.field.derived.(^ast.Ident)
			if !is_ident || ident.name != value.names[i] {
				return
			}
			append(&edits, unname_edit(ctx, field))
		}
		append(ctx.actions, make_code_action(ctx, "Convert to positional fields", "refactor.rewrite", edits[:]))
	}
}

add_call_form :: proc(ctx: ^ActionContext) {
	call := call_at(ctx)
	if call == nil || len(call.args) == 0 || call.ellipsis.kind != .Invalid {
		return
	}
	value, _, is_proc := plain_callee(ctx, call)
	if !is_proc {
		return
	}
	params, named_params := param_names_of(value)
	if !named_params || len(call.args) > len(params) {
		return
	}

	positional := make([dynamic]TextEdit, context.temp_allocator)
	unnamed := make([dynamic]TextEdit, context.temp_allocator)
	holds_order := true
	for arg, i in call.args {
		if field, is_named := arg.derived.(^ast.Field_Value); is_named {
			ident, is_ident := field.field.derived.(^ast.Ident)
			if !is_ident || ident.name != params[i] {
				holds_order = false
			}
			append(&unnamed, unname_edit(ctx, field))
		} else {
			append(&positional, name_edit(ctx, arg, params[i]))
		}
	}
	if len(positional) > 0 && (len(call.args) == len(params) || !fills_params(ctx, call)) {
		append(ctx.actions, make_code_action(ctx, "Convert to named arguments", "refactor.rewrite", positional[:]))
	}
	if len(unnamed) > 0 && holds_order {
		append(ctx.actions, make_code_action(ctx, "Convert to positional arguments", "refactor.rewrite", unnamed[:]))
	}
}

name_edit :: proc(ctx: ^ActionContext, value: ^ast.Expr, name: string) -> TextEdit {
	at := value.pos.offset
	return {range = range_of(ctx, at, at), newText = strings.concatenate({name, " = "}, context.temp_allocator)}
}

unname_edit :: proc(ctx: ^ActionContext, field: ^ast.Field_Value) -> TextEdit {
	return {range = range_of(ctx, field.pos.offset, field.value.pos.offset)}
}

// The innermost call around the cursor, in the procedure literal around the cursor.
call_at :: proc(ctx: ^ActionContext) -> ^ast.Call_Expr {
	#reverse for at in nodes_at(ctx.document.ast.decls[:], ctx.range.start) {
		#partial switch n in at.node.derived {
		case ^ast.Proc_Lit:
			return nil
		case ^ast.Call_Expr:
			if ctx.range.end <= n.end.offset {
				return n
			}
		}
	}
	return nil
}

// The procedure a call runs, when the call names that very procedure. A group resolves to a member by its arguments, and
// a builtin takes no named argument. `x->f()` passes a receiver that its arguments do not show.
@(private = "package")
plain_callee :: proc(
	ctx: ^ActionContext,
	call: ^ast.Call_Expr,
) -> (
	value: SymbolProcedureValue,
	symbol: Symbol,
	ok: bool,
) {
	name: string
	#partial switch callee in call.expr.derived {
	case ^ast.Ident:
		name = callee.name
	case ^ast.Selector_Expr:
		if callee.op.kind != .Period || callee.field == nil {
			return
		}
		name = callee.field.name
	case:
		return
	}
	resolved, found := resolve_entire_file(ctx.document)[uintptr(call.expr)]
	if !found {
		return
	}
	symbol = resolved.symbol^
	if symbol.name != name || symbol.pkg == "$builtin" || strings.has_suffix(symbol.pkg, "intrinsics") {
		return
	}
	value, ok = symbol.value.(SymbolProcedureValue)
	return
}

// Each parameter's name, flattened. It fails on a variadic, a blank or a compile-time parameter, or on a type without
// parameter names, for which the parser makes up the name at the position of the type.
param_names_of :: proc(value: SymbolProcedureValue) -> (names: []string, ok: bool) {
	fields := len(value.orig_arg_types) > 0 ? value.orig_arg_types : value.arg_types
	found := make([dynamic]string, context.temp_allocator)
	for field in fields {
		if field.type != nil {
			if _, variadic := field.type.derived.(^ast.Ellipsis); variadic {
				return
			}
		}
		for name in field.names {
			ident, is_ident := name.derived.(^ast.Ident)
			if !is_ident || ident.name == "_" {
				return
			}
			if field.type != nil && name.pos.offset == field.type.pos.offset {
				return
			}
			append(&found, ident.name)
		}
	}
	return found[:], true
}

// Whether a call with fewer arguments than parameters can spread a call's results over them: `f(g())` for two
// parameters takes both results of `g`, which a name cannot do.
fills_params :: proc(ctx: ^ActionContext, call: ^ast.Call_Expr) -> bool {
	typed := resolve_entire_file(ctx.document)
	for arg in call.args {
		inner := ast.unparen_expr(arg)
		extra := 0
		if or_return_expr, is_or := inner.derived.(^ast.Or_Return_Expr); is_or {
			inner = ast.unparen_expr(or_return_expr.expr)
			extra = 1
		}
		arg_call, is_call := inner.derived.(^ast.Call_Expr)
		if !is_call {
			continue
		}
		resolved, found := typed[uintptr(arg_call.expr)]
		if !found {
			return true
		}
		#partial switch callee in resolved.symbol.value {
		case SymbolProcedureValue:
			count := 0
			for result in callee.return_types {
				count += len(result.names)
			}
			if count > 1 + extra {
				return true
			}
		case SymbolProcedureGroupValue, SymbolAggregateValue:
			return true
		}
	}
	return false
}
