package server

import "core:encoding/json"
import "core:odin/ast"
import "core:slice"
import "core:strings"

import "src:common"

// The members of a procedure group. For a procedure listed in groups, those groups. Otherwise the procedure itself.
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
		groups := proc_group_locations(&h, target, decl, symbol, files)
		if len(groups) > 0 {
			append(&locations, ..groups)
		} else {
			append(&locations, common.Location{symbol.uri, symbol.range})
		}
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

// The declarations of the procedure groups that list decl, found through its references.
@(private = "file")
proc_group_locations :: proc(
	h: ^Call_Hierarchy,
	document: ^Document,
	decl: ^ast.Value_Decl,
	symbol: Symbol,
	files: []Package_File,
) -> []common.Location {
	name, is_ident := decl.names[0].derived.(^ast.Ident)
	if !is_ident {
		return {}
	}

	ast_context := globals_context(document)

	references, _ := find_symbol_references(
		document,
		&ast_context,
		Symbol{uri = symbol.uri, range = symbol.range, pkg = document.package_name, name = name.name},
		.Identifier,
		include_declaration = false,
		target_name = name.name,
		files = files,
		require_proc_group = true,
	)

	groups := make([dynamic]common.Location, context.temp_allocator)
	for reference in references {
		user := hierarchy_document(h, reference.uri)
		if user == nil {
			continue
		}
		text := string(user.text[:user.used_text])
		offset, ok := common.get_absolute_position(reference.range.start, user.text[:user.used_text])
		if !ok {
			continue
		}
		for candidate in top_level_value_decls(user.ast) {
			if len(candidate.names) == 0 || len(candidate.values) != 1 {
				continue
			}
			if offset < candidate.pos.offset || offset >= candidate.end.offset {
				continue
			}
			if _, is_group := candidate.values[0].derived.(^ast.Proc_Group); is_group {
				location := common.Location{reference.uri, common.get_token_range(candidate.names[0], text)}
				if !slice.contains(groups[:], location) {
					append(&groups, location)
				}
			}
		}
	}
	return groups[:]
}

// Whether the text has `proc`, then blanks and comments, then `{`: the start of a group literal. It accepts more
// than the parser does (a comment or string can match); it misses only a nested block comment between `proc` and `{`.
mentions_proc_group :: proc(text: string) -> bool {
	rest := text
	for {
		at := strings.index(rest, "proc")
		if at < 0 do return false
		rest = strings.trim_left_space(rest[at + len("proc"):])
		for {
			if strings.has_prefix(rest, "//") {
				end := strings.index_byte(rest, '\n')
				if end < 0 do return false
				rest = rest[end:]
			} else if strings.has_prefix(rest, "/*") {
				end := strings.index(rest, "*/")
				if end < 0 do return false
				rest = rest[end + len("*/"):]
			} else {
				break
			}
			rest = strings.trim_left_space(rest)
		}
		if strings.has_prefix(rest, "{") do return true
	}
}
