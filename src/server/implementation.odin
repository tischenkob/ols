package server

import "core:encoding/json"
import "core:odin/ast"

import "src:common"

// The members of a procedure group, or the procedure itself.
get_implementation_locations :: proc(
	document: ^Document,
	position: common.Position,
	files: []Package_File = {},
) -> []common.Location {
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
	if !found || len(decl.values) != 1 {
		return {}
	}

	locations := make([dynamic]common.Location, context.temp_allocator)
	#partial switch v in decl.values[0].derived {
	case ^ast.Proc_Lit:
		append(&locations, common.Location{symbol.uri, symbol.range})
	case ^ast.Proc_Group:
		hits := resolve_entire_file_for_references(target, context.temp_allocator, .Identifier, "")
		for member in v.args {
			hit := hits[cast(uintptr)member] or_continue
			append(&locations, common.Location{hit.symbol.uri, hit.symbol.range})
		}
	}
	return locations[:]
}

request_implementation :: proc(
	params: json.Value,
	id: RequestId,
	config: ^common.Config,
	writer: ^Writer,
) -> common.Error {
	position_params: TextDocumentPositionParams
	if unmarshal(params, position_params, context.temp_allocator) != nil {
		return .ParseError
	}

	document := document_get(position_params.textDocument.uri)
	if document == nil {
		return .InternalError
	}

	locations := get_implementation_locations(document, position_params.position)
	send_response(make_response_message(params = locations, id = id), writer)
	return .None
}
