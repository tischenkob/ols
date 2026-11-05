#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:os"
import "core:slice"
import "core:strings"

import "src:common"

// "Create field" on `x.foo` when x is a struct of the workspace, and "Create enum member" on `.Foo` when the expected enum
// is. A member that exists costs one lookup here.
@(private = "package")
add_create_member_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_create_member {
		return
	}
	nodes := nodes_at(ctx.document.ast.decls[:], ctx.range.start)
	if len(nodes) == 0 {
		return
	}
	at := nodes[len(nodes) - 1]
	if implicit, is_implicit := at.node.derived.(^ast.Implicit_Selector_Expr); is_implicit {
		add_create_enum_member(ctx, nodes, implicit)
		return
	}
	if at.parent == nil || ctx.range.end > at.node.end.offset {
		return
	}
	#partial switch p in at.parent.derived {
	case ^ast.Implicit_Selector_Expr:
		add_create_enum_member(ctx, nodes, p)
	case ^ast.Selector_Expr:
		if p.field == at.node && p.op.kind == .Period {
			add_create_field(ctx, nodes, p)
		}
	}
}

add_create_field :: proc(ctx: ^ActionContext, nodes: []Node_At, selector: ^ast.Selector_Expr) {
	reset_ast_context(ctx.ast_context)
	ctx.ast_context.use_locals = true
	symbol, resolved := resolve_type_expression(ctx.ast_context, selector.expr)
	if !resolved {
		return
	}
	value, is_struct := symbol.value.(SymbolStructValue)
	field := selector.field.name
	if !is_struct || slice.contains(value.names, field) || symbol.pointers > 1 || .Anonymous in symbol.flags {
		return
	}
	// `Foo.bar` names a type, which has no fields to reach.
	if root, is_ident := selector.expr.derived.(^ast.Ident);
	   is_ident && root.name == symbol.name && .Mutable not_in symbol.flags {
		return
	}

	target, decl_value, is_local := declaration_in_workspace(ctx, symbol)
	if target == nil {
		return
	}
	type_node, is_type := decl_value.derived.(^ast.Struct_Type)
	if !is_type || type_node.poly_params != nil {
		return
	}

	imports := make([dynamic]TextEdit, context.temp_allocator)
	type, known := received_type(ctx, nodes, selector, &imports)
	if !known {
		return
	}
	fields := make([dynamic]string, context.temp_allocator)
	append(&fields, field)
	append(&fields, ..value.names)
	if type_names_clash(type, fields[:]) ||
	   !type_reaches(ctx, target, decl_value, is_local, symbol.pkg, type, imports[:]) {
		return
	}
	if holds_positional_literal(ctx, symbol.name) {
		return
	}

	changes := make(Changes, context.temp_allocator)
	for edit in imports {
		edits := &changes[ctx.document.uri.uri]
		if edits == nil {
			changes[ctx.document.uri.uri] = make([dynamic]TextEdit, context.temp_allocator)
			edits = &changes[ctx.document.uri.uri]
		}
		append(edits, edit)
	}
	list := type_node.fields.list
	close := type_node.end.offset - 1
	text := fmt.tprintf("%s: %s", field, type)
	if len(list) == 0 {
		append_brace_item(&changes, target, type_node.pos.offset, close, nil, -1, text)
	} else {
		last := list[len(list) - 1]
		end := last.type.end.offset if last.type != nil else last.end.offset
		if last.tag.text != "" {
			end = last.tag.pos.offset + len(last.tag.text)
		}
		append_brace_item(&changes, target, type_node.pos.offset, close, last, end, text)
	}
	append(
		ctx.actions,
		CodeAction{title = fmt.tprintf("Create field %s", field), kind = "quickfix", edit = workspace_edit(changes)},
	)
}

add_create_enum_member :: proc(ctx: ^ActionContext, nodes: []Node_At, selector: ^ast.Implicit_Selector_Expr) {
	if selector.field == nil {
		return
	}
	reset_ast_context(ctx.ast_context)
	ctx.ast_context.use_locals = true
	symbol, resolved := resolve_implicit_selector(ctx.ast_context, ctx.position_context)
	if !resolved {
		// The resolver leaves out some places that name their type, such as a typed declaration.
		expected, has_expected := expected_of(ctx, nodes, selector)
		if !has_expected {
			return
		}
		symbol = expected.symbol
	}
	// An element of a bit set literal resolves to the set.
	if set, is_set := symbol.value.(SymbolBitSetValue); is_set {
		element, element_ok := type_at(ctx, set.expr, symbol.pkg)
		if !element_ok {
			return
		}
		symbol = element.symbol
	}
	value, is_enum := symbol.value.(SymbolEnumValue)
	member := selector.field.name
	if !is_enum || slice.contains(value.names, member) || .Anonymous in symbol.flags {
		return
	}
	target, decl_value, _ := declaration_in_workspace(ctx, symbol)
	if target == nil {
		return
	}
	type_node, is_type := decl_value.derived.(^ast.Enum_Type)
	if !is_type || leaves_out_member(ctx, symbol.name, value.names, member) {
		return
	}

	changes := make(Changes, context.temp_allocator)
	list := type_node.fields
	close := type_node.end.offset - 1
	if len(list) == 0 {
		append_brace_item(&changes, target, type_node.pos.offset, close, nil, -1, member)
	} else {
		last := list[len(list) - 1]
		append_brace_item(&changes, target, type_node.pos.offset, close, last, last.end.offset, member)
	}
	append(
		ctx.actions,
		CodeAction {
			title = fmt.tprintf("Create enum member %s", member),
			kind = "quickfix",
			edit = workspace_edit(changes),
		},
	)
}

