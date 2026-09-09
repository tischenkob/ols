#+private file

package server

import "core:odin/ast"
import "core:strings"

// A constant expression in a top-level procedure becomes a new last parameter, and every caller
// passes it. Constants only: an expression over locals would need rewriting per caller.
@(private = "package")
add_introduce_param_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_introduce_param {
		return
	}
	function := ctx.position_context.function
	if function == nil || function.body == nil {
		return
	}
	decl, is_top := proc_decl_of(ctx.document, function)
	if !is_top || !plain_signature(decl, function) {
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
	if value_decl, is_decl := stmt.derived.(^ast.Value_Decl); is_decl && !value_decl.is_mutable {
		return
	}

	// The selection must match one expression; the cursor takes the outermost constant around it.
	expr: ^ast.Expr
	parent: ^ast.Node
	for at in nodes_at({stmt}, start) {
		if start != end && (at.node.pos.offset != start || at.node.end.offset != end) {
			continue
		}
		if _, is_ident := at.node.derived.(^ast.Ident); is_ident && start == end {
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

	base := strings.to_lower(const_name(ctx, expr, parent), context.temp_allocator)
	if base == "constant" {
		base = "value"
	}
	name := fresh_name(ctx, base, expr.pos)

	symbol, resolved := resolve_type_expression(ctx.ast_context, expr)
	if !resolved {
		return
	}
	// Untyped literals print as their default types only when marked mutable.
	symbol.flags += {.Mutable}
	type, type_ok := symbol_type_text(ctx.ast_context, symbol, name)
	if !type_ok {
		return
	}

	params := function.type.params
	// The parser leaves Field_List.close unset; with no fields the first `)` after `proc` closes the list.
	close := function.type.pos.offset + strings.index_byte(src[function.type.pos.offset:], ')')
	sites, sites_ok := find_call_sites(ctx.document, decl, len(param_names(function)), ctx.files)
	if !sites_ok {
		return
	}

	changes := make(Changes, context.temp_allocator)
	param := strings.concatenate({name, ": ", type}, context.temp_allocator)
	append_list_item(&changes, ctx.document, params.list, close, param)
	append_edit(&changes, ctx.document, expr.pos.offset, expr.end.offset, name)
	value := node_text(src, expr)
	for site in sites {
		append_list_item(&changes, site.document, site.call.args, site.call.close.offset, value)
	}
	append(
		ctx.actions,
		CodeAction{title = "Introduce parameter", kind = "refactor.rewrite", edit = workspace_edit(changes)},
	)
}
