package server

import "core:odin/ast"

// The member argument of `offset_of(T, member)` and `offset_of_member(T, member)`. It names a field of T and is
// not an expression, so it must never resolve to a package, procedure or constant of the same name.
// ponytail: matches the builtin by name, so a user procedure that shadows `offset_of` is treated as the builtin.
offset_of_member_arg :: proc(call: ^ast.Call_Expr) -> (member: ^ast.Ident, ok: bool) {
	if call == nil || call.expr == nil || len(call.args) != 2 do return
	callee := call.expr.derived.(^ast.Ident) or_return
	if callee.name != "offset_of" && callee.name != "offset_of_member" do return
	member = call.args[1].derived.(^ast.Ident) or_return
	return member, true
}

// The member as the selector `T.member`, which resolves it to the field of T.
offset_of_member_selector :: proc(call: ^ast.Call_Expr, member: ^ast.Ident) -> ^ast.Selector_Expr {
	selector := new(ast.Selector_Expr, context.temp_allocator)
	selector.pos, selector.end = member.pos, member.end
	selector.derived = selector
	selector.derived_expr = selector
	selector.expr = call.args[0]
	selector.op.kind = .Period
	selector.field = member
	return selector
}

// Records the field of T for the member in the resolved file, so it is never a use of a package or global.
resolve_offset_of_member :: proc(data: ^FileResolveData, call: ^ast.Call_Expr, member: ^ast.Ident) {
	reset_ast_context(data.ast_context)
	selector := offset_of_member_selector(call, member)
	symbol: Symbol
	ok: bool
	if data.flag == .None {
		symbol, ok = resolve_type_expression(data.ast_context, &selector.node)
	} else if data.target_name == "" || member.name == data.target_name {
		symbol, ok = resolve_location_selector(data.ast_context, selector)
	}
	if ok {
		data.symbols[uintptr(member)] = SymbolAndNode {
			node   = member,
			symbol = new_clone(symbol, data.ast_context.allocator),
		}
	}
}

// The enclosing `offset_of` call and its member when the cursor is on the member.
offset_of_member_at_cursor :: proc(
	position_context: ^DocumentPositionContext,
) -> (
	call: ^ast.Call_Expr,
	member: ^ast.Ident,
	ok: bool,
) {
	if position_context.identifier == nil || position_context.call == nil do return
	call = position_context.call.derived.(^ast.Call_Expr) or_return
	member = offset_of_member_arg(call) or_return
	if &member.node != position_context.identifier do return
	return call, member, true
}

// The field that the member of an enclosing `offset_of` call at the cursor names.
resolve_location_offset_of_member :: proc(
	ast_context: ^AstContext,
	position_context: ^DocumentPositionContext,
) -> (
	symbol: Symbol,
	ok: bool,
) {
	call, member := offset_of_member_at_cursor(position_context) or_return
	symbol = resolve_location_selector(ast_context, offset_of_member_selector(call, member)) or_return
	// A missing field resolves to T itself.
	if symbol.type != .Field do return {}, false
	return symbol, true
}

// The hover of the member of an enclosing `offset_of` call at the cursor: the field of T, as a field hover shows it.
// `is_member` is true whenever the cursor is on the member, and `ok` only when T has that field.
hover_offset_of_member :: proc(
	ast_context: ^AstContext,
	position_context: ^DocumentPositionContext,
) -> (
	content: MarkupContent,
	is_member: bool,
	ok: bool,
) {
	call, member := offset_of_member_at_cursor(position_context) or_return
	is_member = true
	owner := resolve_type_expression(ast_context, call.args[0]) or_return
	v := owner.value.(SymbolStructValue) or_return
	set_ast_package_set_scoped(ast_context, owner.pkg)
	for name, i in v.names {
		if name != member.name do continue
		symbol := resolve_type_expression(ast_context, v.types[i]) or_return
		construct_struct_field_symbol(&symbol, owner.name, v, i)
		build_documentation(ast_context, &symbol, true)
		content = write_hover_content(ast_context, symbol, layout = struct_field_layout_hover(ast_context, v, i))
		return content, true, true
	}
	return
}
