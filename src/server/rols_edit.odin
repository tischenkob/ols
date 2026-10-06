package server

import "base:runtime"
import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:unicode/utf8"

import "src:common"

ActionContext :: struct {
	document:         ^Document,
	ast_context:      ^AstContext,
	position_context: ^DocumentPositionContext,
	range:            common.AbsoluteRange,
	uri:              string,
	config:           ^common.Config,
	actions:          ^[dynamic]CodeAction,
	files:            []Package_File, // in-memory package sources for the tests, else the workspace is read
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
	return writes_through(use.ident, use.parents)
}

// is_write for any expression, with parents its ancestors outermost first.
writes_through :: proc(target: ^ast.Expr, parents: []^ast.Node) -> bool {
	target := target
	i := len(parents) - 1
	for ; i >= 0; i -= 1 {
		#partial switch p in parents[i].derived {
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

	#partial switch p in parents[i].derived {
	case ^ast.Assign_Stmt:
		return slice.contains(p.lhs, target)
	case ^ast.Unary_Expr:
		return p.op.kind == .And
	case ^ast.Using_Stmt:
		return slice.contains(p.list, target)
	}
	return false
}

// `&x`, `&x.f`, `&x[i]` or `using x`, for a use that is_write already reports.
address_taken :: proc(use: IdentUse) -> bool {
	#reverse for parent in use.parents {
		#partial switch p in parent.derived {
		case ^ast.Selector_Expr, ^ast.Index_Expr, ^ast.Slice_Expr, ^ast.Deref_Expr, ^ast.Paren_Expr:
			continue
		case ^ast.Unary_Expr:
			return p.op.kind == .And
		case ^ast.Using_Stmt:
			return true
		}
		return false
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
	return symbol_type_text(ctx.ast_context, symbol, ident.name, require_import = true)
}

