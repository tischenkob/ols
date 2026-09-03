package server

import "base:runtime"
import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"
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

// Type of a local as Odin source, resolved with locals gathered up to the current position.
local_type_text :: proc(ctx: ^ActionContext, ident: ^ast.Ident) -> (string, bool) {
	// Resolving a global type turns locals off and leaves them off.
	ctx.ast_context.use_locals = true
	symbol, ok := resolve_type_expression(ctx.ast_context, ident)
	if !ok {
		return "", false
	}
	return symbol_type_text(ctx.ast_context, symbol, ident.name)
}

// Named types print by name, with the package alias when foreign. Anonymous aggregates and
// untyped constants have no name to write.
symbol_type_text :: proc(ast_context: ^AstContext, symbol: Symbol, name: string) -> (string, bool) {
	symbol := symbol
	_, is_untyped := symbol.value.(SymbolUntypedValue)
	if is_untyped && .Mutable not_in symbol.flags {
		return "", false
	}
	construct_ident_symbol_info(&symbol, name, ast_context.document_package)
	// An untyped value copied from another variable carries that variable's name, not a type.
	if is_untyped {
		symbol.type_name = ""
	}

	text := strings.builder_make(context.temp_allocator)
	if symbol.type_name != "" {
		for _ in 0 ..< symbol.pointers {
			strings.write_byte(&text, '^')
		}
		if symbol.type_pkg != "" && symbol.type_pkg != ast_context.document_package {
			pkg_name := get_pkg_name(ast_context, symbol.type_pkg)
			if pkg_name != "" && pkg_name != "$builtin" {
				strings.write_string(&text, pkg_name)
				strings.write_byte(&text, '.')
			}
		}
		strings.write_string(&text, symbol.type_name)
		#partial switch v in symbol.value {
		case SymbolStructValue:
			write_poly_list(&text, v.poly, v.poly_names)
		case SymbolUnionValue:
			write_poly_list(&text, v.poly, v.poly_names)
		}
	} else {
		write_short_signature(&text, ast_context, symbol)
	}

	result := strings.to_string(text)
	if result == "" || strings.contains(result, "{") {
		return "", false
	}
	return result, true
}

// Initializers that already name their type, so an explicit type would repeat it. callee is
// the resolved callee of a Call_Expr: a conversion like int(x) resolves to a type, not a proc.
value_states_type :: proc(value: ^ast.Expr, callee: Symbol, callee_ok: bool) -> bool {
	#partial switch v in value.derived {
	case ^ast.Comp_Lit:
		return v.type != nil
	case ^ast.Type_Cast, ^ast.Auto_Cast, ^ast.Proc_Lit:
		return true
	case ^ast.Call_Expr:
		if !callee_ok {
			return false
		}
		#partial switch _ in callee.value {
		case SymbolProcedureValue, SymbolAggregateValue, SymbolProcedureGroupValue:
			return false
		}
		return true
	}
	return false
}

Node_At :: struct {
	node, parent: ^ast.Node,
}

// Every node containing pos, outermost first.
nodes_at :: proc(roots: []^ast.Stmt, pos: int) -> []Node_At {
	Data :: struct {
		pos:   int,
		stack: [dynamic]^ast.Node,
		found: [dynamic]Node_At,
	}

	data := Data {
		pos   = pos,
		stack = make([dynamic]^ast.Node, context.temp_allocator),
		found = make([dynamic]Node_At, context.temp_allocator),
	}

	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil {
				pop(&data.stack)
				return nil
			}
			if node.pos.offset > data.pos || data.pos > node.end.offset {
				return nil
			}
			parent: ^ast.Node
			if len(data.stack) > 0 {
				parent = data.stack[len(data.stack) - 1]
			}
			append(&data.found, Node_At{node = node, parent = parent})
			append(&data.stack, node)
			return visitor
		},
	}

	for root in roots {
		ast.walk(&visitor, root)
	}
	return data.found[:]
}

