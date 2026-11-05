#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:strings"

import "src:common"

// On the name of a top-level procedure `foo_a`: "Make group foo" declares `foo :: proc{foo_a, foo_b}` over the
// procedures of the file named with the prefix before the last `_`, and "Add to group foo" adds the procedure to a group
// `foo` of the package that lacks it.
@(private = "package")
add_proc_group_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_proc_group {
		return
	}
	decl, found := top_decl_at(ctx.document, ctx.range.start)
	if !found || !is_proc_constant(decl) {
		return
	}
	name := final_name(decl.names[0])
	cut := strings.last_index_byte(name, '_')
	if cut <= 0 {
		return
	}
	prefix := name[:cut]
	// A group named like a builtin such as `make` would take every call of the builtin in the package.
	if !is_plain_name(prefix) {
		return
	}
	if _, builtin := lookup(prefix, "$builtin", ctx.document.fullpath); builtin {
		return
	}

	if group, group_document, group_decl, has_group := find_group(ctx, prefix); has_group {
		add_to_group(ctx, decl, group, group_document, group_decl, prefix)
		return
	}

	members := make([dynamic]^ast.Value_Decl, context.temp_allocator)
	for stmt in ctx.document.ast.decls {
		sibling := stmt.derived.(^ast.Value_Decl) or_continue
		if !is_proc_constant(sibling) {
			continue
		}
		sibling_name := final_name(sibling.names[0])
		if sibling_cut := strings.last_index_byte(sibling_name, '_');
		   sibling_cut == cut && sibling_name[:cut] == prefix {
			append(&members, sibling)
		}
	}
	if len(members) < 2 {
		return
	}
	// A group of two procedures with the same parameter types does not compile, and a call of it is ambiguous.
	keys := make([dynamic]string, context.temp_allocator)
	names := make([dynamic]string, context.temp_allocator)
	for member in members {
		key := params_key(member.values[0].derived.(^ast.Proc_Lit).type.params)
		for other in keys {
			if other == key {
				return
			}
		}
		append(&keys, key)
		append(&names, final_name(member.names[0]))
	}
	text := fmt.tprintf("%s :: proc{{%s}}", prefix, strings.join(names[:], ", ", context.temp_allocator))
	add_generated(ctx, members[len(members) - 1], fmt.tprintf("Make group %s", prefix), prefix, text)
}

// A file-scope constant holding one procedure literal.
is_proc_constant :: proc(decl: ^ast.Value_Decl) -> bool {
	if decl.is_mutable || len(decl.names) != 1 || len(decl.values) != 1 {
		return false
	}
	_, is_proc := decl.values[0].derived.(^ast.Proc_Lit)
	return is_proc
}

// The parameter types of a procedure as text, one per parameter, so that two procedures with the same key take the
// same arguments.
params_key :: proc(params: ^ast.Field_List) -> string {
	if params == nil {
		return ""
	}
	sb := strings.builder_make(context.temp_allocator)
	for field in params.list {
		type :=
			node_to_string(field.type) if field.type != nil else fmt.tprintf("= %s", node_to_string(field.default_value))
		for _ in field.names {
			fmt.sbprintf(&sb, "%s;", type)
		}
	}
	return strings.to_string(sb)
}

// The group named name at file scope of the package, with its document and declaration.
find_group :: proc(
	ctx: ^ActionContext,
	name: string,
) -> (
	group: ^ast.Proc_Group,
	document: ^Document,
	decl: ^ast.Value_Decl,
	ok: bool,
) {
	h := Call_Hierarchy{ctx.files, make(map[string]^Document, context.temp_allocator)}
	h.documents[ctx.document.uri.uri] = ctx.document
	for candidate in package_documents(&h, ctx.document, name, false) {
		for stmt in candidate.ast.decls {
			value := stmt.derived.(^ast.Value_Decl) or_continue
			if len(value.names) != 1 || len(value.values) != 1 || final_name(value.names[0]) != name {
				continue
			}
			found := value.values[0].derived.(^ast.Proc_Group) or_continue
			return found, candidate, value, true
		}
	}
	return
}

