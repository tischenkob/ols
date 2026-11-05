#+private file

package server

import "core:odin/ast"
import "core:strings"

import "src:common"

@(private = "package")
add_split_merge_if_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_split_merge_if {
		return
	}

	add_split_or(ctx)

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

// `if a || b { … }` as two ifs with a copy of the body each, split at the `||` under the cursor or
// else at the last one. The else-if form behaves the same; separate ifs run the body twice when both
// conditions hold, and are refused where the second if would leave the first one's scope or parent.
add_split_or :: proc(ctx: ^ActionContext) {
	src := ctx.document.ast.src

	if_stmt, parent := if_head_at(ctx)
	if if_stmt == nil || if_stmt.cond == nil || if_stmt.body == nil {
		return
	}
	body, is_block := if_stmt.body.derived.(^ast.Block_Stmt)
	if !is_block || ctx.range.start > body.pos.offset || has_label(body) {
		return
	}
	// A `do` body starts at its statement, so this position is already inside the body.
	if body.uses_do && ctx.range.start == body.pos.offset {
		return
	}

	cond := if_stmt.cond
	if paren, ok := cond.derived.(^ast.Paren_Expr); ok {
		cond = paren.expr
	}
	split := or_at_cursor(cond, ctx.range.start)
	if split == nil || head_hides_comment(src, if_stmt, body, cond, split) {
		return
	}

	left_text := unparen_text(src, split.left)
	right_text := src[split.right.pos.offset:cond.end.offset]
	if split == cond {
		right_text = unparen_text(src, split.right)
		if strings.trim_space(src[split.right.end.offset:cond.end.offset]) != "" {
			return
		}
	}
	if ends_in_line_comment(left_text) || ends_in_line_comment(right_text) {
		return
	}
	left := head_cond(left_text)
	right := head_cond(right_text)

	first: ^ast.Node
	if !body.uses_do && len(body.stmts) > 0 {
		first = body.stmts[0]
	}
	ind := get_line_indentation(src, if_stmt.pos.offset)
	unit := indent_unit(src, ind, first)
	lines := block_lines(src, body, ind, unit)

	sb := strings.builder_make(context.temp_allocator)
	write_if_head(&sb, src, if_stmt, left)
	write_split_body(&sb, lines, ind)
	head_len := strings.builder_len(sb)

	strings.write_string(&sb, " else if ")
	strings.write_string(&sb, right)
	strings.write_string(&sb, " {\n")
	write_split_body(&sb, lines, ind)
	strings.write_string(&sb, src[body.end.offset:if_stmt.end.offset])
	append_split_or(ctx, if_stmt, "Split || into else-if", strings.to_string(sb))

	if !separate_ifs_allowed(src, if_stmt, parent) {
		return
	}
	resize(&sb.buf, head_len)
	strings.write_byte(&sb, '\n')
	strings.write_string(&sb, ind)
	strings.write_string(&sb, "if ")
	strings.write_string(&sb, right)
	strings.write_string(&sb, " {\n")
	write_split_body(&sb, lines, ind)
	append_split_or(ctx, if_stmt, "Split || into separate ifs", strings.to_string(sb))
}

// The innermost if containing the cursor, also when it is an else-if, and its parent.
if_head_at :: proc(ctx: ^ActionContext) -> (^ast.If_Stmt, ^ast.Node) {
	#reverse for at in nodes_at(ctx.document.ast.decls[:], ctx.range.start) {
		if if_stmt, ok := at.node.derived.(^ast.If_Stmt); ok {
			return if_stmt, at.parent
		}
	}
	return nil, nil
}

// The top-level `||` under the cursor, else the root one, which is the last because `||` is left
// associative. Nil when the condition is not a `||`.
or_at_cursor :: proc(cond: ^ast.Expr, cursor: int) -> ^ast.Binary_Expr {
	root, ok := cond.derived.(^ast.Binary_Expr)
	if !ok || root.op.kind != .Cmp_Or {
		return nil
	}
	for cur := root; cur != nil; {
		start := cur.op.pos.offset
		if start <= cursor && cursor <= start + len("||") {
			return cur
		}
		left, is_binary := cur.left.derived.(^ast.Binary_Expr)
		cur = left if is_binary && left.op.kind == .Cmp_Or else nil
	}
	return root
}

