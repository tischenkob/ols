#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:strings"

// On a selection of two or more adjacent parameters of a top-level procedure `foo`: "Introduce parameter object"
// declares `Foo_Params :: struct {...}` with them after the procedure, takes `params: Foo_Params` in their place,
// reads `params.a` in the body and passes `Foo_Params{a = ..., b = ...}` at each call.
@(private = "package")
add_param_object_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_param_object {
		return
	}
	function := ctx.position_context.function
	if function == nil || ctx.range.start == ctx.range.end {
		return
	}
	params := param_names(function)
	first, last := -1, -1
	for param, i in params {
		if param.name != nil && ctx.range.start <= param.name.end.offset && param.name.pos.offset < ctx.range.end {
			if first < 0 do first = i
			last = i
		}
	}
	if first < 0 || last == first {
		return
	}
	decl, is_top := proc_decl_of(ctx.document, function)
	if !is_top || !swappable(decl) || signature_problem(decl, function) != "" {
		return
	}
	// The selection must hold whole fields, so `a, b: int` gives both names or neither.
	first_field, last_field := params[first].field, params[last].field
	if first_field.names[0].pos.offset != params[first].name.pos.offset ||
	   last_field.names[len(last_field.names) - 1].pos.offset != params[last].name.pos.offset {
		return
	}
	src := ctx.document.ast.src
	start, end := first_field.pos.offset, last_field.end.offset
	// The replaced text must not hold a comment, which the new parameter would drop.
	for group in ctx.document.ast.comments {
		if start <= group.pos.offset && group.pos.offset < end {
			return
		}
	}

	proc_name := final_name(decl.names[0])
	type_name := strings.concatenate(
		{strings.to_ada_case(proc_name, context.temp_allocator), "_Params"},
		context.temp_allocator,
	)
	if !is_plain_name(type_name) || package_declares(ctx, type_name) {
		return
	}
	// The new parameter must not hide a name that the procedure reads, and must not take the name of another parameter.
	for use in collect_ident_uses(function) {
		if use.ident.name == "params" && !is_member_name(use) {
			return
		}
	}

	names := make([dynamic]string, context.temp_allocator)
	struct_sb := strings.builder_make(context.temp_allocator)
	unit := indent_unit(src, "", nil)
	fmt.sbprintf(&struct_sb, "%s :: struct {{\n", type_name)
	for i in first ..= last {
		name := params[i].name.name
		type := node_text(src, params[i].field.type)
		// A field named like a type that a field type names would take the place of that type inside the struct.
		if name == "_" || strings.contains_any(type, "\r\n") {
			return
		}
		append(&names, name)
		fmt.sbprintf(&struct_sb, "%s%s: %s,\n", unit, name, type)
	}
	strings.write_string(&struct_sb, "}")
	for i in first ..= last {
		if type_names_clash(node_text(src, params[i].field.type), names[:]) {
			return
		}
	}

	h := Call_Hierarchy{ctx.files, make(map[string]^Document, context.temp_allocator)}
	if len(top_level_variants(&h, ctx.document, decl)) > 0 {
		return
	}
	sites, _, sites_ok := find_call_sites(ctx.document, decl, len(params), ctx.files)
	if !sites_ok {
		return
	}
	private := file_private(ctx.document, decl)
	changes := make(Changes, context.temp_allocator)
	for site in sites {
		// A file-private type cannot be named from another file.
		if private && site.document.uri.uri != ctx.document.uri.uri {
			return
		}
		args := site.call.args
		arg_start, arg_end := args[first].pos.offset, args[last].end.offset
		// A call of the procedure in a replaced argument would take an edit inside this one.
		for other in sites {
			if other.document == site.document &&
			   other.call != site.call &&
			   arg_start <= other.call.pos.offset &&
			   other.call.pos.offset < arg_end {
				return
			}
		}
		qualifier, qualified := type_qualifier(ctx.document, site)
		if !qualified {
			return
		}
		sb := strings.builder_make(context.temp_allocator)
		fmt.sbprintf(&sb, "%s%s{{", qualifier, type_name)
		for i in first ..= last {
			if i > first do strings.write_string(&sb, ", ")
			fmt.sbprintf(&sb, "%s = %s", names[i - first], node_text(site.document.ast.src, args[i]))
		}
		strings.write_string(&sb, "}")
		append_edit(&changes, site.document, arg_start, arg_end, strings.to_string(sb))
	}

	for use in params_uses(ctx, function, params[first:last + 1]) {
		append_edit(&changes, ctx.document, use.ident.pos.offset, use.ident.pos.offset, "params.")
	}
	append_edit(
		&changes,
		ctx.document,
		start,
		end,
		strings.concatenate({"params: ", type_name}, context.temp_allocator),
	)

	insert, insert_ok := insert_after_decl(ctx, decl.pos.offset, strings.to_string(struct_sb))
	if !insert_ok {
		return
	}
	edits := &changes[ctx.document.uri.uri]
	append(edits, insert)
	append(
		ctx.actions,
		CodeAction{title = "Introduce parameter object", kind = "refactor.rewrite", edit = workspace_edit(changes)},
	)
}

// The prefix that names the new type at a call: none in the package of the procedure, else the package name that the
// callee is written with, as in `pkg.foo(...)`.
type_qualifier :: proc(home: ^Document, site: Call_Site) -> (string, bool) {
	if site.document.package_name == home.package_name {
		return "", true
	}
	selector, is_selector := site.call.expr.derived.(^ast.Selector_Expr)
	if !is_selector || selector.op.kind != .Period {
		return "", false
	}
	base, is_ident := selector.expr.derived.(^ast.Ident)
	if !is_ident {
		return "", false
	}
	return strings.concatenate({base.name, "."}, context.temp_allocator), true
}

// The uses in the body of function of the parameters in params. A nested scope can shadow a parameter, and a nested
// procedure cannot see one.
@(private = "package")
params_uses :: proc(ctx: ^ActionContext, function: ^ast.Proc_Lit, params: []Param_Name) -> []IdentUse {
	defer restore_locals(ctx)
	uses := make([dynamic]IdentUse, context.temp_allocator)
	body: for use in collect_ident_uses(function.body) {
		if is_member_name(use) {
			continue
		}
		for parent in use.parents {
			if _, nested := parent.derived.(^ast.Proc_Lit); nested {
				continue body
			}
		}
		for param in params {
			if use.ident.name != param.name.name {
				continue
			}
			gather_locals_in(ctx, function, use.ident.pos.offset)
			if local, is_local := get_local(ctx.ast_context^, use.ident^);
			   is_local && local.lhs.pos.offset == param.name.pos.offset {
				append(&uses, use)
			}
			continue body
		}
	}
	return uses[:]
}
