package server

import "core:encoding/json"
import "core:odin/ast"
import "core:os"
import "core:strings"

import "src:common"

// Documents parsed for one request, keyed by uri. files are in-memory sources for the tests; without
// them open documents are used and the rest is read from disk.
Call_Hierarchy :: struct {
	files:     []Package_File,
	documents: map[string]^Document,
}

prepare_call_hierarchy :: proc(
	document: ^Document,
	position: common.Position,
	files: []Package_File = {},
) -> []CallHierarchyItem {
	h := Call_Hierarchy{files, make(map[string]^Document, context.temp_allocator)}

	symbol, ok := symbol_at(document, position)
	if !ok || .Local in symbol.flags {
		return {}
	}
	target := hierarchy_document(&h, symbol.uri)
	if target == nil {
		return {}
	}
	decl, found := find_decl(target, symbol.range)
	if !found || !is_proc_decl(decl) {
		return {}
	}
	items := make([]CallHierarchyItem, 1, context.temp_allocator)
	items[0] = decl_item(target, decl)
	return items
}

incoming_calls :: proc(item: CallHierarchyItem, files: []Package_File = {}) -> []CallHierarchyIncomingCall {
	h := Call_Hierarchy{files, make(map[string]^Document, context.temp_allocator)}

	document := hierarchy_document(&h, item.uri)
	if document == nil {
		return {}
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

	symbol := Symbol {
		uri   = item.uri,
		range = item.selectionRange,
		pkg   = document.package_name,
		name  = item.name,
	}
	locations, _ := find_symbol_references(
		document,
		&ast_context,
		symbol,
		.Identifier,
		include_declaration = false,
		target_name = item.name,
		files = files,
	)

	calls := make([dynamic]CallHierarchyIncomingCall, context.temp_allocator)
	ranges := make([dynamic][dynamic]common.Range, context.temp_allocator)
	index := make(map[common.Location]int, context.temp_allocator)

	for location in locations {
		caller := hierarchy_document(&h, location.uri)
		if caller == nil {
			continue
		}
		decl, found := decl_containing(caller, location.range.start)
		if !found {
			continue
		}
		from := decl_item(caller, decl)
		key := common.Location{from.uri, from.selectionRange}
		i, seen := index[key]
		if !seen {
			i = len(calls)
			index[key] = i
			append(&calls, CallHierarchyIncomingCall{from = from})
			append(&ranges, make([dynamic]common.Range, context.temp_allocator))
		}
		append(&ranges[i], location.range)
	}

	for &call, i in calls {
		call.fromRanges = ranges[i][:]
	}
	return calls[:]
}

outgoing_calls :: proc(item: CallHierarchyItem, files: []Package_File = {}) -> []CallHierarchyOutgoingCall {
	h := Call_Hierarchy{files, make(map[string]^Document, context.temp_allocator)}

	document := hierarchy_document(&h, item.uri)
	if document == nil {
		return {}
	}
	decl, found := find_decl(document, item.selectionRange)
	if !found {
		return {}
	}

	src := string(document.text[:document.used_text])
	hits := resolve_entire_file_for_references(document, context.temp_allocator, .Identifier, "")

	calls := make([dynamic]CallHierarchyOutgoingCall, context.temp_allocator)
	ranges := make([dynamic][dynamic]common.Range, context.temp_allocator)
	index := make(map[common.Location]int, context.temp_allocator)

	for callee in call_targets(decl) {
		hit := hits[cast(uintptr)callee] or_continue
		if .Local in hit.symbol.flags || is_ols_builtin_file(hit.symbol.uri) {
			continue
		}
		target := hierarchy_document(&h, hit.symbol.uri)
		if target == nil {
			continue
		}
		target_decl, found := find_decl(target, hit.symbol.range)
		if !found || !is_proc_decl(target_decl) {
			continue
		}
		key := common.Location{hit.symbol.uri, hit.symbol.range}
		i, seen := index[key]
		if !seen {
			i = len(calls)
			index[key] = i
			append(&calls, CallHierarchyOutgoingCall{to = decl_item(target, target_decl)})
			append(&ranges, make([dynamic]common.Range, context.temp_allocator))
		}
		append(&ranges[i], common.get_token_range(hit.node^, src))
	}

	for &call, i in calls {
		call.fromRanges = ranges[i][:]
	}
	return calls[:]
}

symbol_at :: proc(document: ^Document, position: common.Position) -> (symbol: Symbol, ok: bool) {
	ast_context := make_ast_context(
		document.ast,
		document.imports,
		document.package_name,
		document.uri.uri,
		document.fullpath,
		context.temp_allocator,
	)

	position_context := get_document_position_context(document, position, .Hover) or_return

	ast_context.position_hint = position_context.hint
	ast_context.current_package = ast_context.document_package

	get_globals(document.ast, &ast_context)
	get_locals(&ast_context, &position_context)

	symbol, _ = prepare_references(document, &ast_context, &position_context) or_return
	return symbol, true
}

hierarchy_document :: proc(h: ^Call_Hierarchy, uri: string) -> ^Document {
	if document, ok := h.documents[uri]; ok {
		return document
	}

	document: ^Document
	defer h.documents[uri] = document

	if parsed, ok := common.parse_uri(uri, context.temp_allocator); ok {
		if open := &document_storage.documents[parsed.path]; open != nil && open.client_owned {
			document = open
			return document
		}
	}

	fullpath := common.uri_to_path(uri, context.temp_allocator)
	text: string
	for file in h.files {
		if file.fullpath == fullpath {
			text = file.text
		}
	}
	if text == "" {
		data, err := os.read_entire_file(fullpath, context.temp_allocator)
		if err != nil {
			return nil
		}
		text = string(data)
	}

	context.allocator = context.temp_allocator
	if parsed, ok := parse_package_file({fullpath, text}, &common.config); ok {
		document = new_clone(parsed)
	}
	return document
}

// Value declarations at file scope, including those under `when` and in foreign blocks.
@(private = "file")
top_level_value_decls :: proc(file: ast.File) -> []^ast.Value_Decl {
	decls := make([dynamic]^ast.Value_Decl, context.temp_allocator)
	for decl in file.decls do collect(decl, &decls)
	return decls[:]

	collect :: proc(stmt: ^ast.Stmt, decls: ^[dynamic]^ast.Value_Decl) {
		if stmt == nil do return
		#partial switch s in stmt.derived {
		case ^ast.Value_Decl:
			append(decls, s)
		case ^ast.When_Stmt:
			collect(s.body, decls)
			collect(s.else_stmt, decls)
		case ^ast.Block_Stmt:
			for inner in s.stmts do collect(inner, decls)
		case ^ast.Foreign_Block_Decl:
			collect(s.body, decls)
		}
	}
}

