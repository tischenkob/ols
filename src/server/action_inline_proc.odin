#+private file

package server

import "core:odin/ast"
import "core:odin/parser"
import "core:strings"

Param :: struct {
	name: string,
	type: string, // in the callee's source
	arg:  ^ast.Expr,
}

@(private = "package")
add_inline_proc_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_inline_proc {
		return
	}
	function := ctx.position_context.function
	if function == nil || function.body == nil {
		return
	}

	call: ^ast.Call_Expr
	parent: ^ast.Node
	#reverse for at in nodes_at({function.body}, ctx.range.start) {
		if c, is_call := at.node.derived.(^ast.Call_Expr); is_call {
			call, parent = c, at.parent
			break
		}
	}
	if call == nil || parent == nil || call.ellipsis.kind != .Invalid {
		return
	}
	callee_ident, is_ident := call.expr.derived.(^ast.Ident)
	if !is_ident {
		return
	}
	for arg in call.args {
		if _, named := arg.derived.(^ast.Field_Value); named {
			return
		}
	}

	resolved, is_resolved := resolve_entire_file(ctx.document)[uintptr(call.expr)]
	if !is_resolved {
		return
	}
	symbol := resolved.symbol
	callee, is_proc := symbol.value.(SymbolProcedureValue)
	if !is_proc || .Local in symbol.flags || symbol.pkg != ctx.ast_context.document_package {
		return
	}
	if callee.generic || len(callee.where_clauses) > 0 {
		return
	}
	for name in attribute_names(callee.attributes) {
		if name == "export" || name == "link_name" || strings.has_prefix(name, "deferred_") {
			return
		}
	}

	target, lit := find_proc_lit(ctx, symbol)
	if lit == nil || lit.body == nil || lit.type == nil {
		return
	}
	body, is_block := lit.body.derived.(^ast.Block_Stmt)
	if !is_block || len(body.stmts) == 0 {
		return
	}
	callee_src := target.ast.src

	params := make([dynamic]Param, context.temp_allocator)
	if lit.type.params != nil {
		for field in lit.type.params.list {
			if field.flags & {.Using, .Ellipsis, .C_Vararg} != {} {
				return
			}
			if _, variadic := field.type.derived.(^ast.Ellipsis); variadic {
				return
			}
			for name in field.names {
				ident := name.derived.(^ast.Ident) or_else nil
				if ident == nil {
					return
				}
				append(&params, Param{ident.name, node_text(callee_src, field.type), nil})
			}
		}
	}
	if len(params) != len(call.args) {
		return
	}
	for &param, i in params {
		param.arg = call.args[i]
	}

	if stmt, is_stmt := parent.derived.(^ast.Expr_Stmt); is_stmt {
		inline_statement(ctx, stmt, body, params[:], callee_src)
		return
	}
	if len(field_types(callee.return_types)) != 1 || len(body.stmts) != 1 {
		return
	}
	ret, is_return := body.stmts[0].derived.(^ast.Return_Stmt)
	if !is_return || len(ret.results) != 1 {
		return
	}
	inline_expression(ctx, call, parent, ret.results[0], params[:], callee_src)
}

// Every parameter occurrence becomes its argument. An argument with a call is passed through
// once or not at all, never duplicated or dropped.
inline_expression :: proc(
	ctx: ^ActionContext,
	call: ^ast.Call_Expr,
	parent: ^ast.Node,
	expr: ^ast.Expr,
	params: []Param,
	callee_src: string,
) {
	src := ctx.document.ast.src
	counts := make([]int, len(params), context.temp_allocator)

	Replacement :: struct {
		start, end: int,
		text:       string,
	}
	replacements := make([dynamic]Replacement, context.temp_allocator)

	for use in collect_ident_uses(expr) {
		i := param_index(params, use)
		if i < 0 {
			continue
		}
		for p in use.parents {
			if _, is_proc := p.derived.(^ast.Proc_Lit); is_proc {
				return
			}
		}
		if len(use.parents) > 0 {
			if unary, is_unary := use.parents[len(use.parents) - 1].derived.(^ast.Unary_Expr); is_unary && unary.op.kind == .And {
				return
			}
		}
		counts[i] += 1
		text := node_text(src, params[i].arg)
		if !is_atom(params[i].arg) {
			text = strings.concatenate({"(", text, ")"}, context.temp_allocator)
		}
		append(&replacements, Replacement{use.ident.pos.offset, use.ident.end.offset, text})
	}
	for param, i in params {
		if counts[i] != 1 && has_side_effect(param.arg) {
			return
		}
	}

	sb := strings.builder_make(context.temp_allocator)
	at := expr.pos.offset
	for r in replacements {
		strings.write_string(&sb, callee_src[at:r.start])
		strings.write_string(&sb, r.text)
		at = r.end
	}
	strings.write_string(&sb, callee_src[at:expr.end.offset])
	text := strings.to_string(sb)

	if needs_parens(expr, parent, call) {
		text = strings.concatenate({"(", text, ")"}, context.temp_allocator)
	}
	edits := make([]TextEdit, 1, context.temp_allocator)
	edits[0] = {
		range   = range_of(ctx, call.pos.offset, call.end.offset),
		newText = text,
	}
	append(ctx.actions, make_code_action(ctx, "Inline procedure call", "refactor.inline", edits))
}

