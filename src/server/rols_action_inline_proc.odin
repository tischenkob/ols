#+private file

package server

import "core:odin/ast"
import "core:odin/parser"
import "core:strings"

Param :: struct {
	name:      string,
	type:      string, // in the callee's source, empty when the parameter is `d := 0`
	arg:       ^ast.Expr,
	defaulted: bool, // the call omits the argument and `arg` is the default, in the callee's source
}

// An omitted default that the body reads must be a literal: other defaults mean something else at the call site.
default_blocks_inline :: proc(param: Param) -> bool {
	if !param.defaulted {
		return false
	}
	_, is_lit := param.arg.derived.(^ast.Basic_Lit)
	return !is_lit
}

// A literal takes the parameter's type: `1 / d` with `d: f32 = 2` must not become `1 / 2`.
// A literal that already has the parameter's type by default stays bare.
typed_arg_text :: proc(param: Param, text: string) -> string {
	lit, is_lit := param.arg.derived.(^ast.Basic_Lit)
	if !is_lit || param.type == "" {
		return text
	}
	#partial switch lit.tok.kind {
	case .Integer:
		if param.type == "int" {return text}
	case .Float:
		if param.type == "f64" {return text}
	case .String:
		if param.type == "string" {return text}
	case .Rune:
		if param.type == "rune" {return text}
	}
	return strings.concatenate({param.type, "(", text, ")"}, context.temp_allocator)
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
	symbol := resolved.symbol^
	callee, is_proc := symbol.value.(SymbolProcedureValue)
	if !is_proc || .Local in symbol.flags || symbol.pkg != ctx.ast_context.document_package {
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
	// A polymorphic call resolves to a solved symbol without `generic` or the where clauses, so check the declaration.
	if lit.type.generic || len(lit.where_clauses) > 0 || expr_contains_poly(lit.type) {
		return
	}
	body, is_block := lit.body.derived.(^ast.Block_Stmt)
	if !is_block || len(body.stmts) == 0 {
		return
	}
	callee_src := target.ast.src
	roots := make([dynamic]^ast.Node, context.temp_allocator)
	append(&roots, body)
	if lit.type.params != nil {
		for field in lit.type.params.list {
			if field.type != nil do append(&roots, field.type)
			if field.default_value != nil do append(&roots, field.default_value)
		}
	}
	if borrows_from_file(ctx, target, lit, call, roots[:]) {
		return
	}

	params := make([dynamic]Param, context.temp_allocator)
	if lit.type.params != nil {
		for field in lit.type.params.list {
			if field.flags & {.Using, .Ellipsis, .C_Vararg} != {} {
				return
			}
			if field.type != nil {
				if _, variadic := field.type.derived.(^ast.Ellipsis); variadic {
					return
				}
			}
			for name in field.names {
				ident := name.derived.(^ast.Ident) or_else nil
				if ident == nil {
					return
				}
				type_text := node_text(callee_src, field.type) if field.type != nil else ""
				append(&params, Param{name = ident.name, type = type_text, arg = field.default_value})
			}
		}
	}
	if len(call.args) > len(params) {
		return
	}
	for &param, i in params {
		if i < len(call.args) {
			param.arg = call.args[i]
		} else if param.arg == nil {
			return
		} else {
			param.defaulted = true
		}
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
		if default_blocks_inline(params[i]) {
			return
		}
		counts[i] += 1
		text := node_text(callee_src if params[i].defaulted else src, params[i].arg)
		text = typed_arg_text(params[i], text)
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
		arg := node_text(callee_src if param.defaulted else src, param.arg)
		if used[i] && default_blocks_inline(param) {
			return
		}
		if !used[i] {
			if has_side_effect(param.arg) {
				return
			}
			continue
		}
		if arg == param.name {
			continue
		}
		// The body redeclaring the parameter would clash with the local that binds the argument.
		if body_declares(body, param.name) {
			return
		}
		// Locals declared above would capture a later argument that names them.
		for use in collect_ident_uses(param.arg) {
			if param_index(params, use) >= 0 {
				return
			}
		}
		strings.write_string(&sb, inner)
		strings.write_string(&sb, param.name)
		if param.type == "" {
			strings.write_string(&sb, " := ")
		} else {
			strings.write_string(&sb, ": ")
			strings.write_string(&sb, param.type)
			strings.write_string(&sb, " = ")
		}
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

// Whether a statement directly in the body declares the name.
body_declares :: proc(body: ^ast.Block_Stmt, name: string) -> bool {
	for stmt in body.stmts {
		decl := stmt.derived.(^ast.Value_Decl) or_continue
		for n in decl.names {
			if ident, is_ident := n.derived.(^ast.Ident); is_ident && ident.name == name {
				return true
			}
		}
	}
	return false
}

// The current document first: a file-private callee shadows a package one of the same name.
find_proc_lit :: proc(ctx: ^ActionContext, symbol: Symbol) -> (^Document, ^ast.Proc_Lit) {
	if lit := proc_lit_named(ctx.document, symbol.name); lit != nil {
		return ctx.document, lit
	}
	h := Call_Hierarchy{ctx.files, make(map[string]^Document, context.temp_allocator)}
	document := hierarchy_document(&h, symbol.uri)
	if document == nil {
		return nil, nil
	}
	return document, proc_lit_named(document, symbol.name)
}

// The source of roots is copied from the callee's file into the caller's, so it must mean the same
// there. From another file it may not name a file-private declaration of the callee's file, or use an
// import that the caller's file lacks or binds under another name. Shadowing is not tracked, so a
// local of the same name refuses too. In either file, a name the copy takes from outside lit may not
// be bound otherwise at the call: by a local there, a file-private declaration of the caller's file
// or an import of another package.
borrows_from_file :: proc(
	ctx: ^ActionContext,
	callee: ^Document,
	lit: ^ast.Proc_Lit,
	call: ^ast.Call_Expr,
	roots: []^ast.Node,
) -> bool {
	caller := ctx.document
	same_file := callee == caller
	private_names := file_private_names(callee)
	caller_private := file_private_names(caller)
	caller_locals := locals_at(caller, ctx.position_context^, call.pos.offset)
	for root in roots {
		for use in collect_ident_uses(root) {
			name := use.ident.name
			if !same_file &&
			   (name in private_names || unmatched_import(callee.ast.imports[:], caller.ast.imports[:], name)) {
				return true
			}
			if is_field_name(use, callee) {
				continue
			}
			_, captured := get_local(caller_locals, ast.Ident{name = name, pos = call.pos})
			if !same_file {
				captured ||= name in caller_private
				captured ||= unmatched_import(caller.ast.imports[:], callee.ast.imports[:], name)
			}
			if !captured {
				continue
			}
			// Only a use that a local of lit binds keeps its meaning in the copy.
			callee_locals := locals_at(callee, {function = lit}, use.ident.pos.offset)
			if _, local := get_local(callee_locals, use.ident^); !local {
				return true
			}
		}
	}
	return false
}

// Whether from imports a package under name that to does not import from the same path under that name.
unmatched_import :: proc(from, to: []^ast.Import_Decl, name: string) -> bool {
	for imp in from {
		if pattern_import_name(imp) != name {
			continue
		}
		matched := false
		for other in to {
			matched ||= other.fullpath == imp.fullpath && pattern_import_name(other) == name
		}
		if !matched {
			return true
		}
	}
	return false
}

// A context with the locals of the function of pc in document that are visible at offset.
locals_at :: proc(document: ^Document, pc: DocumentPositionContext, offset: int) -> AstContext {
	ast_context := make_ast_context(
		document.ast,
		document.imports,
		document.package_name,
		document.uri.uri,
		document.fullpath,
		context.temp_allocator,
	)
	get_globals(document.ast, &ast_context)
	pc := pc
	pc.position = offset
	get_locals(&ast_context, &pc)
	return ast_context
}

// Whether the use is a field name, as in `p.x`, `.x` or `{x = 1}` of a struct, rather than a name in
// scope. A key of a map or array literal is a value; a literal of a named type is resolved in
// document when given, and counts as a struct otherwise.
is_field_name :: proc(use: IdentUse, document: ^Document = nil) -> bool {
	n := len(use.parents)
	if n == 0 {
		return false
	}
	#partial switch p in use.parents[n - 1].derived {
	case ^ast.Selector_Expr:
		return p.field == use.ident
	case ^ast.Implicit_Selector_Expr:
		return true
	case ^ast.Field_Value:
		if p.field != use.ident {
			return false
		}
		lit: ^ast.Comp_Lit
		if n >= 2 {
			lit = use.parents[n - 2].derived.(^ast.Comp_Lit) or_else nil
		}
		if lit == nil || lit.type == nil {
			return true
		}
		#partial switch _ in lit.type.derived {
		case ^ast.Map_Type, ^ast.Array_Type, ^ast.Dynamic_Array_Type:
			return false
		case ^ast.Ident, ^ast.Selector_Expr:
			if document == nil {
				return true
			}
			if symbol, ok := resolve_type_in_package(document, document.package_name, lit.type); ok {
				#partial switch _ in symbol.value {
				case SymbolMapValue, SymbolFixedArrayValue, SymbolSliceValue, SymbolDynamicArrayValue:
					return false
				}
			}
		}
		return true
	}
	return false
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
	if is_field_name(use) {
		return -1
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
