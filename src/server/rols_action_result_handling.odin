#+private file

package server

import "core:odin/ast"
import "core:strings"

@(private = "package")
Result_Kind :: enum {
	Other,
	Bool,
	Error,
}

@(private = "package")
add_result_handling_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_result_handling {
		return
	}
	function := ctx.position_context.function
	if function == nil || function.body == nil {
		return
	}

	call: ^ast.Call_Expr
	parent: ^ast.Node
	#reverse for at in nodes_at({function.body}, ctx.range.start) {
		if c, is_call := at.node.derived.(^ast.Call_Expr); is_call {
			call, parent = c, at.parent
			break
		}
	}
	if call == nil || parent == nil {
		return
	}
	#partial switch _ in parent.derived {
	case ^ast.Or_Return_Expr, ^ast.Or_Else_Expr, ^ast.Or_Branch_Expr:
		return
	}

	resolved, is_resolved := resolve_entire_file(ctx.document)[uintptr(call.expr)]
	if !is_resolved {
		return
	}
	callee, is_proc := resolved.symbol.value.(SymbolProcedureValue)
	if !is_proc {
		return
	}
	results := field_types(callee.return_types)
	if len(results) == 0 {
		return
	}
	last := results[len(results) - 1]
	kind := result_kind(last)

	src := ctx.document.ast.src
	_, is_stmt := parent.derived.(^ast.Expr_Stmt)

	if is_stmt {
		sb := strings.builder_make(context.temp_allocator)
		for i in 0 ..< len(results) {
			strings.write_string(&sb, i == 0 ? "_" : ", _")
		}
		strings.write_string(&sb, " = ")
		append_insert(ctx, call.pos.offset, "Discard result", "quickfix", strings.to_string(sb))
	}
	if kind == .Other {
		return
	}

	proc_results: []^ast.Expr
	if function.type != nil && function.type.results != nil {
		proc_results = field_types(function.type.results.list)
	}
	proc_last: ^ast.Expr
	if len(proc_results) > 0 {
		proc_last = proc_results[len(proc_results) - 1]
	}
	propagates := proc_last != nil && same_error(ctx, src, last, proc_last, kind)

	// `x := f() or_return` needs a result left over once the error is taken off.
	if propagates && (is_stmt || len(results) > 1) {
		append_insert(ctx, call.end.offset, "Add or_return", is_stmt ? "quickfix" : "refactor.rewrite", " or_return")
	}

	if len(results) != 2 {
		return
	}

	if !is_stmt {
		set_ast_package_set_scoped(ctx.ast_context, resolved.symbol.pkg)
		first, first_ok := resolve_type_expression(ctx.ast_context, results[0])
		text := strings.concatenate({" or_else ", zero_value_text(first, first_ok)}, context.temp_allocator)
		append_insert(ctx, call.end.offset, "Add or_else", "refactor.rewrite", text)
	}

	decl := parent.derived.(^ast.Value_Decl) or_else nil
	if edits, ok := handle_result_edits(ctx, decl, kind, proc_results, propagates); ok {
		append(ctx.actions, make_code_action(ctx, "Handle result with if", "refactor.rewrite", edits))
	}
}

// Adds `, ok`/`, err` to a one-name declaration and an `if` after it that returns zero values,
// propagating the error when `propagates`.
@(private = "package")
handle_result_edits :: proc(
	ctx: ^ActionContext,
	decl: ^ast.Value_Decl,
	kind: Result_Kind,
	proc_results: []^ast.Expr,
	propagates: bool,
) -> (
	[]TextEdit,
	bool,
) {
	if decl == nil || !decl.is_mutable || len(decl.names) != 1 || len(decl.values) != 1 {
		return nil, false
	}
	src := ctx.document.ast.src
	name := fresh_name(ctx, kind == .Bool ? "ok" : "err", decl.pos)
	ind := get_line_indentation(src, decl.pos.offset)
	edits := make([]TextEdit, 2, context.temp_allocator)
	edits[0] = {
		range   = range_of(ctx, decl.names[0].end.offset, decl.names[0].end.offset),
		newText = strings.concatenate({", ", name}, context.temp_allocator),
	}
	edits[1] = {
		range   = range_of(ctx, decl.end.offset, decl.end.offset),
		newText = handle_result_if_text(ctx, name, kind, proc_results, propagates, ind),
	}
	return edits, true
}