strip_space :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for c in s {
		if !strings.is_space(c) {
			strings.write_rune(&sb, c)
		}
	}
	return strings.to_string(sb)
}

node_text :: proc(src: string, node: ^ast.Node) -> string {
	return src[node.pos.offset:node.end.offset]
}

append_replace_range :: proc(ctx: ^ActionContext, start, end: int, title: string, text: string) {
	edits := make([]TextEdit, 1, context.temp_allocator)
	edits[0] = TextEdit {
		range   = range_of(ctx, start, end),
		newText = text,
	}
	append(ctx.actions, make_code_action(ctx, title, "refactor.rewrite", edits))
}

// Source between the braces, without the newline after `{` and trailing whitespace.
block_inner_text :: proc(src: string, block: ^ast.Block_Stmt) -> string {
	return strings.trim_left(strings.trim_right_space(src[block.open.offset + 1:block.close.offset]), "\r\n")
}

// The lines of a block at their current depth. A `do` body has no braces; its one statement is
// placed one level below ind.
block_lines :: proc(src: string, block: ^ast.Block_Stmt, ind, unit: string) -> string {
	if block.uses_do {
		return strings.concatenate({ind, unit, node_text(src, block.stmts[0])}, context.temp_allocator)
	}
	return block_inner_text(src, block)
}

// One indentation level: what inner adds to ind when it sits on its own deeper line, else the
// indentation of the first indented line of the file, else a tab.
indent_unit :: proc(src, ind: string, inner: ^ast.Node) -> string {
	if inner != nil {
		deeper := get_line_indentation(src, inner.pos.offset)
		if len(deeper) > len(ind) && strings.has_prefix(deeper, ind) {
			return deeper[len(ind):]
		}
	}
	rest := src
	for line in strings.split_lines_iterator(&rest) {
		ws := len(line) - len(strings.trim_left(line, " \t"))
		if ws > 0 && ws < len(line) {
			return line[:ws]
		}
	}
	return "\t"
}

// Deletes whole lines first..=last (zero based). The last line of the document has no trailing
// newline to consume.
delete_lines_edit :: proc(ctx: ^ActionContext, first, last: int) -> TextEdit {
	edit := TextEdit {
		range = {start = {line = first, character = 0}, end = {line = last + 1, character = 0}},
	}
	if _, ok := common.get_last_column(last + 1, ctx.document.text); !ok {
		if column, ok := common.get_last_column(last, ctx.document.text); ok {
			edit.range.end = {line = last, character = column}
		}
	}
	return edit
}

// `{}` is the zero literal for every aggregate, including enums and unions. The scalar forms are
// the shortest ones the compiler accepts for each basic type.
zero_value_text :: proc(symbol: Symbol, resolved: bool) -> string {
	if !resolved {
		return "{}"
	}
	if symbol.pointers > 0 {
		return "nil"
	}
	#partial switch v in symbol.value {
	case SymbolBasicValue:
		switch v.ident.name {
		case "bool", "b8", "b16", "b32", "b64":
			return "false"
		case "string", "cstring":
			return `""`
		case "rawptr", "any", "typeid":
			return "nil"
		}
		return "0"
	case SymbolMultiPointerValue,
	     SymbolSliceValue,
	     SymbolDynamicArrayValue,
	     SymbolMapValue,
	     SymbolProcedureValue,
	     SymbolProcedureGroupValue:
		return "nil"
	}
	return "{}"
}

is_taken :: proc(ctx: ^ActionContext, ident: ast.Ident) -> bool {
	if ident.name in ctx.ast_context.globals {
		return true
	}
	_, ok := get_local(ctx.ast_context^, ident)
	return ok
}

// base, else base2, base3... whichever is free among the locals visible at pos and the globals.
fresh_name :: proc(ctx: ^ActionContext, base: string, pos: tokenizer.Pos) -> string {
	probe: ast.Ident
	probe.pos = pos
	probe.name = base
	for i := 2; is_taken(ctx, probe); i += 1 {
		probe.name = fmt.tprintf("%s%d", base, i)
	}
	return probe.name
}
