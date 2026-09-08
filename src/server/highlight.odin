package server

import "core:encoding/json"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:slice"

import "src:common"

request_highlights :: proc(
	params: json.Value,
	id: RequestId,
	config: ^common.Config,
	writer: ^Writer,
) -> common.Error {
	if _, ok := params.(json.Object); !ok do return .ParseError

	highlight_params: HighlightParams
	if unmarshal(params, highlight_params, context.temp_allocator) != nil do return .ParseError

	document := document_get(highlight_params.textDocument.uri)
	if document == nil do return .InternalError

	highlights := get_document_highlights(document, highlight_params.position, config)
	send_response(make_response_message(params = highlights, id = id), writer)

	return .None
}

// References to the symbol under the cursor, or the exit points of the proc, loop or switch
// the cursor names.
get_document_highlights :: proc(
	document: ^Document,
	position: common.Position,
	config: ^common.Config,
) -> []DocumentHighlight {
	if !config.enable_document_highlights do return {}

	text := document.text[:document.used_text]
	offset, ok := common.get_absolute_position(position, text)
	if !ok do return {}

	if exits, is_exit := exit_highlights(document, text, offset); is_exit {
		return exits
	}

	locations, refs_ok := get_references(document, position, true)
	if !refs_ok do return {}

	uses := make(map[int]IdentUse, 0, context.temp_allocator)
	for decl in document.ast.decls {
		for use in collect_ident_uses(decl) {
			uses[use.ident.pos.offset] = use
		}
	}

	highlights := make([dynamic]DocumentHighlight, 0, len(locations), context.temp_allocator)
	for location in locations {
		kind := DocumentHighlightKind.Read
		if start, start_ok := common.get_absolute_position(location.range.start, text); start_ok {
			if use, found := uses[start]; found && (is_write(use) || is_declaration_name(use)) {
				kind = .Write
			}
		}
		append(&highlights, DocumentHighlight{kind = kind, range = location.range})
	}

	return sorted(highlights[:])
}

@(private = "file")
is_declaration_name :: proc(use: IdentUse) -> bool {
	if len(use.parents) == 0 do return false
	decl := use.parents[len(use.parents) - 1].derived.(^ast.Value_Decl) or_else nil
	if decl == nil do return false
	name: ^ast.Expr = use.ident
	return slice.contains(decl.names, name)
}

@(private = "file")
sorted :: proc(highlights: []DocumentHighlight) -> []DocumentHighlight {
	less :: proc(a, b: DocumentHighlight) -> bool {
		if a.range.start.line != b.range.start.line do return a.range.start.line < b.range.start.line
		return a.range.start.character < b.range.start.character
	}
	slice.sort_by(highlights, less)
	return highlights
}

@(private = "file")
Target_Kind :: enum {
	None,
	Loop,
	Switch,
	Labelled, // only a labelled break reaches it
}

@(private = "file")
exit_highlights :: proc(document: ^Document, text: []u8, offset: int) -> ([]DocumentHighlight, bool) {
	word_start, word_end := offset, offset
	for word_start > 0 && is_ident_byte(text[word_start - 1]) do word_start -= 1
	for word_end < len(text) && is_ident_byte(text[word_end]) do word_end += 1
	word := string(text[word_start:word_end])

	chain := nodes_at(document.ast.decls[:], offset)

	lit: ^ast.Proc_Lit
	#reverse for at in chain {
		if p, is_lit := at.node.derived.(^ast.Proc_Lit); is_lit {
			lit = p
			break
		}
	}

	if lit != nil && lit.body != nil && names_returns(lit, word, word_start, offset) {
		return return_highlights(text, lit), true
	}

	target: ^ast.Node
	switch word {
	case "break", "continue", "fallthrough":
		#reverse for at, i in chain {
			branch := at.node.derived.(^ast.Branch_Stmt) or_else nil
			if branch == nil do continue
			ancestors := make([dynamic]^ast.Node, 0, i, context.temp_allocator)
			for above in chain[:i] do append(&ancestors, above.node)
			target = branch_target(ancestors[:], branch)
			break
		}
	case "for", "switch":
		#reverse for at in chain {
			if pos, _, is_keyword := keyword_of(at.node); is_keyword && pos == word_start {
				target = at.node
				break
			}
		}
	}

	if target == nil do return {}, false

	highlights := make([dynamic]DocumentHighlight, 0, context.temp_allocator)
	if pos, length, is_keyword := keyword_of(target); is_keyword {
		append(&highlights, DocumentHighlight{kind = .Text, range = offset_range(text, pos, pos + length)})
	}
	for branch in branches_targeting(target) {
		keyword := tokenizer.to_string(branch.tok.kind)
		start := branch.pos.offset
		append(&highlights, DocumentHighlight{kind = .Text, range = offset_range(text, start, start + len(keyword))})
	}

	return sorted(highlights[:]), true
}

@(private = "file")
names_returns :: proc(lit: ^ast.Proc_Lit, word: string, word_start, offset: int) -> bool {
	if word == "return" do return true
	if word == "proc" && word_start == lit.pos.offset do return true
	results := lit.type.results
	return results != nil && results.pos.offset <= offset && offset <= results.end.offset
}