// The declaration whose first name spans name_range.
find_decl :: proc(document: ^Document, name_range: common.Range) -> (^ast.Value_Decl, bool) {
	src := string(document.text[:document.used_text])
	for decl in top_level_value_decls(document.ast) {
		if len(decl.names) > 0 && common.get_token_range(decl.names[0], src) == name_range {
			return decl, true
		}
	}
	return nil, false
}

@(private = "file")
decl_containing :: proc(document: ^Document, position: common.Position) -> (decl: ^ast.Value_Decl, ok: bool) {
	offset := common.get_absolute_position(position, document.text[:document.used_text]) or_return
	for decl in top_level_value_decls(document.ast) {
		if len(decl.names) > 0 && decl.pos.offset <= offset && offset < decl.end.offset {
			return decl, true
		}
	}
	return nil, false
}

@(private = "file")
is_proc_decl :: proc(decl: ^ast.Value_Decl) -> bool {
	if len(decl.values) != 1 do return false
	#partial switch v in decl.values[0].derived {
	case ^ast.Proc_Lit, ^ast.Proc_Group:
		return true
	}
	return false
}

@(private = "file")
decl_item :: proc(document: ^Document, decl: ^ast.Value_Decl) -> CallHierarchyItem {
	src := string(document.text[:document.used_text])
	item := CallHierarchyItem {
		name           = get_ast_node_string(decl.names[0], src),
		kind           = .Variable if decl.is_mutable else .Constant,
		uri            = document.uri.uri,
		range          = common.get_token_range(decl, src),
		selectionRange = common.get_token_range(decl.names[0], src),
	}
	if len(decl.values) == 1 {
		#partial switch v in decl.values[0].derived {
		case ^ast.Proc_Lit:
			item.kind = .Function
			words := strings.fields(get_ast_node_string(v.type, src), context.temp_allocator)
			item.detail = strings.join(words, " ", context.temp_allocator)
		case ^ast.Proc_Group:
			item.kind = .Function
			item.detail = "proc group"
		}
	}
	return item
}

// Callee expressions of every call in a procedure body, or the members of a procedure group.
@(private = "file")
call_targets :: proc(decl: ^ast.Value_Decl) -> []^ast.Expr {
	targets := make([dynamic]^ast.Expr, context.temp_allocator)
	if len(decl.values) != 1 do return {}

	#partial switch v in decl.values[0].derived {
	case ^ast.Proc_Group:
		append(&targets, ..v.args)
	case ^ast.Proc_Lit:
		visitor := ast.Visitor {
			data = &targets,
			visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
				if node == nil do return nil
				if call, ok := node.derived.(^ast.Call_Expr); ok {
					callee := call.expr
					for {
						paren := callee.derived.(^ast.Paren_Expr) or_break
						callee = paren.expr
					}
					append((^[dynamic]^ast.Expr)(visitor.data), callee)
				}
				return visitor
			},
		}
		ast.walk(&visitor, v.body)
	}
	return targets[:]
}

request_prepare_call_hierarchy :: proc(
	params: json.Value,
	id: RequestId,
	config: ^common.Config,
	writer: ^Writer,
) -> common.Error {
	prepare_params: CallHierarchyPrepareParams
	if unmarshal(params, prepare_params, context.temp_allocator) != nil {
		return .ParseError
	}

	document := document_get(prepare_params.textDocument.uri)
	if document == nil {
		return .InternalError
	}

	items := prepare_call_hierarchy(document, prepare_params.position)
	send_response(make_response_message(params = items, id = id), writer)
	return .None
}

request_incoming_calls :: proc(
	params: json.Value,
	id: RequestId,
	config: ^common.Config,
	writer: ^Writer,
) -> common.Error {
	calls_params: CallHierarchyCallsParams
	if unmarshal(params, calls_params, context.temp_allocator) != nil {
		return .ParseError
	}

	calls := incoming_calls(calls_params.item)
	send_response(make_response_message(params = calls, id = id), writer)
	return .None
}

request_outgoing_calls :: proc(
	params: json.Value,
	id: RequestId,
	config: ^common.Config,
	writer: ^Writer,
) -> common.Error {
	calls_params: CallHierarchyCallsParams
	if unmarshal(params, calls_params, context.temp_allocator) != nil {
		return .ParseError
	}

	calls := outgoing_calls(calls_params.item)
	send_response(make_response_message(params = calls, id = id), writer)
	return .None
}