// The split rebuilds the head from its conditions, so a comment outside them would be lost.
head_hides_comment :: proc(
	src: string,
	if_stmt: ^ast.If_Stmt,
	body: ^ast.Block_Stmt,
	cond: ^ast.Expr,
	split: ^ast.Binary_Expr,
) -> bool {
	blank :: proc(src: string, start, end: int) -> bool {
		return strings.trim_space(src[start:end]) == ""
	}
	paren_blank :: proc(src: string, expr: ^ast.Expr) -> bool {
		paren, ok := expr.derived.(^ast.Paren_Expr)
		return(
			!ok ||
			(blank(src, paren.pos.offset + 1, paren.expr.pos.offset) &&
					blank(src, paren.expr.end.offset, paren.end.offset - 1)) \
		)
	}

	head := if_stmt.init.pos.offset if if_stmt.init != nil else if_stmt.cond.pos.offset
	if !blank(src, if_stmt.pos.offset + len("if"), head) {
		return true
	}
	if if_stmt.init != nil && strings.trim_space(src[if_stmt.init.end.offset:if_stmt.cond.pos.offset]) != ";" {
		return true
	}
	// A `do` body starts at its statement, after the `do`.
	tail := strings.trim_space(src[if_stmt.cond.end.offset:body.pos.offset])
	if tail != "" && !(body.uses_do && tail == "do") {
		return true
	}
	op := split.op.pos.offset
	return(
		!blank(src, split.left.end.offset, op) ||
		!blank(src, op + len("||"), split.right.pos.offset) ||
		!paren_blank(src, if_stmt.cond) ||
		!paren_blank(src, split.left) ||
		!paren_blank(src, split.right) \
	)
}

// Inside parentheses a binary expression ends after the newline and any comment before it, so its
// text can end in a line comment, which would swallow the ` {` or `)` written after it. Text without
// that newline cannot. A `//` in a string on the last line before such a newline also refuses, which
// is the safe direction.
ends_in_line_comment :: proc(text: string) -> bool {
	if !strings.has_suffix(text, "\n") {
		return false
	}
	trimmed := strings.trim_space(text)
	last := trimmed[strings.last_index_byte(trimmed, '\n') + 1:]
	return strings.contains(last, "//") || strings.contains(last, "#!")
}

// Odin rejects a bare composite literal in an if head, and a line break there can end the condition,
// so text holding either gets parentheses.
head_cond :: proc(text: string) -> string {
	text := strings.trim_space(text)
	if strings.contains_any(text, "{\r\n") {
		return strings.concatenate({"(", text, ")"}, context.temp_allocator)
	}
	return text
}

// Odin rejects a label that a procedure declares twice, and a nested procedure is a procedure of its own.
has_label :: proc(body: ^ast.Block_Stmt) -> bool {
	found: bool
	visitor := ast.Visitor {
		data = &found,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			found := (^bool)(visitor.data)
			if node == nil || found^ {
				return nil
			}
			#partial switch n in node.derived {
			case ^ast.Proc_Lit:
				return nil
			case ^ast.Block_Stmt:
				found^ = n.label != nil
			case ^ast.If_Stmt:
				found^ = n.label != nil
			case ^ast.For_Stmt:
				found^ = n.label != nil
			case ^ast.Range_Stmt:
				found^ = n.label != nil
			case ^ast.Unroll_Range_Stmt:
				found^ = n.label != nil
			case ^ast.Switch_Stmt:
				found^ = n.label != nil
			case ^ast.Type_Switch_Stmt:
				found^ = n.label != nil
			}
			return visitor
		},
	}
	ast.walk(&visitor, body)
	return found
}

// The second if must sit next to the first in a statement list, on its own line, and nothing may
// tie it to the first: an else, an init whose scope it needs, a label its copy of the body breaks to.
separate_ifs_allowed :: proc(src: string, if_stmt: ^ast.If_Stmt, parent: ^ast.Node) -> bool {
	if if_stmt.else_stmt != nil || if_stmt.init != nil || if_stmt.label != nil || parent == nil {
		return false
	}
	#partial switch p in parent.derived {
	case ^ast.Block_Stmt:
		if p.uses_do {
			return false
		}
	case ^ast.Case_Clause:
	case:
		return false
	}
	start, end := before_on_line(src, if_stmt.pos.offset)
	return start == end
}

write_split_body :: proc(sb: ^strings.Builder, lines, ind: string) {
	if len(lines) > 0 {
		strings.write_string(sb, lines)
		strings.write_byte(sb, '\n')
	}
	strings.write_string(sb, ind)
	strings.write_byte(sb, '}')
}

// The text is cloned because the two actions share one builder.
append_split_or :: proc(ctx: ^ActionContext, if_stmt: ^ast.If_Stmt, title, text: string) {
	src := ctx.document.ast.src
	matched := match_line_endings(src, if_stmt.pos.offset, strings.clone(text, context.temp_allocator))
	append_replace(ctx, if_stmt, title, matched)
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
	cond := strings.concatenate(
		{operand_text(src, if_stmt.cond), " && ", operand_text(src, inner.cond)},
		context.temp_allocator,
	)
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
	// A group call with no matching overload: the resolve with the locals at the callee returns every member.
	ast_context: AstContext
	position_context: DocumentPositionContext
	if ast_context_at(
		document,
		common.get_token_range(callee^, document.ast.src).start,
		&ast_context,
		&position_context,
	) {
		if symbol, found := resolve_type_expression(&ast_context, callee); found {
			return symbol_deferred(symbol)
		}
	}
	return true
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