// The document that declares symbol and the value of that declaration, when the file belongs to the workspace. A symbol
// from the index has the range of the name, and one from the open document's globals that of the value.
declaration_in_workspace :: proc(
	ctx: ^ActionContext,
	symbol: Symbol,
) -> (
	document: ^Document,
	value: ^ast.Expr,
	is_local: bool,
) {
	h := Call_Hierarchy{ctx.files, make(map[string]^Document, context.temp_allocator)}
	h.documents[ctx.uri] = ctx.document
	if symbol.uri != ctx.uri {
		fullpath := common.uri_to_path(symbol.uri, context.temp_allocator)
		in_workspace := false
		for file in workspace_odin_files(ctx.document.fullpath, ctx.files) {
			if same_path(file.fullpath, fullpath) {
				in_workspace = true
				break
			}
		}
		if !in_workspace {
			return nil, nil, false
		}
	}
	document = hierarchy_document(&h, symbol.uri)
	if document == nil {
		return nil, nil, false
	}

	Data :: struct {
		document: ^Document,
		symbol:   Symbol,
		value:    ^ast.Expr,
		is_local: bool,
	}
	data := Data {
		document = document,
		symbol   = symbol,
	}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil || data.value != nil {
				return nil
			}
			if decl, is_decl := node.derived.(^ast.Value_Decl); is_decl && len(decl.names) == len(decl.values) {
				src := data.document.ast.src
				for name, i in decl.names {
					ident, is_ident := name.derived.(^ast.Ident)
					if !is_ident || ident.name != data.symbol.name {
						continue
					}
					start := data.symbol.range.start
					if common.get_token_range(name, src).start == start ||
					   common.get_token_range(decl.values[i], src).start == start {
						data.value = decl.values[i]
						data.is_local = !slice.contains(data.document.ast.decls[:], decl)
						return nil
					}
				}
			}
			return visitor
		},
	}
	for decl in document.ast.decls {
		ast.walk(&visitor, decl)
	}
	if data.value == nil {
		return nil, nil, false
	}
	return document, data.value, data.is_local
}

// Whether the names of a type written for the cursor mean the same in a field of the declaration in target.
type_reaches :: proc(
	ctx: ^ActionContext,
	target: ^Document,
	decl_value: ^ast.Expr,
	is_local: bool,
	pkg: string,
	type: string,
	imports: []TextEdit,
) -> bool {
	if len(imports) > 0 {
		return target == ctx.document
	}
	if is_local {
		if !spelled_names_hold(ctx, position_ident(decl_value, ""), type, pkg) {
			return false
		}
	} else if !holds_at_file_scope(ctx, type, pkg) {
		return false
	}
	if target == ctx.document {
		return true
	}
	for word in type_words(type) {
		first, dot, _ := strings.partition(word, ".")
		if dot != "" {
			if !same_import(ctx.document, target, first) {
				return false
			}
			continue
		}
		if global, is_global := ctx.ast_context.globals[first]; is_global && global.private == .File {
			return false
		}
	}
	return true
}

// Whether target imports the package that from calls alias, under that alias.
same_import :: proc(from, target: ^Document, alias: string) -> bool {
	for imp in from.imports {
		if imp.base != alias {
			continue
		}
		for other in target.imports {
			if other.base == alias && other.name == imp.name {
				return true
			}
		}
	}
	return false
}

// Appends text as the last item of the braced list of the type that starts at start and closes at close. A list on one
// line stays on one line. last is the last item with its text ending at end, nil for an empty list.
append_brace_item :: proc(
	changes: ^Changes,
	document: ^Document,
	start, close: int,
	last: ^ast.Node,
	end: int,
	text: string,
) {
	src := document.ast.src
	if last == nil {
		// The parser leaves the open position of an empty field list at zero.
		open := start + strings.index_byte(src[start:close + 1], '{')
		if !strings.contains_rune(src[open:close], '\n') {
			append_edit(changes, document, open + 1, open + 1, text)
			return
		}
		ind := get_line_indentation(src, open)
		unit := indent_unit(src, ind, nil)
		item := fmt.tprintf("\n%s%s%s,", ind, unit, text)
		append_edit(changes, document, open + 1, open + 1, item)
		return
	}
	rest := src[end:close]
	spaces := len(rest) - len(strings.trim_left_space(rest))
	has_comma := strings.has_prefix(rest[spaces:], ",")
	after := end + spaces + 1 if has_comma else end
	if !strings.contains_rune(src[after:close], '\n') {
		if has_comma {
			append_edit(changes, document, after, after, fmt.tprintf(" %s", text))
		} else {
			append_edit(changes, document, end, end, fmt.tprintf(", %s", text))
		}
		return
	}
	if !has_comma {
		append_edit(changes, document, end, end, ",")
	}
	// A comment after the last item stays on its line.
	line_end := after + strings.index_byte(src[after:close], '\n')
	if line_end > after && src[line_end - 1] == '\r' {
		line_end -= 1
	}
	ind := get_line_indentation(src, last.pos.offset)
	append_edit(changes, document, line_end, line_end, fmt.tprintf("\n%s%s,", ind, text))
}