// The body becomes a bare block, with a typed local per parameter the body reads. Passing a
// variable of the parameter's own name needs no local.
inline_statement :: proc(
	ctx: ^ActionContext,
	stmt: ^ast.Expr_Stmt,
	body: ^ast.Block_Stmt,
	params: []Param,
	callee_src: string,
) {
	if !plain_body(body) {
		return
	}
	src := ctx.document.ast.src

	used := make([]bool, len(params), context.temp_allocator)
	for use in collect_ident_uses(body) {
		if i := param_index(params, use); i >= 0 {
			used[i] = true
		}
	}

	ind := get_line_indentation(src, stmt.pos.offset)
	unit := indent_unit(src, ind, nil)
	inner := strings.concatenate({ind, unit}, context.temp_allocator)

	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "{\n")
	for param, i in params {
		arg := node_text(src, param.arg)
		if !used[i] {
			if has_side_effect(param.arg) {
				return
			}
			continue
		}
		if arg == param.name {
			continue
		}
		// Locals declared above would capture a later argument that names them.
		for use in collect_ident_uses(param.arg) {
			if param_index(params, use) >= 0 {
				return
			}
		}
		strings.write_string(&sb, inner)
		strings.write_string(&sb, param.name)
		strings.write_string(&sb, ": ")
		strings.write_string(&sb, param.type)
		strings.write_string(&sb, " = ")
		strings.write_string(&sb, arg)
		strings.write_byte(&sb, '\n')
	}
	from := get_line_indentation(callee_src, body.stmts[0].pos.offset)
	strings.write_string(&sb, reindent(block_inner_text(callee_src, body), from, inner))
	strings.write_byte(&sb, '\n')
	strings.write_string(&sb, ind)
	strings.write_byte(&sb, '}')

	edits := make([]TextEdit, 1, context.temp_allocator)
	edits[0] = {
		range   = range_of(ctx, stmt.pos.offset, stmt.end.offset),
		newText = strings.to_string(sb),
	}
	append(ctx.actions, make_code_action(ctx, "Inline procedure call", "refactor.inline", edits))
}

// The current document first: a file-private callee shadows a package one of the same name.
find_proc_lit :: proc(ctx: ^ActionContext, symbol: Symbol) -> (^Document, ^ast.Proc_Lit) {
	if lit := proc_lit_named(ctx.document, symbol.name); lit != nil {
		return ctx.document, lit
	}
	h := Call_Hierarchy{{}, make(map[string]^Document, context.temp_allocator)}
	document := hierarchy_document(&h, symbol.uri)
	if document == nil {
		return nil, nil
	}
	return document, proc_lit_named(document, symbol.name)
}

proc_lit_named :: proc(document: ^Document, name: string) -> ^ast.Proc_Lit {
	for decl in top_level_value_decls(document.ast) {
		if len(decl.names) != 1 || len(decl.values) != 1 || final_name(decl.names[0]) != name {
			continue
		}
		return decl.values[0].derived.(^ast.Proc_Lit) or_else nil
	}
	return nil
}

// Index of the parameter the use reads, or -1 for other names and for field names.
param_index :: proc(params: []Param, use: IdentUse) -> int {
	if len(use.parents) > 0 {
		#partial switch p in use.parents[len(use.parents) - 1].derived {
		case ^ast.Selector_Expr:
			if p.field == use.ident {
				return -1
			}
		case ^ast.Implicit_Selector_Expr:
			return -1
		case ^ast.Field_Value:
			if p.field == use.ident {
				return -1
			}
		}
	}
	for param, i in params {
		if param.name == use.ident.name {
			return i
		}
	}
	return -1
}

is_atom :: proc(expr: ^ast.Expr) -> bool {
	#partial switch _ in expr.derived {
	case ^ast.Ident, ^ast.Basic_Lit, ^ast.Selector_Expr, ^ast.Call_Expr, ^ast.Paren_Expr, ^ast.Index_Expr:
		return true
	}
	return false
}

needs_parens :: proc(expr: ^ast.Expr, parent: ^ast.Node, call: ^ast.Call_Expr) -> bool {
	inner: ^ast.Binary_Expr
	#partial switch e in expr.derived {
	case ^ast.Binary_Expr:
		inner = e
	case ^ast.Ternary_If_Expr, ^ast.Ternary_When_Expr, ^ast.Or_Else_Expr:
	case:
		return false
	}
	#partial switch p in parent.derived {
	case ^ast.Binary_Expr:
		if inner == nil {
			return true
		}
		zero: parser.Parser
		outer_prec := parser.token_precedence(&zero, p.op.kind)
		inner_prec := parser.token_precedence(&zero, inner.op.kind)
		return outer_prec > inner_prec || (outer_prec == inner_prec && p.right == call)
	case ^ast.Unary_Expr, ^ast.Selector_Expr, ^ast.Index_Expr, ^ast.Deref_Expr, ^ast.Slice_Expr:
		return true
	}
	return false
}

// No return, defer or or_return outside nested procedure literals.
plain_body :: proc(body: ^ast.Block_Stmt) -> bool {
	ok := true
	visitor := ast.Visitor {
		data = &ok,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			#partial switch _ in node.derived {
			case ^ast.Proc_Lit:
				return nil
			case ^ast.Return_Stmt, ^ast.Defer_Stmt, ^ast.Or_Return_Expr:
				(^bool)(visitor.data)^ = false
				return nil
			}
			return visitor
		},
	}
	ast.walk(&visitor, body)
	return ok
}