add_to_group :: proc(
	ctx: ^ActionContext,
	decl: ^ast.Value_Decl,
	group: ^ast.Proc_Group,
	group_document: ^Document,
	group_decl: ^ast.Value_Decl,
	prefix: string,
) {
	name := final_name(decl.names[0])
	// A group in another file cannot name a procedure private to this one.
	if group_document != ctx.document && file_private(ctx.document, decl) {
		return
	}
	lit := decl.values[0].derived.(^ast.Proc_Lit)
	key := params_key(lit.type.params)
	for arg in group.args {
		member, is_ident := arg.derived.(^ast.Ident)
		if !is_ident {
			return
		}
		if member.name == name {
			return
		}
		other, known := member_key(ctx, member.name)
		if !known || other == key {
			return
		}
	}

	// A call of the group that the procedure could take may pick it instead of the member it calls now.
	required, total := arity(lit.type.params)
	h := Call_Hierarchy{ctx.files, make(map[string]^Document, context.temp_allocator)}
	h.documents[ctx.document.uri.uri] = ctx.document
	for location in group_references(ctx, group_document, group_decl, prefix) {
		document := hierarchy_document(&h, location.uri)
		if document == nil {
			return
		}
		call, offset_ok := call_at_reference(document, location)
		if !offset_ok {
			return
		}
		if call != nil && (call.ellipsis.kind != .Invalid || required <= len(call.args) && len(call.args) <= total) {
			return
		}
	}

	changes := make(Changes, context.temp_allocator)
	append_list_item(&changes, group_document, group.args, group.close.offset, name)
	append(
		ctx.actions,
		CodeAction {
			title = fmt.tprintf("Add to group %s", prefix),
			kind = "refactor.rewrite",
			edit = workspace_edit(changes),
		},
	)
}

// The params_key of the package procedure named name, from the open document or the index.
member_key :: proc(ctx: ^ActionContext, name: string) -> (key: string, ok: bool) {
	if global, is_global := ctx.ast_context.globals[name]; is_global {
		lit := global.expr.derived.(^ast.Proc_Lit) or_return
		return params_key(lit.type.params), true
	}
	symbol := lookup(name, ctx.document.package_name, ctx.document.fullpath) or_return
	value := symbol.value.(SymbolProcedureValue) or_return
	list := ast.Field_List {
		list = value.arg_types,
	}
	return params_key(&list), true
}

// The fewest and the most arguments a call of a procedure with params takes. A variadic parameter takes any number.
arity :: proc(params: ^ast.Field_List) -> (required, total: int) {
	if params == nil {
		return
	}
	for field in params.list {
		if field.type != nil {
			if _, variadic := field.type.derived.(^ast.Ellipsis); variadic {
				return required, max(int)
			}
		}
		total += len(field.names)
		if field.default_value == nil {
			required += len(field.names)
		}
	}
	return
}

// Every reference to the group outside its declaration, in the open document and the rest of the workspace.
group_references :: proc(
	ctx: ^ActionContext,
	document: ^Document,
	decl: ^ast.Value_Decl,
	name: string,
) -> []common.Location {
	ast_context := make_ast_context(
		ctx.document.ast,
		ctx.document.imports,
		ctx.document.package_name,
		ctx.document.uri.uri,
		ctx.document.fullpath,
		context.temp_allocator,
	)
	get_globals(ctx.document.ast, &ast_context)
	symbol := Symbol {
		uri   = document.uri.uri,
		range = common.get_token_range(decl.names[0], document.ast.src),
		pkg   = document.package_name,
		name  = name,
	}
	locations, _ := find_symbol_references(
		ctx.document,
		&ast_context,
		symbol,
		.Identifier,
		include_declaration = false,
		target_name = name,
		files = ctx.files,
	)
	return locations
}
