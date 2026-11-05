#+private file

package server

import "core:odin/ast"
import "core:os"
import "core:strings"

import "src:common"

// The inverse of "Lift using": `using a.b` goes, and each name it promotes in the rest of the block becomes `a.b.x`.
// A `using` struct field becomes `#subtype`, which keeps the conversion to the embedded type and drops the promotion.
@(private = "package")
add_expand_using_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_expand_using {
		return
	}
	add_expand_statement(ctx)
	add_convert_field(ctx)
}

add_expand_statement :: proc(ctx: ^ActionContext) {
	stmts, index, found := stmt_at_range(ctx)
	if !found {
		return
	}
	stmt, is_using := stmts[index].derived.(^ast.Using_Stmt)
	if !is_using || len(stmt.list) != 1 {
		return
	}
	path := stmt.list[0]
	if path_root(path) == nil || in_when_body(ctx.position_context.function.body, stmt.pos.offset) {
		return
	}
	src := ctx.document.ast.src
	// The statement goes with its whole line, so it must have the line to itself.
	line_start, _ := before_on_line(src, stmt.pos.offset)
	line_end := stmt.end.offset + (strings.index_byte(src[stmt.end.offset:], '\n') %% (len(src) + 1))
	if strings.trim_space(src[line_start:stmt.pos.offset]) != "" ||
	   strings.trim_space(src[stmt.end.offset:min(line_end, len(src))]) != "" {
		return
	}
	// using_fields fails on an import, a type, a value of no struct type and a `using` field it cannot resolve.
	fields, is_struct := using_fields(ctx, resolve_entire_file(ctx.document), path)
	if !is_struct {
		return
	}
	edits, ok := qualify_edits(ctx, fields, stmts[index + 1:], path)
	if !ok {
		return
	}
	append(&edits, delete_lines_edit(ctx, stmt.pos.line - 1, stmt.end.line - 1))
	append(ctx.actions, make_code_action(ctx, "Expand using", "refactor.rewrite", edits[:]))
}

// An edit that adds the path before each promoted name in rest. It fails when a name cannot be told to be promoted, or
// when the root of the path means something else at a use.
qualify_edits :: proc(
	ctx: ^ActionContext,
	fields: map[string]struct{},
	rest: []^ast.Stmt,
	path: ^ast.Expr,
) -> (
	edits: [dynamic]TextEdit,
	ok: bool,
) {
	symbols := resolve_entire_file_for_references(ctx.document, context.temp_allocator, .Identifier, "")
	root := path_root(path)
	root_decl, root_local := local_decl_offset(ctx, symbols, root)
	prefix := strings.concatenate({strip_space(node_text(ctx.document.ast.src, path)), "."}, context.temp_allocator)

	edits = make([dynamic]TextEdit, context.temp_allocator)
	for stmt in rest {
		if stmt == nil {
			continue
		}
		for use in collect_ident_uses(stmt) {
			// A nested procedure sees no local `using`.
			if in_proc_lit(use) {
				continue
			}
			// A `using` in a nested scope can take a promoted name over. One in the same scope cannot, as the compiler
			// refuses a name that both bring in.
			if under_using(use) && !is_stmt_of_list(use) {
				return
			}
			if use.ident.name == root.name && !is_member_name(use) {
				decl, local := local_decl_offset(ctx, symbols, use.ident)
				if local != root_local || (local && decl != root_decl) {
					return
				}
			}
			if use.ident.name not_in fields {
				continue
			}
			if is_member_name(use) {
				if is_index_key(ctx, use) {
					return
				}
				continue
			}
			if declares_name(use) {
				continue
			}
			resolved, known := symbols[uintptr(use.ident)]
			if !known {
				return
			}
			if .Local in resolved.symbol.flags {
				continue
			}
			at := use.ident.pos.offset
			append(&edits, TextEdit{range = range_of(ctx, at, at), newText = prefix})
		}
	}
	return edits, true
}

in_proc_lit :: proc(use: IdentUse) -> bool {
	for parent in use.parents {
		if _, is_proc := parent.derived.(^ast.Proc_Lit); is_proc {
			return true
		}
	}
	return false
}

// Whether the `using` above this use is itself a statement of the list being scanned.
is_stmt_of_list :: proc(use: IdentUse) -> bool {
	#partial switch p in use.parents[0].derived {
	case ^ast.Using_Stmt:
		return true
	case ^ast.Value_Decl:
		return p.is_using
	}
	return false
}

// The name a declaration introduces: `x` in `x := x`, or a loop or a switch variable. The value in the same statement
// still reads the promoted name, and the resolver places the name's scope after the statement.
declares_name :: proc(use: IdentUse) -> bool {
	parent := use.parents[len(use.parents) - 1]
	#partial switch p in parent.derived {
	case ^ast.Value_Decl:
		for name in p.names {
			if name == use.ident {
				return true
			}
		}
	case ^ast.Range_Stmt:
		for value in p.vals {
			if value == use.ident {
				return true
			}
		}
	}
	return false
}

