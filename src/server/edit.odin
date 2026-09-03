package server

import "base:runtime"
import "core:odin/ast"
import "core:slice"
import "core:strings"

import "src:common"

ActionContext :: struct {
	document:         ^Document,
	ast_context:      ^AstContext,
	position_context: ^DocumentPositionContext,
	range:            common.AbsoluteRange,
	uri:              string,
	config:           ^common.Config,
	actions:          ^[dynamic]CodeAction,
}

make_code_action :: proc(ctx: ^ActionContext, title: string, kind: CodeActionKind, edits: []TextEdit) -> CodeAction {
	edit: WorkspaceEdit
	edit.changes = make(map[string][]TextEdit, 0, context.temp_allocator)
	edit.changes[ctx.uri] = edits
	return CodeAction{title = title, kind = kind, edit = edit}
}

range_of :: proc(ctx: ^ActionContext, start, end: int) -> common.Range {
	text := ctx.document.text[:ctx.document.used_text]
	return {
		start = common.get_relative_token_position(start, text, 0),
		end = common.get_relative_token_position(end, text, 0),
	}
}

trim_range :: proc(src: string, start, end: int) -> (int, int) {
	start, end := start, end
	for start < end && strings.is_space(rune(src[start])) {
		start += 1
	}
	for end > start && strings.is_space(rune(src[end - 1])) {
		end -= 1
	}
	return start, end
}

StmtListAt :: struct {
	stmts:       []^ast.Stmt,
	first, last: int,
}

// Innermost block or case body containing [start, end], and the indices of the statements it
// overlaps. first > last when the range sits in whitespace between statements.
find_stmt_list_at :: proc(root: ^ast.Node, start, end: int) -> (StmtListAt, bool) {
	Data :: struct {
		start, end: int,
		result:     StmtListAt,
		found:      bool,
	}

	data := Data{start = start, end = end}

	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil || node.pos.offset > data.start || data.end > node.end.offset {
				return nil
			}

			stmts: []^ast.Stmt
			#partial switch n in node.derived {
			case ^ast.Block_Stmt:
				stmts = n.stmts
			case ^ast.Case_Clause:
				stmts = n.body
			case:
				return visitor
			}

			data.result = {stmts = stmts, first = len(stmts), last = -1}
			data.found = true
			for stmt, i in stmts {
				if stmt == nil || stmt.end.offset < data.start || data.end < stmt.pos.offset {
					continue
				}
				if data.start != data.end && (stmt.end.offset == data.start || data.end == stmt.pos.offset) {
					continue
				}
				data.result.first = min(data.result.first, i)
				data.result.last = i
			}
			return visitor
		},
	}

	ast.walk(&visitor, root)
	return data.result, data.found
}

IdentUse :: struct {
	ident:   ^ast.Ident,
	parents: []^ast.Node, // outermost first
}

collect_ident_uses :: proc(root: ^ast.Node, allocator := context.temp_allocator) -> []IdentUse {
	Data :: struct {
		uses:      [dynamic]IdentUse,
		stack:     [dynamic]^ast.Node,
		allocator: runtime.Allocator,
	}

	data := Data {
		uses      = make([dynamic]IdentUse, allocator),
		stack     = make([dynamic]^ast.Node, context.temp_allocator),
		allocator = allocator,
	}

	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil {
				pop(&data.stack)
				return nil
			}
			if ident, ok := node.derived.(^ast.Ident); ok {
				append(&data.uses, IdentUse{ident = ident, parents = slice.clone(data.stack[:], data.allocator)})
			}
			append(&data.stack, node)
			return visitor
		},
	}

	ast.walk(&visitor, root)
	return data.uses[:]
}

// Assignment, address-of and `using` targets count as writes, also through the base of a
// selector, index, slice or deref: `x.y = 1` and `&x[i]` write x.
is_write :: proc(use: IdentUse) -> bool {
	target: ^ast.Expr = use.ident
	i := len(use.parents) - 1
	for ; i >= 0; i -= 1 {
		#partial switch p in use.parents[i].derived {
		case ^ast.Selector_Expr:
			if p.expr == target {
				target = p
				continue
			}
		case ^ast.Index_Expr:
			if p.expr == target {
				target = p
				continue
			}
		case ^ast.Slice_Expr:
			if p.expr == target {
				target = p
				continue
			}
		case ^ast.Deref_Expr:
			target = p
			continue
		}
		break
	}
	if i < 0 {
		return false
	}

	#partial switch p in use.parents[i].derived {
	case ^ast.Assign_Stmt:
		return slice.contains(p.lhs, target)
	case ^ast.Unary_Expr:
		return p.op.kind == .And
	case ^ast.Using_Stmt:
		return slice.contains(p.list, target)
	}
	return false
}

// Byte offset of the local declaration the ident refers to. symbols comes from
// resolve_entire_file_for_references(document, allocator, .Identifier, "").
local_decl_offset :: proc(ctx: ^ActionContext, symbols: SymbolAndNodeMap, ident: ^ast.Ident) -> (int, bool) {
	resolved, ok := symbols[uintptr(ident)]
	if !ok || .Local not_in resolved.symbol.flags {
		return 0, false
	}
	return common.get_absolute_position(resolved.symbol.range.start, ctx.document.text[:ctx.document.used_text])
}

reindent :: proc(text, from, to: string, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	for line, i in strings.split(text, "\n", context.temp_allocator) {
		if i > 0 {
			strings.write_byte(&sb, '\n')
		}
		if len(line) == 0 {
			continue
		}
		strings.write_string(&sb, to)
		strings.write_string(&sb, strings.trim_prefix(line, from))
	}
	return strings.to_string(sb)
}

get_line_indentation :: proc(src: string, offset: int) -> string {
	line_start := offset
	for line_start > 0 && src[line_start - 1] != '\n' {
		line_start -= 1
	}

	indent_end := line_start
	for indent_end < len(src) && (src[indent_end] == ' ' || src[indent_end] == '\t') {
		indent_end += 1
	}

	return src[line_start:indent_end]
}
