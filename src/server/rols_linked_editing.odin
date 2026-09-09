package server

import "core:encoding/json"
import "core:strings"

import "src:common"

request_linked_editing_range :: proc(
	params: json.Value,
	id: RequestId,
	config: ^common.Config,
	writer: ^Writer,
) -> common.Error {
	if _, ok := params.(json.Object); !ok do return .ParseError

	linked_params: LinkedEditingRangeParams
	if unmarshal(params, linked_params, context.temp_allocator) != nil do return .ParseError

	document := document_get(linked_params.textDocument.uri)
	if document == nil do return .InternalError

	response: ResponseMessage
	if ranges, ok := get_linked_editing_ranges(document, linked_params.position, config); ok {
		response = make_response_message(
			params = LinkedEditingRanges{ranges = ranges, wordPattern = "[A-Za-z_][A-Za-z0-9_]*"},
			id = id,
		)
	} else {
		response = make_response_message(params = nil, id = id)
	}
	send_response(response, writer)

	return .None
}

// Occurrences of the local or parameter under the cursor, declaration included. Anything wider than one
// function body is a rename, not a linked edit, so globals and fields report nothing.
get_linked_editing_ranges :: proc(
	document: ^Document,
	position: common.Position,
	config: ^common.Config,
) -> (
	[]common.Range,
	bool,
) {
	if !config.enable_linked_editing do return {}, false

	ast_context := make_ast_context(
		document.ast,
		document.imports,
		document.package_name,
		document.uri.uri,
		document.fullpath,
		context.temp_allocator,
	)

	position_context, ok := get_document_position_context(document, position, .Hover)
	if !ok do return {}, false

	ast_context.position_hint = position_context.hint
	ast_context.current_package = ast_context.document_package

	get_globals(document.ast, &ast_context)
	get_locals(&ast_context, &position_context)

	symbol, resolve_flag, found := prepare_references(document, &ast_context, &position_context)
	if !found do return {}, false
	if symbol.flags & {.Local, .Parameter} == {} do return {}, false
	if !strings.equal_fold(symbol.uri, document.uri.uri) do return {}, false

	locations, located := find_symbol_references(
		document,
		&ast_context,
		symbol,
		resolve_flag,
		current_file_only = true,
		target_name = get_target_name(&position_context, resolve_flag),
	)
	if !located || len(locations) == 0 do return {}, false

	ranges := make([dynamic]common.Range, 0, len(locations), context.temp_allocator)
	for location in locations do append(&ranges, location.range)

	return ranges[:], true
}