add_convert_field :: proc(ctx: ^ActionContext) {
	start, end := trim_selection(ctx.document.ast.src, ctx.range.start, ctx.range.end)
	field, keyword := using_field_at(ctx, start, end)
	if field == nil {
		return
	}
	ident, is_ident := field.names[0].derived.(^ast.Ident)
	if !is_ident || ident.name == "_" {
		return
	}
	reset_ast_context(ctx.ast_context)
	embedded, resolved := resolve_type_expression(ctx.ast_context, field.type)
	if !resolved {
		return
	}
	// A member that the embedded type itself promotes has a range in a third type, so the search below would miss uses.
	value, is_struct := embedded.value.(SymbolStructValue)
	if !is_struct || len(value.usings) > 0 || has_promoted_use(ctx, embedded, value) {
		return
	}
	append_replace_range(ctx, keyword, keyword + len("using"), "Convert using to #subtype", "#subtype")
}

// The `using` field at the range, with the offset of its keyword: the node of a field starts at its name.
using_field_at :: proc(ctx: ^ActionContext, start, end: int) -> (field: ^ast.Field, keyword: int) {
	src := ctx.document.ast.src
	#reverse for at in nodes_at(ctx.document.ast.decls[:], start) {
		type, is_struct := at.node.derived.(^ast.Struct_Type)
		if !is_struct {
			continue
		}
		if type.fields == nil {
			return nil, 0
		}
		for f in type.fields.list {
			if .Subtype in f.flags {
				// A struct takes one #subtype field.
				return nil, 0
			}
		}
		for f in type.fields.list {
			if .Using not_in f.flags || len(f.names) != 1 || f.type == nil {
				continue
			}
			before := strings.trim_right_space(src[:f.names[0].pos.offset])
			if strings.has_suffix(before, "using") && len(before) - len("using") <= start && end <= f.type.end.offset {
				return f, len(before) - len("using")
			}
		}
		return nil, 0
	}
	return nil, 0
}

// Whether a file of the workspace reaches a member of the embedded type other than through a value of that type.
has_promoted_use :: proc(ctx: ^ActionContext, embedded: Symbol, value: SymbolStructValue) -> bool {
	h := Call_Hierarchy{ctx.files, make(map[string]^Document, context.temp_allocator)}
	h.documents[ctx.uri] = ctx.document

	sources := make([dynamic]Package_File, context.temp_allocator)
	append(&sources, Package_File{fullpath = ctx.document.fullpath, text = ctx.document.ast.src})
	for file in workspace_odin_files(ctx.document.fullpath, ctx.files) {
		append(&sources, file)
	}
	for source in sources {
		text := source.text
		if text == "" {
			data, err := os.read_entire_file(source.fullpath, context.temp_allocator)
			if err != nil {
				return true
			}
			text = string(data)
		}
		for name, i in value.names {
			if name == "_" || !strings.contains(text, name) {
				continue
			}
			document := hierarchy_document(&h, common.create_uri(source.fullpath, context.temp_allocator).uri)
			if document == nil {
				return true
			}
			symbols := resolve_entire_file_for_references(document, context.temp_allocator, .Field, name)
			for _, found in symbols {
				// The uri can name the file of the struct that embeds the field, so only the range is compared.
				if found.symbol.range == value.ranges[i] && promoted_at(document, found.node, embedded) {
					return true
				}
			}
		}
	}
	return false
}

// Whether the member name at node comes through anything but a value or a literal of the embedded type itself.
promoted_at :: proc(document: ^Document, node: ^ast.Node, embedded: Symbol) -> bool {
	nodes := nodes_at(document.ast.decls[:], node.pos.offset)
	parent := parent_of_node(nodes, node)
	if parent == nil {
		return true
	}
	position := common.get_relative_token_position(node.pos.offset, document.text[:document.used_text], 0)
	ast_context: AstContext
	position_context: DocumentPositionContext
	if !ast_context_at(document, position, &ast_context, &position_context) {
		return true
	}
	base: ^ast.Expr
	#partial switch p in parent.derived {
	case ^ast.Field:
		// The member's own declaration.
		return false
	case ^ast.Selector_Expr:
		base = p.expr
	case ^ast.Field_Value:
		// A field's own declaration has no such parent, and a key names the type of its literal.
		literal := parent_of_node(nodes, parent)
		if literal == nil {
			return true
		}
		lit, is_lit := literal.derived.(^ast.Comp_Lit)
		if !is_lit || lit.type == nil {
			return true
		}
		base = lit.type
	case:
		// A bare name, which a `using` of a value of the embedded type brings in as well.
		ident, is_ident := node.derived.(^ast.Ident)
		if !is_ident {
			return true
		}
		local, is_local := get_local(ast_context, ident^)
		if !is_local || !is_using_local(local) {
			return true
		}
		base = local.rhs.derived.(^ast.Selector_Expr).expr
	}
	reset_ast_context(&ast_context)
	symbol, ok := resolve_type_expression(&ast_context, base)
	return !ok || symbol.name != embedded.name || symbol.pkg != embedded.pkg || symbol.range != embedded.range
}

parent_of_node :: proc(nodes: []Node_At, node: ^ast.Node) -> ^ast.Node {
	for at in nodes {
		if at.node == node {
			return at.parent
		}
	}
	return nil
}
