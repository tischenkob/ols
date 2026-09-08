package server

import "core:encoding/json"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:path/filepath"
import "core:strings"

import "src:common"
import "src:odin/format"

DocumentRangeFormattingParams :: struct {
	textDocument: TextDocumentIdentifier,
	range:        common.Range,
	options:      FormattingOptions,
}

request_range_format :: proc(
	params: json.Value,
	id: RequestId,
	config: ^common.Config,
	writer: ^Writer,
) -> common.Error {
	if _, ok := params.(json.Object); !ok do return .ParseError

	format_params: DocumentRangeFormattingParams
	if unmarshal(params, format_params, context.temp_allocator) != nil do return .ParseError

	document := document_get(format_params.textDocument.uri)
	if document == nil do return .InternalError

	response := make_response_message(params = get_range_format(document, format_params.range, config), id = id)
	send_response(response, writer)

	return .None
}

// Attributes and doc comments belong to the declaration, but sit before its own position.
@(private = "file")
decl_start :: proc(decl: ^ast.Stmt) -> tokenizer.Pos {
	pos := decl.pos

	docs: ^ast.Comment_Group
	attributes: []^ast.Attribute

	#partial switch d in decl.derived_stmt {
	case ^ast.Value_Decl:
		docs, attributes = d.docs, d.attributes[:]
	case ^ast.Import_Decl:
		docs, attributes = d.docs, d.attributes[:]
	case ^ast.Foreign_Block_Decl:
		docs, attributes = d.docs, d.attributes[:]
	case ^ast.Foreign_Import_Decl:
		docs, attributes = d.docs, d.attributes[:]
	}

	if docs != nil && docs.pos.offset < pos.offset do pos = docs.pos
	for attribute in attributes {
		if attribute.pos.offset < pos.offset do pos = attribute.pos
	}

	return pos
}

// Each intersecting declaration is formatted on its own as a one-declaration package,
// then the synthetic package clause is stripped back off.
get_range_format :: proc(document: ^Document, range: common.Range, config: ^common.Config) -> []TextEdit {
	edits := make([dynamic]TextEdit, context.temp_allocator)

	if !config.enable_range_format do return edits[:]
	if document.ast.syntax_error_count > 0 do return edits[:]

	src := document.ast.src
	text := document.text[:document.used_text]
	style := format.find_config_file_or_default(filepath.dir(document.fullpath))

	for decl in document.ast.decls {
		start_pos := decl_start(decl)
		if start_pos.line - 1 > range.end.line || decl.end.line - 1 < range.start.line do continue

		start := strings.last_index_byte(src[:start_pos.offset], '\n') + 1
		end := min(decl.end.offset, len(src))
		if end <= start do continue

		fragment := strings.concatenate({"package p\n\n", src[start:end], "\n"}, context.temp_allocator)
		formatted, ok := format.format(document.fullpath, fragment, style, allocator = context.temp_allocator)
		if !ok do continue

		body := strings.trim_left(formatted[strings.index_byte(formatted, '\n') + 1:], "\n")
		body = strings.trim_right_space(body)
		if body == "" do continue

		append(
			&edits,
			TextEdit {
				newText = body,
				range = {
					common.get_relative_token_position(start, text, 0),
					common.get_relative_token_position(end, text, 0),
				},
			},
		)
	}

	return edits[:]
}
