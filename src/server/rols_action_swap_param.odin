#+private file

package server

import "core:odin/ast"

import "src:common"

// Offers "Move parameter left" and "Move parameter right" for the parameter at the range. Both share one workspace
// search for the calls.
@(private = "package")
add_swap_param_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_swap_param {
		return
	}
	function := ctx.position_context.function
	if function == nil {
		return
	}
	params := param_names(function)
	index := param_at_range(params, ctx.range)
	if len(params) < 2 || index < 0 {
		return
	}
	decl, is_top := proc_decl_of(ctx.document, function)
	if !is_top || !swappable(decl) || signature_problem(decl, function) != "" {
		return
	}
	h := Call_Hierarchy{ctx.files, make(map[string]^Document, context.temp_allocator)}
	variants := top_level_variants(&h, ctx.document, decl)
	for variant in variants {
		if !swappable(variant.decl) || variant_problem(variant, params, ctx.document.ast.src) != "" {
			return
		}
	}
	sites, _, sites_ok := find_call_sites(ctx.document, decl, len(params), ctx.files, variant_symbols(variants))
	if !sites_ok {
		return
	}
	offer_swap(ctx, function, variants, sites, index, index - 1, "Move parameter left")
	offer_swap(ctx, function, variants, sites, index, index + 1, "Move parameter right")
}

// A declared type keeps the old order, and a variable may take another procedure of that order.
@(private = "package")
swappable :: proc(decl: ^ast.Value_Decl) -> bool {
	return !decl.is_mutable && decl.type == nil
}

offer_swap :: proc(
	ctx: ^ActionContext,
	function: ^ast.Proc_Lit,
	variants: []Decl_Variant,
	sites: []Call_Site,
	index, neighbor: int,
	title: string,
) {
	count := len(param_names(function))
	if neighbor < 0 || neighbor >= count {
		return
	}
	// Swapping the arguments swaps the order in which they evaluate.
	for site in sites {
		if has_side_effect(site.call.args[index]) || has_side_effect(site.call.args[neighbor]) {
			return
		}
	}
	order := make([]int, count, context.temp_allocator)
	for &value, i in order {
		value = i
	}
	order[index], order[neighbor] = neighbor, index
	edit := reorder_params_edit(ctx.document, function, order, variants, sites)
	append(ctx.actions, CodeAction{title = title, kind = "refactor.rewrite", edit = edit})
}

// The index of the parameter that holds the range, or -1. In `a, b: int` the type belongs to both names and selects
// neither.
@(private = "package")
param_at_range :: proc(params: []Param_Name, range: common.AbsoluteRange) -> int {
	for param, i in params {
		if param.name == nil {
			continue
		}
		field := param.field
		if holds_range(param.name, range) ||
		   (len(field.names) == 1 && (holds_range(field.type, range) || holds_range(field.default_value, range))) {
			return i
		}
	}
	return -1
}

holds_range :: proc(node: ^ast.Node, range: common.AbsoluteRange) -> bool {
	return node != nil && node.pos.offset <= range.start && range.end <= node.end.offset
}
