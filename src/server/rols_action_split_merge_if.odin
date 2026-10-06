#+private file

package server

import "core:odin/ast"
import "core:strings"

@(private = "package")
add_split_merge_if_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_split_merge_if {
		return
	}

	if_stmt := find_if_stmt_at_position(ctx.document.ast.decls[:], ctx.range.start)
	if if_stmt == nil || if_stmt.else_stmt != nil || if_stmt.label != nil || if_stmt.body == nil {
		return
	}
	body, is_block := if_stmt.body.derived.(^ast.Block_Stmt)
	if !is_block || body.uses_do {
		return
	}

	add_split_if(ctx, if_stmt, body)
	if text, ok := merge_if_text(ctx.document.ast.src, if_stmt); ok && !merge_calls_deferred(ctx.document, if_stmt) {
		append_replace(ctx, if_stmt, "Merge nested if", text)
	}
}

add_split_if :: proc(ctx: ^ActionContext, if_stmt: ^ast.If_Stmt, body: ^ast.Block_Stmt) {
	src := ctx.document.ast.src

	cond := if_stmt.cond
	if paren, ok := cond.derived.(^ast.Paren_Expr); ok {
		cond = paren.expr
	}
	bin, is_binary := cond.derived.(^ast.Binary_Expr)
	if !is_binary || bin.op.kind != .Cmp_And {
		return
	}

	first: ^ast.Node
	if len(body.stmts) > 0 {
		first = body.stmts[0]
	}
	ind := get_line_indentation(src, if_stmt.pos.offset)
	unit := indent_unit(src, ind, first)
	deeper := strings.concatenate({ind, unit}, context.temp_allocator)

	sb := strings.builder_make(context.temp_allocator)
	write_if_head(&sb, src, if_stmt, unparen_text(src, bin.left))
	strings.write_string(&sb, deeper)
	strings.write_string(&sb, "if ")
	strings.write_string(&sb, unparen_text(src, bin.right))
	strings.write_string(&sb, " {\n")
	if inner := block_inner_text(src, body); len(inner) > 0 {
		strings.write_string(&sb, reindent(inner, deeper, strings.concatenate({deeper, unit}, context.temp_allocator)))
		strings.write_byte(&sb, '\n')
	}
	strings.write_string(&sb, deeper)
	strings.write_string(&sb, "}\n")
	strings.write_string(&sb, ind)
	strings.write_string(&sb, "}")

	append_replace(ctx, if_stmt, "Split if", strings.to_string(sb))
}

// `if a { if b { … } }` as `if a && b { … }`.
@(private = "package")
merge_if_text :: proc(src: string, if_stmt: ^ast.If_Stmt) -> (string, bool) {
	if if_stmt.else_stmt != nil || if_stmt.label != nil || if_stmt.body == nil {
		return "", false
	}
	body, is_body_block := if_stmt.body.derived.(^ast.Block_Stmt)
	// A `do` body has no braces: its `open` is the statement's own position, so the slices below
	// would cut into the statement.
	if !is_body_block || body.uses_do || len(body.stmts) != 1 {
		return "", false
	}
	inner, is_if := body.stmts[0].derived.(^ast.If_Stmt)
	if !is_if || inner.else_stmt != nil || inner.init != nil || inner.label != nil || inner.body == nil {
		return "", false
	}
	inner_body, is_block := inner.body.derived.(^ast.Block_Stmt)
	if !is_block || inner_body.uses_do {
		return "", false
	}

	// Anything besides whitespace around the inner if is a comment that would be lost.
	if strings.trim_space(src[body.open.offset + 1:inner.pos.offset]) != "" ||
	   strings.trim_space(src[inner.end.offset:body.close.offset]) != "" {
		return "", false
	}

	// rols: a comment between a condition and its brace would be lost as well.
	// The head is rebuilt too, so a comment before the condition is lost.
	head := if_stmt.init.pos.offset if if_stmt.init != nil else if_stmt.cond.pos.offset
	if strings.trim_space(src[if_stmt.cond.end.offset:body.open.offset]) != "" ||
	   strings.trim_space(src[inner.cond.end.offset:inner_body.open.offset]) != "" ||
	   strings.trim_space(src[if_stmt.pos.offset + len("if"):head]) != "" ||
	   (if_stmt.init != nil && strings.trim_space(src[if_stmt.init.end.offset:if_stmt.cond.pos.offset]) != ";") ||
	   strings.trim_space(src[inner.pos.offset + len("if"):inner.cond.pos.offset]) != "" {
		return "", false
	}

	ind := get_line_indentation(src, if_stmt.pos.offset)
	unit := indent_unit(src, ind, inner)
	deeper := strings.concatenate({ind, unit}, context.temp_allocator)

	sb := strings.builder_make(context.temp_allocator)
	cond := strings.concatenate({operand_text(src, if_stmt.cond), " && ", operand_text(src, inner.cond)}, context.temp_allocator)
	write_if_head(&sb, src, if_stmt, cond)
	if text := block_inner_text(src, inner_body); len(text) > 0 {
		strings.write_string(&sb, reindent(text, strings.concatenate({deeper, unit}, context.temp_allocator), deeper))
		strings.write_byte(&sb, '\n')
	}
	strings.write_string(&sb, ind)
	strings.write_string(&sb, "}")
	return strings.to_string(sb), true
}