// "\n" + `if !ok {`/`if err != nil {` returning zero values, to go after a statement indented by ind.
@(private = "package")
handle_result_if_text :: proc(
	ctx: ^ActionContext,
	name: string,
	kind: Result_Kind,
	proc_results: []^ast.Expr,
	propagates: bool,
	ind: string,
) -> string {
	ret := strings.builder_make(context.temp_allocator)
	strings.write_string(&ret, "return")
	for type, i in proc_results {
		strings.write_string(&ret, i == 0 ? " " : ", ")
		if propagates && kind == .Error && i == len(proc_results) - 1 {
			strings.write_string(&ret, name)
			continue
		}
		symbol, ok := resolve_type_expression(ctx.ast_context, type)
		strings.write_string(&ret, zero_value_text(symbol, ok))
	}

	unit := indent_unit(ctx.document.ast.src, ind, nil)
	cond := kind == .Bool ? "!" : ""
	tail := kind == .Bool ? "" : " != nil"
	return strings.concatenate(
		{"\n", ind, "if ", cond, name, tail, " {\n", ind, unit, strings.to_string(ret), "\n", ind, "}"},
		context.temp_allocator,
	)
}

// One type per value: `a, b: int` yields int twice.
@(private = "package")
field_types :: proc(fields: []^ast.Field) -> []^ast.Expr {
	types := make([dynamic]^ast.Expr, context.temp_allocator)
	for field in fields {
		for _ in 0 ..< max(len(field.names), 1) {
			append(&types, field.type)
		}
	}
	return types[:]
}

@(private = "package")
result_kind :: proc(type: ^ast.Expr) -> Result_Kind {
	if type == nil {
		return .Other
	}
	#partial switch t in type.derived {
	case ^ast.Ident:
		if t.name == "bool" {
			return .Bool
		}
		if strings.contains(t.name, "Err") {
			return .Error
		}
	case ^ast.Selector_Expr:
		if t.field != nil && strings.contains(t.field.name, "Err") {
			return .Error
		}
	case ^ast.Union_Type:
		return .Error
	}
	return .Other
}

@(private = "package")
final_name :: proc(type: ^ast.Expr) -> string {
	#partial switch t in type.derived {
	case ^ast.Ident:
		return t.name
	case ^ast.Selector_Expr:
		if t.field != nil {
			return t.field.name
		}
	}
	return ""
}

// Whether a result of type `last` can be returned through a proc whose last result is `proc_last`:
// bool through bool, or an error through the same error type or a union that lists it.
same_error :: proc(ctx: ^ActionContext, src: string, last, proc_last: ^ast.Expr, kind: Result_Kind) -> bool {
	if kind == .Bool {
		return result_kind(proc_last) == .Bool
	}
	if result_kind(proc_last) != .Error {
		return false
	}
	text := strip_space(node_text(src, last))
	if text == strip_space(node_text(src, proc_last)) {
		return true
	}
	name := final_name(last)
	if name == "" {
		return false
	}
	variants: []^ast.Expr
	if union_type, is_union := proc_last.derived.(^ast.Union_Type); is_union {
		variants = union_type.variants
	} else if symbol, ok := resolve_type_expression(ctx.ast_context, proc_last); ok {
		variants = (symbol.value.(SymbolUnionValue) or_else {}).types
	}
	for variant in variants {
		if final_name(variant) == name {
			return true
		}
	}
	return false
}
