package server

import "core:encoding/json"
import "core:odin/tokenizer"

import "src:common"

request_selection_range :: proc(
	params: json.Value,
	id: RequestId,
	config: ^common.Config,
	writer: ^Writer,
) -> common.Error {
	if _, ok := params.(json.Object); !ok do return .ParseError

	selection_params: SelectionRangeParams
	if unmarshal(params, selection_params, context.temp_allocator) != nil do return .ParseError

	document := document_get(selection_params.textDocument.uri)
	if document == nil do return .InternalError

	result := make(json.Array, 0, len(selection_params.positions), context.temp_allocator)
	for chain in get_selection_ranges(document, selection_params.positions, config) {
		append(&result, nest_ranges(chain))
	}

	send_response(make_response_message(params = json.Value(result), id = id), writer)

	return .None
}

// For each position, the ranges around it from innermost to outermost.
get_selection_ranges :: proc(
	document: ^Document,
	positions: []common.Position,
	config: ^common.Config,
) -> [][]common.Range {
	chains := make([][]common.Range, len(positions), context.temp_allocator)
	if !config.enable_selection_range do return chains

	text := document.text[:document.used_text]

	for position, i in positions {
		offset, ok := common.get_absolute_position(position, text)
		if !ok do continue

		chain := make([dynamic]common.Range, context.temp_allocator)

		word_start, word_end := offset, offset
		for word_start > 0 && is_word_byte(text[word_start - 1]) do word_start -= 1
		for word_end < len(text) && is_word_byte(text[word_end]) do word_end += 1
		if word_end > word_start {
			append(&chain, range_between(text, word_start, word_end))
		}

		#reverse for at in nodes_at(document.ast.decls[:], offset) {
			range := range_between(text, at.node.pos.offset, at.node.end.offset)
			if len(chain) > 0 {
				last := chain[len(chain) - 1]
				if last == range do continue
				// Ranges must nest, so a word the innermost node does not contain is dropped.
				if len(chain) == 1 && !range_contains(range, last) {
					clear(&chain)
				}
			}
			append(&chain, range)
		}

		chains[i] = chain[:]
	}

	return chains
}

@(private = "file")
is_word_byte :: proc(c: u8) -> bool {
	return tokenizer.is_letter(rune(c)) || tokenizer.is_digit(rune(c))
}

@(private = "file")
range_between :: proc(text: []u8, start, end: int) -> common.Range {
	return {
		start = common.get_relative_token_position(start, text, 0),
		end = common.get_relative_token_position(end, text, 0),
	}
}

@(private = "file")
position_less :: proc(a, b: common.Position) -> bool {
	return a.line < b.line || (a.line == b.line && a.character < b.character)
}

@(private = "file")
range_contains :: proc(outer, inner: common.Range) -> bool {
	return !position_less(inner.start, outer.start) && !position_less(outer.end, inner.end)
}

// A recursive struct would need a pointer field, which `marshal` rejects.
@(private = "file")
nest_ranges :: proc(chain: []common.Range) -> json.Value {
	value: json.Value
	#reverse for range in chain {
		object := make(json.Object, 2, context.temp_allocator)
		object["range"] = range_value(range)
		if value != nil do object["parent"] = value
		value = object
	}
	return value
}

@(private = "file")
range_value :: proc(range: common.Range) -> json.Value {
	position_value :: proc(position: common.Position) -> json.Value {
		object := make(json.Object, 2, context.temp_allocator)
		object["line"] = json.Integer(position.line)
		object["character"] = json.Integer(position.character)
		return object
	}
	object := make(json.Object, 2, context.temp_allocator)
	object["start"] = position_value(range.start)
	object["end"] = position_value(range.end)
	return object
}