@(private = "file")
return_highlights :: proc(text: []u8, lit: ^ast.Proc_Lit) -> []DocumentHighlight {
	Data :: struct {
		returns: [dynamic]^ast.Return_Stmt,
	}

	data := Data {
		returns = make([dynamic]^ast.Return_Stmt, context.temp_allocator),
	}

	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			data := (^Data)(visitor.data)
			#partial switch n in node.derived {
			case ^ast.Proc_Lit:
				return nil
			case ^ast.Return_Stmt:
				append(&data.returns, n)
			}
			return visitor
		},
	}
	ast.walk(&visitor, lit.body)

	highlights := make([dynamic]DocumentHighlight, 0, len(data.returns) + 1, context.temp_allocator)
	append(
		&highlights,
		DocumentHighlight{kind = .Text, range = offset_range(text, lit.pos.offset, lit.pos.offset + len("proc"))},
	)
	for ret in data.returns {
		start := ret.pos.offset
		append(&highlights, DocumentHighlight{kind = .Text, range = offset_range(text, start, start + len("return"))})
	}

	return sorted(highlights[:])
}

// Every break/continue/fallthrough inside `target` that leaves or repeats it.
@(private = "file")
branches_targeting :: proc(target: ^ast.Node) -> []^ast.Branch_Stmt {
	Data :: struct {
		target:  ^ast.Node,
		stack:   [dynamic]^ast.Node,
		matches: [dynamic]^ast.Branch_Stmt,
	}

	data := Data {
		target  = target,
		stack   = make([dynamic]^ast.Node, context.temp_allocator),
		matches = make([dynamic]^ast.Branch_Stmt, context.temp_allocator),
	}

	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil {
				pop(&data.stack)
				return nil
			}
			#partial switch n in node.derived {
			case ^ast.Proc_Lit:
				return nil
			case ^ast.Branch_Stmt:
				if branch_target(data.stack[:], n) == data.target {
					append(&data.matches, n)
				}
			}
			append(&data.stack, node)
			return visitor
		},
	}
	ast.walk(&visitor, target)

	return data.matches[:]
}

@(private = "file")
branch_target :: proc(ancestors: []^ast.Node, branch: ^ast.Branch_Stmt) -> ^ast.Node {
	#reverse for node in ancestors {
		if _, is_lit := node.derived.(^ast.Proc_Lit); is_lit do return nil

		kind := target_kind(node)
		if kind == .None do continue

		if branch.label != nil {
			label := label_of(node)
			if label == nil do continue
			if ident, is_ident := label.derived.(^ast.Ident); is_ident && ident.name == branch.label.name {
				return node
			}
			continue
		}

		#partial switch branch.tok.kind {
		case .Continue:
			if kind == .Loop do return node
		case .Break:
			if kind == .Loop || kind == .Switch do return node
		case .Fallthrough:
			if kind == .Switch do return node
		}
	}
	return nil
}

@(private = "file")
target_kind :: proc(node: ^ast.Node) -> Target_Kind {
	#partial switch _ in node.derived {
	case ^ast.For_Stmt, ^ast.Range_Stmt, ^ast.Unroll_Range_Stmt:
		return .Loop
	case ^ast.Switch_Stmt, ^ast.Type_Switch_Stmt:
		return .Switch
	case ^ast.If_Stmt, ^ast.Block_Stmt:
		return .Labelled
	}
	return .None
}

@(private = "file")
label_of :: proc(node: ^ast.Node) -> ^ast.Expr {
	#partial switch n in node.derived {
	case ^ast.For_Stmt:
		return n.label
	case ^ast.Range_Stmt:
		return n.label
	case ^ast.Unroll_Range_Stmt:
		return n.label
	case ^ast.Switch_Stmt:
		return n.label
	case ^ast.Type_Switch_Stmt:
		return n.label
	case ^ast.If_Stmt:
		return n.label
	case ^ast.Block_Stmt:
		return n.label
	}
	return nil
}

// Offset and byte length of the keyword a branch statement can name.
@(private = "file")
keyword_of :: proc(node: ^ast.Node) -> (offset: int, length: int, ok: bool) {
	#partial switch n in node.derived {
	case ^ast.For_Stmt:
		return n.for_pos.offset, len("for"), true
	case ^ast.Range_Stmt:
		return n.for_pos.offset, len("for"), true
	case ^ast.Unroll_Range_Stmt:
		return n.for_pos.offset, len("for"), true
	case ^ast.Switch_Stmt:
		return n.switch_pos.offset, len("switch"), true
	case ^ast.Type_Switch_Stmt:
		return n.switch_pos.offset, len("switch"), true
	case ^ast.If_Stmt:
		return n.if_pos.offset, len("if"), true
	case ^ast.Block_Stmt:
		return n.open.offset, 1, true
	}
	return 0, 0, false
}

@(private = "file")
offset_range :: proc(text: []u8, start, end: int) -> common.Range {
	return {
		start = common.get_relative_token_position(start, text, 0),
		end = common.get_relative_token_position(end, text, 0),
	}
}

@(private = "file")
is_ident_byte :: proc(c: u8) -> bool {
	return tokenizer.is_letter(rune(c)) || tokenizer.is_digit(rune(c))
}
