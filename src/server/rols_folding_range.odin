package server

import "core:encoding/json"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:slice"
import "core:strings"

import "src:common"

request_folding_range :: proc(
	params: json.Value,
	id: RequestId,
	config: ^common.Config,
	writer: ^Writer,
) -> common.Error {
	if _, ok := params.(json.Object); !ok do return .ParseError

	folding_params: FoldingRangeParams
	if unmarshal(params, folding_params, context.temp_allocator) != nil do return .ParseError

	document := document_get(folding_params.textDocument.uri)
	if document == nil do return .InternalError

	response := make_response_message(params = get_folding_ranges(document), id = id)
	send_response(response, writer)

	return .None
}

folding_range_less :: proc(a, b: FoldingRange) -> bool {
	return a.startLine < b.startLine || (a.startLine == b.startLine && a.endLine < b.endLine)
}

get_folding_ranges :: proc(document: ^Document) -> []FoldingRange {
	Walker :: struct {
		src:        string,
		ranges:     [dynamic]FoldingRange,
		// Bodies of proc literals and compound statements fold from the keyword line.
		body_start: map[^ast.Node]int,
	}

	// Lines startLine+1 ..= endLine get hidden, so a closing token alone on its line stays visible.
	add_region :: proc(w: ^Walker, start_line: int, end: tokenizer.Pos) {
		end_line := end.line
		if end.offset > 0 && end.offset <= len(w.src) {
			last := end.offset - 1
			line_start := strings.last_index_byte(w.src[:last], '\n') + 1
			if strings.trim_space(w.src[line_start:last]) == "" {
				end_line -= 1
			}
		}
		if end_line > start_line {
			append(&w.ranges, FoldingRange{start_line - 1, end_line - 1, "region"})
		}
	}

	visit :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
		if node == nil do return nil
		w := (^Walker)(visitor.data)

		#partial switch n in node.derived {
		case ^ast.Proc_Lit:
			if n.body != nil do w.body_start[n.body] = n.pos.line
		case ^ast.If_Stmt:
			w.body_start[n.body] = n.pos.line
		case ^ast.For_Stmt:
			w.body_start[n.body] = n.pos.line
		case ^ast.Range_Stmt:
			w.body_start[n.body] = n.pos.line
		case ^ast.Switch_Stmt:
			w.body_start[n.body] = n.pos.line
		case ^ast.Type_Switch_Stmt:
			w.body_start[n.body] = n.pos.line
		case ^ast.When_Stmt:
			w.body_start[n.body] = n.pos.line
		case ^ast.Block_Stmt:
			add_region(w, w.body_start[node] or_else n.pos.line, n.end)
		case ^ast.Case_Clause:
			if n.end.line > n.pos.line {
				append(&w.ranges, FoldingRange{n.pos.line - 1, n.end.line - 1, "region"})
			}
		case ^ast.Comp_Lit,
		     ^ast.Struct_Type,
		     ^ast.Union_Type,
		     ^ast.Enum_Type,
		     ^ast.Bit_Field_Type,
		     ^ast.Proc_Type,
		     ^ast.Call_Expr:
			add_region(w, node.pos.line, node.end)
		}

		return visitor
	}

	w := Walker {
		src        = document.ast.src,
		ranges     = make([dynamic]FoldingRange, context.temp_allocator),
		body_start = make(map[^ast.Node]int, context.temp_allocator),
	}

	first, last := 0, 0
	for decl in document.ast.decls {
		imp, ok := decl.derived.(^ast.Import_Decl)
		if !ok do continue
		if imp.pos.line == last + 1 {
			last = imp.pos.line
			continue
		}
		if last > first do append(&w.ranges, FoldingRange{first - 1, last - 1, "imports"})
		first, last = imp.pos.line, imp.pos.line
	}
	if last > first do append(&w.ranges, FoldingRange{first - 1, last - 1, "imports"})

	for group in document.ast.comments {
		if group.end.line > group.pos.line {
			append(&w.ranges, FoldingRange{group.pos.line - 1, group.end.line - 1, "comment"})
		}
	}

	visitor := ast.Visitor{visit = visit, data = &w}
	for decl in document.ast.decls {
		ast.walk(&visitor, decl)
	}

	slice.sort_by(w.ranges[:], folding_range_less)
	return slice.unique(w.ranges[:])
}
