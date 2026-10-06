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
	if !is_top || signature_problem(decl, function) != "" {
		return
	}
	target := params[index]
	if !slice.contains(unused_params(function), target.name) {
		return
	}
	// The platform variants of the procedure lose the parameter too, so each must have the same parameters and
	// leave it unused.
	h := Call_Hierarchy{ctx.files, make(map[string]^Document, context.temp_allocator)}
	variants := top_level_variants(&h, ctx.document, decl)
	for variant in variants {
		if variant_problem(variant, params, ctx.document.ast.src) != "" {
			return
		}
		lit := variant.decl.values[0].derived.(^ast.Proc_Lit)
		if !slice.contains(unused_param_names(lit), target.name.name) {
			return
		}
	}
	sites, _, sites_ok := find_call_sites(ctx.document, decl, len(params), ctx.files, variant_symbols(variants))
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
	remove_param(&changes, ctx.document, function, index)
	for variant in variants {
		remove_param(&changes, variant.document, variant.decl.values[0].derived.(^ast.Proc_Lit), index)
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

// The names of the parameters of lit that its body never reads.
unused_param_names :: proc(lit: ^ast.Proc_Lit) -> []string {
	unused := unused_params(lit)
	names := make([]string, len(unused), context.temp_allocator)
	for ident, i in unused do names[i] = ident.name
	return names
}

// Removes the parameter at index from the parameter list of lit in document.
remove_param :: proc(changes: ^Changes, document: ^Document, lit: ^ast.Proc_Lit, index: int) {
	target := param_names(lit)[index]
	fields := lit.type.params.list
	if len(target.field.names) == 1 {
		remove_list_item(changes, document, fields, slice.linear_search(fields, target.field) or_else 0)
	} else {
		names := target.field.names
		remove_list_item(changes, document, names, slice.linear_search(names, cast(^ast.Expr)target.name) or_else 0)
	}
}
