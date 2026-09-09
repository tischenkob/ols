#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:slice"

@(private = "package")
add_remove_param_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_remove_param {
		return
	}
	function := ctx.position_context.function
	if function == nil {
		return
	}
	params := param_names(function)
	index := -1
	for param, i in params {
		if param.name != nil && param.name.pos.offset <= ctx.range.start && ctx.range.start <= param.name.end.offset {
			index = i
		}
	}
	if index < 0 {
		return
	}
	decl, is_top := proc_decl_of(ctx.document, function)
	if !is_top || !plain_signature(decl, function) {
		return
	}
	target := params[index]
	if !slice.contains(unused_params(function), target.name) {
		return
	}
	sites, sites_ok := find_call_sites(ctx.document, decl, len(params), ctx.files)
	if !sites_ok {
		return
	}
	// Deleting the argument would delete whatever evaluating it does.
	for site in sites {
		if has_side_effect(site.call.args[index]) {
			return
		}
	}

	changes := make(Changes, context.temp_allocator)
	fields := function.type.params.list
	if len(target.field.names) == 1 {
		remove_list_item(&changes, ctx.document, fields, slice.linear_search(fields, target.field) or_else 0)
	} else {
		names := target.field.names
		remove_list_item(&changes, ctx.document, names, slice.linear_search(names, cast(^ast.Expr)target.name) or_else 0)
	}
	for site in sites {
		remove_list_item(&changes, site.document, site.call.args, index)
	}
	append(
		ctx.actions,
		CodeAction {
			title = fmt.tprintf("Remove parameter %s", target.name.name),
			kind = "quickfix",
			edit = workspace_edit(changes),
		},
	)
}