// Odin rejects a call to a procedure with a deferred_* attribute inside `&&`, so merging fails
// when either condition of `if a { if b { … } }` makes one. merge_if_text is syntactic; this
// resolves the callees. A named callee that does not resolve counts as deferred.
@(private = "package")
merge_calls_deferred :: proc(document: ^Document, node: ^ast.Node) -> bool {
	if_stmt := node.derived.(^ast.If_Stmt) or_return
	if if_stmt.body == nil do return false
	body := if_stmt.body.derived.(^ast.Block_Stmt) or_return
	if len(body.stmts) != 1 do return false
	inner := body.stmts[0].derived.(^ast.If_Stmt) or_return
	return calls_deferred(document, if_stmt.cond) || calls_deferred(document, inner.cond)
}

calls_deferred :: proc(document: ^Document, expr: ^ast.Expr) -> bool {
	Search :: struct {
		document: ^Document,
		resolved: SymbolAndNodeMap,
		found:    bool,
	}
	if expr == nil do return false
	search := Search{document, resolve_entire_file(document), false}
	visitor := ast.Visitor {
		data = &search,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			search := (^Search)(visitor.data)
			if node == nil || search.found do return nil
			#partial switch n in node.derived {
			case ^ast.Proc_Lit:
				// A call in a nested body is not part of the condition's expression.
				return nil
			case ^ast.Call_Expr:
				#partial switch _ in n.expr.derived {
				case ^ast.Ident, ^ast.Selector_Expr:
					search.found = callee_deferred(search.document, search.resolved, n.expr)
				}
			}
			return visitor
		},
	}
	ast.walk(&visitor, expr)
	return search.found
}

callee_deferred :: proc(document: ^Document, resolved_map: SymbolAndNodeMap, callee: ^ast.Expr) -> bool {
	resolved, ok := resolved_map[uintptr(callee)]
	if ok && !resolved.is_unresolved && resolved.symbol != nil {
		if _, is_group := resolved.symbol.value.(SymbolProcedureGroupValue); !is_group {
			return symbol_deferred(resolved.symbol^)
		}
	}
	// A group call whose overload does not resolve: without a call, the resolve returns every member.
	symbol, found := resolve_type_in_package(document, document.package_name, callee)
	if !found do return true
	if _, is_group := symbol.value.(SymbolProcedureGroupValue); is_group do return true
	return symbol_deferred(symbol)
}

symbol_deferred :: proc(symbol: Symbol) -> bool {
	#partial switch v in symbol.value {
	case SymbolProcedureValue:
		for name in attribute_names(v.attributes) {
			if strings.has_prefix(name, "deferred_") do return true
		}
	case SymbolAggregateValue:
		for member in v.symbols {
			if symbol_deferred(member) do return true
		}
	}
	return false
}

write_if_head :: proc(sb: ^strings.Builder, src: string, if_stmt: ^ast.If_Stmt, cond: string) {
	strings.write_string(sb, "if ")
	if if_stmt.init != nil {
		strings.write_string(sb, src[if_stmt.init.pos.offset:if_stmt.init.end.offset])
		strings.write_string(sb, "; ")
	}
	strings.write_string(sb, cond)
	strings.write_string(sb, " {\n")
}

unparen_text :: proc(src: string, expr: ^ast.Expr) -> string {
	if paren, ok := expr.derived.(^ast.Paren_Expr); ok {
		return src[paren.expr.pos.offset:paren.expr.end.offset]
	}
	return src[expr.pos.offset:expr.end.offset]
}

// Operand of a generated `&&`, parenthesised when it binds looser than `&&` or when Odin requires it,
// as for `or_return`, `or_break` and `or_continue`.
operand_text :: proc(src: string, expr: ^ast.Expr) -> string {
	text := src[expr.pos.offset:expr.end.offset]
	wrap := false
	#partial switch e in expr.derived {
	case ^ast.Binary_Expr:
		wrap = e.op.kind == .Cmp_Or
	case ^ast.Ternary_If_Expr, ^ast.Ternary_When_Expr, ^ast.Or_Else_Expr, ^ast.Or_Return_Expr, ^ast.Or_Branch_Expr:
		wrap = true
	}
	if wrap {
		return strings.concatenate({"(", text, ")"}, context.temp_allocator)
	}
	return text
}

append_replace :: proc(ctx: ^ActionContext, if_stmt: ^ast.If_Stmt, title: string, text: string) {
	edits := make([]TextEdit, 1, context.temp_allocator)
	edits[0] = TextEdit {
		range   = range_of(ctx, if_stmt.pos.offset, if_stmt.end.offset),
		newText = text,
	}
	append(ctx.actions, make_code_action(ctx, title, "refactor.rewrite", edits))
}