// The documents of the workspace files whose text holds one of words, and the open one. ok is false when a file cannot
// be read, as it could hold anything.
workspace_documents :: proc(ctx: ^ActionContext, words: ..string) -> (documents: []^Document, ok: bool) {
	h := Call_Hierarchy{ctx.files, make(map[string]^Document, context.temp_allocator)}
	h.documents[ctx.uri] = ctx.document
	found := make([dynamic]^Document, context.temp_allocator)
	append(&found, ctx.document)
	for file in workspace_odin_files(ctx.document.fullpath, ctx.files) {
		text := file.text
		if text == "" {
			data, err := os.read_entire_file(file.fullpath, context.temp_allocator)
			if err != nil {
				return nil, false
			}
			text = string(data)
		}
		holds := false
		for word in words {
			holds ||= strings.contains(text, word)
		}
		if !holds {
			continue
		}
		document := hierarchy_document(&h, common.create_uri(file.fullpath, context.temp_allocator).uri)
		if document == nil {
			return nil, false
		}
		append(&found, document)
	}
	return found[:], true
}

// Whether a written literal of the struct lists its values by position, which a new field leaves one short. A literal
// that takes its type from its place has no name to find here.
holds_positional_literal :: proc(ctx: ^ActionContext, name: string) -> bool {
	documents, ok := workspace_documents(ctx, name)
	if !ok {
		return true
	}
	Data :: struct {
		name:  string,
		found: bool,
	}
	data := Data {
		name = name,
	}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil || data.found {
				return nil
			}
			if lit, is_lit := node.derived.(^ast.Comp_Lit);
			   is_lit && lit.type != nil && names_type(lit.type, data.name) {
				for elem in lit.elems {
					if _, is_named := elem.derived.(^ast.Field_Value); !is_named {
						data.found = true
					}
				}
			}
			return visitor
		},
	}
	for document in documents {
		for decl in document.ast.decls {
			ast.walk(&visitor, decl)
		}
	}
	return data.found
}

// `Name` or `pkg.Name`.
names_type :: proc(node: ^ast.Expr, name: string) -> bool {
	#partial switch n in node.derived {
	case ^ast.Ident:
		return n.name == name
	case ^ast.Selector_Expr:
		return n.field != nil && n.field.name == name
	}
	return false
}

// Whether a new member would leave a place without it that must list every member: a switch without #partial that lists
// members of the enum, or a literal of an enumerated array without #partial. A switch is told by its case names, so a
// switch over another enum with a shared member name refuses too.
leaves_out_member :: proc(ctx: ^ActionContext, name: string, members: []string, member: string) -> bool {
	documents, ok := workspace_documents(ctx, "switch", name)
	if !ok {
		return true
	}
	Data :: struct {
		name:    string,
		members: []string,
		member:  string,
		found:   bool,
	}
	data := Data{name, members, member, false}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil || data.found {
				return nil
			}
			#partial switch n in node.derived {
			case ^ast.Switch_Stmt:
				if !n.partial && switch_misses_member(n, data.name, data.members, data.member) {
					data.found = true
				}
			case ^ast.Comp_Lit:
				if n.type == nil || n.tag != nil || len(n.elems) == 0 {
					break
				}
				if array, is_array := n.type.derived.(^ast.Array_Type); is_array && array.len != nil {
					data.found ||= names_type(array.len, data.name)
				}
			}
			return visitor
		},
	}
	for document in documents {
		for decl in document.ast.decls {
			ast.walk(&visitor, decl)
		}
	}
	return data.found
}

switch_misses_member :: proc(stmt: ^ast.Switch_Stmt, name: string, members: []string, member: string) -> bool {
	block, is_block := stmt.body.derived.(^ast.Block_Stmt)
	if !is_block {
		return false
	}
	lists_enum := false
	for clause in block.stmts {
		case_clause := clause.derived.(^ast.Case_Clause) or_continue
		for item in case_clause.list {
			#partial switch v in item.derived {
			case ^ast.Implicit_Selector_Expr:
				if v.field != nil {
					if v.field.name == member {
						return false
					}
					lists_enum ||= slice.contains(members, v.field.name)
				}
			case ^ast.Selector_Expr:
				if v.field != nil && names_type(v.expr, name) {
					if v.field.name == member {
						return false
					}
					lists_enum = true
				}
			}
		}
	}
	return lists_enum
}
