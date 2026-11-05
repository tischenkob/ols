#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:strings"

import "src:common"

// On a parameter of a top-level procedure: "Pass by pointer" turns `x: T` into `x: ^T`, reads `x^` in the body and
// passes `&arg`, and "Pass by value" does the reverse for `x: ^T`.
@(private = "package")
add_param_pointer_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_param_pointer {
		return
	}
	function := ctx.position_context.function
	if function == nil {
		return
	}
	params := param_names(function)
	index := param_at_range(params, ctx.range)
	if index < 0 {
		return
	}
	decl, is_top := proc_decl_of(ctx.document, function)
	if !is_top || !swappable(decl) || signature_problem(decl, function) != "" {
		return
	}
	// Each platform variant would need its own body rewritten.
	h := Call_Hierarchy{ctx.files, make(map[string]^Document, context.temp_allocator)}
	if len(top_level_variants(&h, ctx.document, decl)) > 0 {
		return
	}
	param := params[index]
	uses := params_uses(ctx, function, params[index:index + 1])
	if pointer, is_pointer := param.field.type.derived.(^ast.Pointer_Type); is_pointer {
		offer_by_value(ctx, decl, function, params, index, pointer, uses)
	} else {
		offer_by_pointer(ctx, decl, function, params, index, uses)
	}
}

offer_by_pointer :: proc(
	ctx: ^ActionContext,
	decl: ^ast.Value_Decl,
	function: ^ast.Proc_Lit,
	params: []Param_Name,
	index: int,
	uses: []IdentUse,
) {
	param := params[index]
	// An argument converts to `any`, a union, `rawptr` or another pointer type, and its address would not.
	reset_ast_context(ctx.ast_context)
	type, resolved := resolve_type_expression(ctx.ast_context, param.field.type)
	if !resolved || type.pointers > 0 {
		return
	}
	#partial switch v in type.value {
	case SymbolUnionValue, SymbolMultiPointerValue, SymbolProcedureValue, SymbolProcedureGroupValue:
		return
	case SymbolBasicValue:
		if v.ident == nil || v.ident.name == "any" || v.ident.name == "rawptr" || v.ident.name == "typeid" {
			return
		}
	}
	_, is_struct := type.value.(SymbolStructValue)

	sites, _, sites_ok := find_call_sites(ctx.document, decl, len(params), ctx.files)
	if !sites_ok {
		return
	}
	changes := make(Changes, context.temp_allocator)
	for site in sites {
		arg := site.call.args[index]
		if !addressable(site.document, arg) {
			return
		}
		append_edit(&changes, site.document, arg.pos.offset, arg.pos.offset, "&")
	}

	src := ctx.document.ast.src
	retype_param(
		&changes,
		ctx.document,
		param,
		strings.concatenate({"^", node_text(src, param.field.type)}, context.temp_allocator),
	)
	for use in uses {
		// A selector reaches a struct field through a pointer as it does through the value.
		if is_struct && len(use.parents) > 0 {
			if selector, is_selector := use.parents[len(use.parents) - 1].derived.(^ast.Selector_Expr);
			   is_selector && selector.expr == use.ident && selector.op.kind == .Period {
				continue
			}
		}
		append_edit(&changes, ctx.document, use.ident.end.offset, use.ident.end.offset, "^")
	}
	append(
		ctx.actions,
		CodeAction{title = "Pass by pointer", kind = "refactor.rewrite", edit = workspace_edit(changes)},
	)
}

offer_by_value :: proc(
	ctx: ^ActionContext,
	decl: ^ast.Value_Decl,
	function: ^ast.Proc_Lit,
	params: []Param_Name,
	index: int,
	pointer: ^ast.Pointer_Type,
	uses: []IdentUse,
) {
	param := params[index]
	if pointer.elem == nil || pointer.tag != nil {
		return
	}
	changes := make(Changes, context.temp_allocator)
	// The copy keeps what the caller sees apart from what the body writes, so the body may only read through the
	// pointer: `x^`, `x.f` and `x[i]`, none of them written or addressed.
	for use in uses {
		if is_write(use) || address_taken(use) || len(use.parents) == 0 {
			return
		}
		#partial switch p in use.parents[len(use.parents) - 1].derived {
		case ^ast.Deref_Expr:
			append_edit(&changes, ctx.document, p.op.pos.offset, p.end.offset, "")
		case ^ast.Selector_Expr:
			if p.expr != use.ident || p.op.kind != .Period {
				return
			}
		case ^ast.Index_Expr:
			if p.expr != use.ident {
				return
			}
		case:
			return
		}
	}

	sites, _, sites_ok := find_call_sites(ctx.document, decl, len(params), ctx.files)
	if !sites_ok {
		return
	}
	for site in sites {
		arg := site.call.args[index]
		if unary, is_unary := ast.unparen_expr(arg).derived.(^ast.Unary_Expr); is_unary && unary.op.kind == .And {
			append_edit(&changes, site.document, arg.pos.offset, unary.expr.pos.offset, "")
			append_edit(&changes, site.document, unary.expr.end.offset, arg.end.offset, "")
		} else {
			append_edit(&changes, site.document, arg.end.offset, arg.end.offset, "^")
		}
	}
	retype_param(&changes, ctx.document, param, node_text(ctx.document.ast.src, pointer.elem))
	append(ctx.actions, CodeAction{title = "Pass by value", kind = "refactor.rewrite", edit = workspace_edit(changes)})
}

// Gives the parameter type, splitting a field such as `a, b: int` that declares it with other names.
retype_param :: proc(changes: ^Changes, document: ^Document, param: Param_Name, type: string) {
	field := param.field
	if len(field.names) == 1 {
		append_edit(changes, document, field.type.pos.offset, field.type.end.offset, type)
		return
	}
	src := document.ast.src
	sb := strings.builder_make(context.temp_allocator)
	for name, i in field.names {
		if i > 0 do strings.write_string(&sb, ", ")
		written := type if name == param.name else node_text(src, field.type)
		fmt.sbprintf(&sb, "%s: %s", node_text(src, name), written)
	}
	append_edit(changes, document, field.names[0].pos.offset, field.type.end.offset, strings.to_string(sb))
}

// Whether `&arg` points at the memory that arg names, in a call in document: a variable, a field or element of one,
// or a dereference. A parameter, a constant, a call result and a map element are not.
addressable :: proc(document: ^Document, arg: ^ast.Expr) -> bool {
	text := document.text[:document.used_text]
	position := common.get_relative_token_position(arg.pos.offset, text, 0)
	position_context, ok := get_document_position_context(document, position, .Hover)
	if !ok {
		return false
	}
	ast_context := make_ast_context(
		document.ast,
		document.imports,
		document.package_name,
		document.uri.uri,
		document.fullpath,
		context.temp_allocator,
	)
	get_globals(document.ast, &ast_context)
	get_locals(&ast_context, &position_context)
	postfix := Postfix_Context {
		ast_context      = &ast_context,
		position_context = &position_context,
	}
	return addressing(&postfix, arg) == .Variable
}