// Named types print by name, with the package alias when foreign. Anonymous aggregates and
// untyped constants have no name to write. With require_import, a type of a package that the file
// does not import has no name either: use it where the text is written as code and no import is added.
symbol_type_text :: proc(
	ast_context: ^AstContext,
	symbol: Symbol,
	name: string,
	require_import := false,
) -> (
	string,
	bool,
) {
	symbol := symbol
	_, is_untyped := symbol.value.(SymbolUntypedValue)
	if is_untyped && .Mutable not_in symbol.flags {
		return "", false
	}
	// An anonymous aggregate carries its keyword, such as `struct`, as its name.
	if .Anonymous in symbol.flags {
		return "", false
	}
	// A variable's own symbol, as a poly call result is, can carry the package of its type argument. It is
	// still anonymous, and must not turn the variable name into a type name.
	if name != "" && symbol.name == name && (symbol.type == .Variable || symbol.type == .Constant) {
		symbol.pkg = ast_context.document_package
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
		// A builtin result of a package's proc carries that package, but it is never written qualified.
		// An alias that the package declares under a builtin name, such as c.int, is.
		if symbol.type_pkg != "" &&
		   symbol.type_pkg != ast_context.document_package &&
		   !builtin_without_decl(symbol.type_name, symbol.type_pkg) {
			pkg_name := get_pkg_name(ast_context, symbol.type_pkg)
			if require_import && symbol.type_pkg != "$builtin" && !pkg_imported(ast_context, symbol.type_pkg) {
				return "", false
			}
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

// Whether the current file imports the package, under any name.
pkg_imported :: proc(ast_context: ^AstContext, pkg: string) -> bool {
	for imp in ast_context.imports {
		if imp.name == pkg {
			return true
		}
	}
	return false
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

// Whitespace inside string and rune literals is part of the value and stays.
strip_space :: proc(s: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	quote: rune
	escaped := false
	for c in s {
		if quote != 0 {
			strings.write_rune(&sb, c)
			if escaped {
				escaped = false
			} else if c == '\\' && quote != '`' {
				escaped = true
			} else if c == quote {
				quote = 0
			}
			continue
		}
		if c == '"' || c == '\'' || c == '`' {
			quote = c
		}
		if quote != 0 || !strings.is_space(c) {
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

append_insert :: proc(ctx: ^ActionContext, at: int, title, kind, text: string) {
	edits := make([]TextEdit, 1, context.temp_allocator)
	edits[0] = {
		range   = range_of(ctx, at, at),
		newText = text,
	}
	append(ctx.actions, make_code_action(ctx, title, kind, edits))
}

// Source between the braces, without the newline after `{` and trailing whitespace. A `do` body
// has no braces: its open and close tokens are the statement itself, so it is the statement text.
block_inner_text :: proc(src: string, block: ^ast.Block_Stmt) -> string {
	if block.uses_do && len(block.stmts) == 1 {
		return node_text(src, block.stmts[0])
	}
	return trim_block_text(src[block.open.offset + 1:block.close.offset])
}

// The text between braces without the newline after `{` and trailing whitespace. A body written on
// the brace line, like `{ x = 1 }`, has no indentation of its own, so it loses its leading space.
trim_block_text :: proc(text: string) -> string {
	inner := strings.trim_left(strings.trim_right_space(text), "\r\n")
	if !strings.contains_any(inner, "\r\n") {
		return strings.trim_left_space(inner)
	}
	return inner
}

// The lines of a block at their current depth. A `do` body has no braces; its one statement is
// placed one level below ind.
block_lines :: proc(src: string, block: ^ast.Block_Stmt, ind, unit: string) -> string {
	inner := block_inner_text(src, block)
	// A `do` body or a body on the brace line has no indentation of its own.
	if block.uses_do || (len(inner) > 0 && !strings.contains_any(inner, "\r\n")) {
		return strings.concatenate({ind, unit, inner}, context.temp_allocator)
	}
	return inner
}

// `do ` when body is a one-statement block written with `do`, so a rewritten loop header keeps it.
do_keyword :: proc(body: ^ast.Node) -> string {
	block, ok := body.derived.(^ast.Block_Stmt)
	return "do " if ok && block.uses_do else ""
}

// One indentation level: what inner adds to ind when it sits on its own deeper line, else the
// indentation of the first indented line of code in the file, else a tab. Lines inside a raw string
// or block comment do not count.
indent_unit :: proc(src, ind: string, inner: ^ast.Node) -> string {
	if inner != nil {
		deeper := get_line_indentation(src, inner.pos.offset)
		if len(deeper) > len(ind) && strings.has_prefix(deeper, ind) {
			return deeper[len(ind):]
		}
	}
	t: tokenizer.Tokenizer
	tokenizer.init(&t, src, "", common.parser_warning_handler)
	for tok := tokenizer.scan(&t); tok.kind != .EOF; tok = tokenizer.scan(&t) {
		lead := get_line_indentation(src, tok.pos.offset)
		// A token that starts its line: the indentation reaches the token itself.
		if len(lead) > 0 && tok.pos.column == len(lead) + 1 {
			return lead
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

// A fresh local must not shadow a package symbol from any file of the package, or a builtin such as `len`.
is_taken :: proc(ctx: ^ActionContext, ident: ast.Ident) -> bool {
	if ident.name in ctx.ast_context.globals {
		return true
	}
	if _, ok := get_local(ctx.ast_context^, ident); ok {
		return true
	}
	if _, ok := lookup(ident.name, ctx.ast_context.current_package, ctx.document.fullpath); ok {
		return true
	}
	_, ok := lookup(ident.name, "$builtin", ctx.document.fullpath)
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

// The alias of the import of import_path (e.g. `core:os`), "" when it has none. `document.imports`
// drops packages whose collection is not configured, so read the parsed imports.
import_alias :: proc(document: ^Document, import_path: string) -> (alias: string, imported: bool) {
	fullpath := fmt.tprintf("\"%s\"", import_path)
	for imp in document.ast.imports {
		if imp.fullpath == fullpath {
			return imp.name.text, true
		}
	}
	return "", false
}

// The start of the line where `import "<import_path>"` goes, sorted among the top-level imports of
// the same collection (`core`, `vendor`, or relative paths): before the first one whose path sorts
// after it, else after the last one. False when the file imports nothing of that collection, or
// the import that it would follow ends the file without a newline. Imports that start on a
// 0-based line in skip_lines, such as imports being removed, are ignored.
import_group_offset :: proc(
	document: ^Document,
	import_path: string,
	skip_lines: map[int]struct{} = nil,
) -> (
	int,
	bool,
) {
	collection :: proc(path: string) -> string {
		colon := strings.index_byte(path, ':')
		return colon >= 0 ? path[:colon] : ""
	}
	src := document.ast.src
	after := -1
	for decl in document.ast.decls {
		imp, is_import := decl.derived.(^ast.Import_Decl)
		if !is_import || imp.pos.line - 1 in skip_lines do continue
		path := strings.trim(imp.fullpath, "\"`")
		if collection(path) != collection(import_path) do continue
		if import_path < path {
			start := imp.pos.offset
			if imp.docs != nil do start = min(start, imp.docs.pos.offset)
			for attr in imp.attributes do start = min(start, attr.pos.offset)
			return strings.last_index_byte(src[:start], '\n') + 1, true
		}
		after = imp.end.offset
	}
	if after < 0 do return 0, false
	newline := strings.index_byte(src[after:], '\n')
	if newline < 0 do return 0, false
	return after + newline + 1, true
}

// Appends to edits an insertion for each package that import_group_offset places among the
// imports of its collection, ignoring the imports on removed_lines. Each insertion starts a line
// that stays, so it cannot land inside a removal edit. Returns the packages without a place.
append_grouped_imports :: proc(
	edits: ^[dynamic]TextEdit,
	document: ^Document,
	packages: []Package,
	removed_lines: map[int]struct{},
) -> []Package {
	sorted := slice.clone(packages, context.temp_allocator)
	slice.sort_by(sorted, proc(a, b: Package) -> bool {return a.original < b.original})
	rest := make([dynamic]Package, 0, len(sorted), context.temp_allocator)
	for pkg in sorted {
		offset, ok := import_group_offset(document, pkg.original, removed_lines)
		pos := common.get_relative_token_position(offset, document.text[:document.used_text], 0)
		if _, is_removed := removed_lines[pos.line]; !ok || is_removed {
			append(&rest, pkg)
			continue
		}
		append(
			edits,
			TextEdit{range = {start = pos, end = pos}, newText = fmt.tprintf("import \"%s\"\n", pkg.original)},
		)
	}
	return rest[:]
}

// Adds `import "<import_path>"`, or `import <alias> "<import_path>"` with an alias, after the last
// import when enable_add_import_to_bottom is set, else among the imports of its collection, else
// after the package clause.
import_edit :: proc(ctx: ^ActionContext, import_path: string, alias := "") -> TextEdit {
	decl :=
		alias == "" ? fmt.tprintf("import \"%s\"", import_path) : fmt.tprintf("import %s \"%s\"", alias, import_path)
	if ctx.config.enable_add_import_to_bottom {
		line, is_import := find_most_bottom_line_number(ctx.ast_context)
		return {
			range = {start = {line = line, character = 0}, end = {line = line, character = 0}},
			newText = is_import ? fmt.tprintf("%s\n", decl) : fmt.tprintf("\n%s", decl),
		}
	}

	if offset, grouped := import_group_offset(ctx.document, import_path); grouped {
		return {range = range_of(ctx, offset, offset), newText = fmt.tprintf("%s\n", decl)}
	}

	// pkg_decl lines are 1-based, so this is the 0-based line right after the package clause.
	// A blank line goes on each side of the import, unless that line is blank or past the end.
	line := ctx.ast_context.file.pkg_decl.end.line
	src := ctx.document.ast.src
	rest := src[ctx.ast_context.file.pkg_decl.end.offset:]
	newline := strings.index_byte(rest, '\n')
	next_line := newline < 0 ? "" : rest[newline + 1:]
	if eol := strings.index_byte(next_line, '\n'); eol >= 0 do next_line = next_line[:eol]
	blank := strings.trim_space(next_line) == ""
	return {
		range = {start = {line = line, character = 0}, end = {line = line, character = 0}},
		newText = fmt.tprintf("\n%s\n%s", decl, blank ? "" : "\n"),
	}
}

// Appends edit, an import from import_edit, to edits unless edits already add that import. An
// import that goes where an earlier one goes joins that edit on the line after it, so the blank
// lines that import_edit puts around an import after the package clause stay around the group.
append_import_edit :: proc(edits: ^[dynamic]TextEdit, edit: TextEdit) {
	decl := strings.trim(edit.newText, "\n")
	for &existing in edits {
		lines := strings.trim(existing.newText, "\n")
		if existing.range != edit.range || !strings.has_prefix(lines, "import ") {
			continue
		}
		for line in strings.split_lines(lines, context.temp_allocator) {
			if line == decl do return
		}
		body := strings.trim_right(existing.newText, "\n")
		existing.newText = strings.concatenate(
			{body, "\n", decl, existing.newText[len(body):]},
			context.temp_allocator,
		)
		return
	}
	append(edits, edit)
}

// A type node as source text for the current document. decl_pkg is the directory of the package
// that declares the node. Indexed nodes name other packages by directory, and those print through
// the current document's import alias, with a missing import appended to edits. Builtin type
// names stay bare. Fails on polymorphic and unsupported nodes.
requalified_type_text :: proc(
	ctx: ^ActionContext,
	type_expr: ^ast.Expr,
	decl_pkg: string,
	edits: ^[dynamic]TextEdit,
) -> (
	string,
	bool,
) {
	sb := strings.builder_make(context.temp_allocator)
	if !write_requalified_type(&sb, ctx, type_expr, decl_pkg, edits) {
		return "", false
	}
	return strings.to_string(sb), true
}

@(private = "file")
write_requalified_type :: proc(
	sb: ^strings.Builder,
	ctx: ^ActionContext,
	node: ^ast.Expr,
	decl_pkg: string,
	edits: ^[dynamic]TextEdit,
) -> bool {
	if node == nil {
		return false
	}
	#partial switch n in node.derived {
	case ^ast.Ident:
		// Names in the current document or package need no qualifier.
		local := node.pos.file == ctx.document.fullpath || decl_pkg == ctx.ast_context.document_package
		if n.name in keyword_map || local {
			strings.write_string(sb, n.name)
			return true
		}
		// Anything but a declaration of decl_pkg, such as a polymorphic parameter, has no name here.
		if decl_pkg == "" || decl_pkg == "$builtin" || strings.contains(n.name, "/") {
			return false
		}
		if _, found := memory_index_lookup(&indexer.index, n.name, decl_pkg); !found {
			return false
		}
		alias := package_alias(ctx, decl_pkg, edits) or_return
		if alias != "" {
			strings.write_string(sb, alias)
			strings.write_byte(sb, '.')
		}
		strings.write_string(sb, n.name)
	case ^ast.Selector_Expr:
		base, is_ident := n.expr.derived.(^ast.Ident)
		if !is_ident || n.field == nil {
			return false
		}
		alias: string
		if strings.contains(base.name, "/") {
			// The indexer replaced the declaring file's alias with the package directory.
			alias = package_alias(ctx, base.name, edits) or_return
		} else if node.pos.file == ctx.document.fullpath && document_imports_alias(ctx.document, base.name) {
			alias = base.name
		} else {
			return false
		}
		if alias != "" {
			strings.write_string(sb, alias)
			strings.write_byte(sb, '.')
		}
		strings.write_string(sb, n.field.name)
	case ^ast.Basic_Lit:
		strings.write_string(sb, n.tok.text)
	case ^ast.Paren_Expr:
		return write_requalified_type(sb, ctx, n.expr, decl_pkg, edits)
	case ^ast.Pointer_Type:
		if n.tag != nil {
			return false
		}
		strings.write_byte(sb, '^')
		return write_requalified_type(sb, ctx, n.elem, decl_pkg, edits)
	case ^ast.Multi_Pointer_Type:
		strings.write_string(sb, "[^]")
		return write_requalified_type(sb, ctx, n.elem, decl_pkg, edits)
	case ^ast.Array_Type:
		if n.tag != nil {
			return false
		}
		strings.write_byte(sb, '[')
		if n.len != nil && !write_requalified_type(sb, ctx, n.len, decl_pkg, edits) {
			return false
		}
		strings.write_byte(sb, ']')
		return write_requalified_type(sb, ctx, n.elem, decl_pkg, edits)
	case ^ast.Dynamic_Array_Type:
		if n.tag != nil {
			return false
		}
		strings.write_string(sb, "[dynamic]")
		return write_requalified_type(sb, ctx, n.elem, decl_pkg, edits)
	case ^ast.Map_Type:
		strings.write_string(sb, "map[")
		if !write_requalified_type(sb, ctx, n.key, decl_pkg, edits) {
			return false
		}
		strings.write_byte(sb, ']')
		return write_requalified_type(sb, ctx, n.value, decl_pkg, edits)
	case ^ast.Union_Type:
		if n.poly_params != nil || n.align != nil || len(n.where_clauses) > 0 || n.kind == .maybe {
			return false
		}
		strings.write_string(sb, "union")
		#partial switch n.kind {
		case .no_nil:
			strings.write_string(sb, " #no_nil")
		case .shared_nil:
			strings.write_string(sb, " #shared_nil")
		}
		strings.write_string(sb, " {")
		for variant, i in n.variants {
			if i > 0 {
				strings.write_string(sb, ", ")
			}
			if !write_requalified_type(sb, ctx, variant, decl_pkg, edits) {
				return false
			}
		}
		strings.write_byte(sb, '}')
	case ^ast.Struct_Type:
		if n.poly_params != nil ||
		   n.align != nil ||
		   n.min_field_align != nil ||
		   n.max_field_align != nil ||
		   len(n.where_clauses) > 0 ||
		   n.is_packed ||
		   n.is_raw_union ||
		   n.is_no_copy ||
		   n.is_all_or_none {
			return false
		}
		strings.write_string(sb, "struct {")
		if !write_requalified_fields(sb, ctx, n.fields, decl_pkg, edits) {
			return false
		}
		strings.write_byte(sb, '}')
	case ^ast.Proc_Type:
		if n.generic || n.diverging || n.tags != {} || n.calling_convention != nil {
			return false
		}
		strings.write_string(sb, "proc(")
		if !write_requalified_fields(sb, ctx, n.params, decl_pkg, edits) {
			return false
		}
		strings.write_byte(sb, ')')
		if n.results == nil || len(n.results.list) == 0 {
			return true
		}
		strings.write_string(sb, " -> ")
		results := n.results.list
		if len(results) == 1 && !field_has_names(results[0]) {
			return write_requalified_type(sb, ctx, results[0].type, decl_pkg, edits)
		}
		strings.write_byte(sb, '(')
		if !write_requalified_fields(sb, ctx, n.results, decl_pkg, edits) {
			return false
		}
		strings.write_byte(sb, ')')
	case:
		return false
	}
	return true
}

// The parser gives an unnamed parameter or result a synthesised name at its type's position.
@(private = "file")
field_has_names :: proc(field: ^ast.Field) -> bool {
	for name in field.names {
		if field.type == nil || name.pos.offset != field.type.pos.offset {
			return true
		}
	}
	return false
}

@(private = "file")
write_requalified_fields :: proc(
	sb: ^strings.Builder,
	ctx: ^ActionContext,
	fields: ^ast.Field_List,
	decl_pkg: string,
	edits: ^[dynamic]TextEdit,
) -> bool {
	if fields == nil {
		return true
	}
	UNPRINTED :: ast.Field_Flags {
		.Ellipsis,
		.Using,
		.No_Alias,
		.C_Vararg,
		.Const,
		.Any_Int,
		.Subtype,
		.By_Ptr,
		.No_Broadcast,
		.No_Capture,
	}
	for field, i in fields.list {
		if field.type == nil || field.default_value != nil || field.tag.text != "" || field.flags & UNPRINTED != {} {
			return false
		}
		if i > 0 {
			strings.write_string(sb, ", ")
		}
		if field_has_names(field) {
			for name, j in field.names {
				ident, is_ident := name.derived.(^ast.Ident)
				if !is_ident {
					return false
				}
				if j > 0 {
					strings.write_string(sb, ", ")
				}
				strings.write_string(sb, ident.name)
			}
			strings.write_string(sb, ": ")
		}
		if !write_requalified_type(sb, ctx, field.type, decl_pkg, edits) {
			return false
		}
	}
	return true
}

@(private = "file")
document_imports_alias :: proc(document: ^Document, alias: string) -> bool {
	for imp in document.imports {
		if imp.base == alias {
			return true
		}
	}
	return false
}

// How the current document names the package in directory dir: "" for its own package, else the
// import alias. An unimported package gets its directory name and an import appended to edits,
// unless that name is already taken.
package_alias :: proc(ctx: ^ActionContext, dir: string, edits: ^[dynamic]TextEdit) -> (string, bool) {
	if dir == ctx.ast_context.document_package {
		return "", true
	}
	for imp in ctx.document.imports {
		if imp.name == dir {
			return imp.base, true
		}
	}
	if dir not_in indexer.index.collection.packages {
		return "", false
	}
	import_path, has_path := package_import_path(ctx, dir)
	if !has_path {
		return "", false
	}
	alias := filepath.base(dir)
	// Any local gathered so far counts, including the parameters.
	probe: ast.Ident
	probe.name = alias
	probe.pos.offset = len(ctx.document.ast.src)
	if alias in keyword_map || is_taken(ctx, probe) || document_imports_alias(ctx.document, alias) {
		return "", false
	}
	append_import_edit(edits, import_edit(ctx, import_path))
	return alias, true
}

// `collection:rest` for the collection with the longest root containing dir, else dir relative to
// the current package. Import paths use '/' on every platform.
@(private = "file")
package_import_path :: proc(ctx: ^ActionContext, dir: string) -> (string, bool) {
	dir, _ := filepath.replace_separators(dir, '/', context.temp_allocator)
	best := ""
	best_len := -1
	for name, root in ctx.config.collections {
		root, _ := filepath.replace_separators(root, '/', context.temp_allocator)
		root = strings.trim_right(root, "/")
		if len(root) > best_len && len(dir) > len(root) && dir[len(root)] == '/' && strings.has_prefix(dir, root) {
			best = fmt.tprintf("%s:%s", name, dir[len(root) + 1:])
			best_len = len(root)
		}
	}
	if best_len >= 0 {
		return best, true
	}
	rel, err := filepath.rel(ctx.ast_context.document_package, dir, context.temp_allocator)
	if err != .None {
		return "", false
	}
	rel, _ = filepath.replace_separators(rel, '/', context.temp_allocator)
	return rel, true
}

// Drops an action whose title and edits equal an earlier one, as two providers can offer the same
// fix, such as a lint quick fix and a refactoring. The kept action takes over isPreferred, and the
// quickfix kind when either has it. Titles that still occur more than once get the first line of
// the code the action replaces in this document, shortened. A title that is still shared after
// that gets its position among the equal ones. Unique titles stay as they are, so an editor shows
// the usual text.
make_titles_distinct :: proc(document: ^Document, actions: ^[dynamic]CodeAction) {
	MAX_SNIPPET :: 40
	same_edits :: proc(a, b: CodeAction) -> bool {
		if len(a.edit.changes) != len(b.edit.changes) do return false
		for uri, edits in a.edit.changes {
			other, found := b.edit.changes[uri]
			if !found || len(edits) != len(other) do return false
			for edit, i in edits {
				if edit.range != other[i].range || edit.newText != other[i].newText do return false
			}
		}
		// Document changes hold file operations; compare their printed form.
		return fmt.tprintf("%v", a.edit.documentChanges) == fmt.tprintf("%v", b.edit.documentChanges)
	}
	for i := 0; i < len(actions); i += 1 {
		for j := 0; j < i; j += 1 {
			if actions[j].title == actions[i].title && same_edits(actions[j], actions[i]) {
				actions[j].isPreferred ||= actions[i].isPreferred
				if actions[i].kind == "quickfix" do actions[j].kind = "quickfix"
				ordered_remove(actions, i)
				i -= 1
				break
			}
		}
	}

	text := document.text[:document.used_text]
	counts := make(map[string]int, context.temp_allocator)
	for action in actions do counts[action.title] += 1
	for &action in actions {
		if counts[action.title] < 2 do continue
		edits := action.edit.changes[document.uri.uri]
		if len(edits) == 0 do continue
		range, ok := common.get_absolute_range(edits[0].range, text)
		if !ok || range.start >= range.end do continue
		snippet := string(text[range.start:range.end])
		if newline := strings.index_byte(snippet, '\n'); newline >= 0 {
			snippet = snippet[:newline]
		}
		snippet = strings.trim_space(snippet)
		if cut := utf8.rune_offset(snippet, MAX_SNIPPET); cut >= 0 {
			snippet = strings.concatenate({snippet[:cut], "..."}, context.temp_allocator)
		}
		if snippet != "" {
			action.title = fmt.aprintf("%s (%s)", action.title, snippet, allocator = context.temp_allocator)
		}
	}
	seen := make(map[string]int, context.temp_allocator)
	counts = make(map[string]int, context.temp_allocator)
	for action in actions do counts[action.title] += 1
	for &action in actions {
		if counts[action.title] < 2 do continue
		seen[action.title] += 1
		action.title = fmt.aprintf("%s #%d", action.title, seen[action.title], allocator = context.temp_allocator)
	}
}

// Symbol types of values. Types other than structs, unions and enums, such as distinct ones, are
// indexed as unresolved, so a type declaration is told apart by ruling these out.
VALUE_SYMBOL_TYPES :: bit_set[SymbolType]{.Function, .Field, .Variable, .Package, .Keyword, .EnumMember, .Constant}

// A builtin type name that the package does not declare as a type visible to other files. A
// constant such as `string :: "x"` is indexed as unresolved like a distinct type, so a literal or
// operator value tells it apart. A constant with a call or a name as value still counts as a type.
builtin_without_decl :: proc(name, pkg: string) -> bool {
	if !is_builtin_type_name(name) {
		return false
	}
	symbol, found := memory_index_lookup(&indexer.index, name, pkg)
	if !found || symbol.type in VALUE_SYMBOL_TYPES || .PrivateFile in symbol.flags {
		return true
	}
	if symbol.value_expr != nil {
		#partial switch _ in symbol.value_expr.derived {
		case ^ast.Basic_Lit, ^ast.Unary_Expr, ^ast.Binary_Expr, ^ast.Comp_Lit:
			return true
		}
	}
	return false
}
