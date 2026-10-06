#+private file

package server

import "core:odin/ast"
import "core:odin/parser"
import "core:slice"
import "core:strings"

import "src:common"

Param :: struct {
	name:      string,
	type:      string, // in the callee's source, empty when the parameter is `d := 0`
	type_expr: ^ast.Expr, // the node of type, nil when type is empty
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
// A literal that already has the parameter's type by default stays bare. An implicit selector
// takes a named type in front, since `int(b)` gives `.Left` no type: `int(Button.Left)`.
typed_arg_text :: proc(param: Param, text: string) -> string {
	if _, implicit := param.arg.derived.(^ast.Implicit_Selector_Expr); implicit && param.type_expr != nil {
		#partial switch _ in param.type_expr.derived {
		case ^ast.Ident, ^ast.Selector_Expr:
			return strings.concatenate({param.type, text}, context.temp_allocator)
		}
	}
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
	lit_kinds := make(map[^ast.Comp_Lit]Use_Kind, context.temp_allocator)
	origin := Copy{target, lit, call, &lit_kinds}

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
				append(
					&params,
					Param{name = ident.name, type = type_text, type_expr = field.type, arg = field.default_value},
				)
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
		inline_statement(ctx, stmt, body, params[:], origin)
		return
	}
	if len(field_types(callee.return_types)) != 1 || len(body.stmts) != 1 {
		return
	}
	ret, is_return := body.stmts[0].derived.(^ast.Return_Stmt)
	if !is_return || len(ret.results) != 1 {
		return
	}
	// An untyped literal result is copied with the result type in front.
	result_type: ^ast.Expr
	if comp, is_comp := ret.results[0].derived.(^ast.Comp_Lit); is_comp && comp.type == nil {
		if lit.type.results == nil || len(lit.type.results.list) != 1 || lit.type.results.list[0].type == nil {
			return
		}
		result_type = lit.type.results.list[0].type
	}
	inline_expression(ctx, call, parent, ret.results[0], result_type, params[:], origin)
}

// Where the copied text comes from: the callee's file and procedure literal, inlined at call.
// lit_kinds caches what use_kind finds for the field names of each literal.
Copy :: struct {
	callee:    ^Document,
	lit:       ^ast.Proc_Lit,
	call:      ^ast.Call_Expr,
	lit_kinds: ^map[^ast.Comp_Lit]Use_Kind,
}

// The import edits that the text of written, copied from the callee's file, needs in the caller's
// file. False when the text would mean something else there.
copy_imports :: proc(ctx: ^ActionContext, origin: Copy, written: []^ast.Node) -> ([]TextEdit, bool) {
	imports, borrows := borrows_from_file(ctx, origin, written)
	if borrows {
		return nil, false
	}
	edits := make([dynamic]TextEdit, context.temp_allocator)
	for imp in imports {
		append_import_edit(&edits, import_edit(ctx, strings.trim(imp.fullpath, "\"`"), imp.name.text))
	}
	return edits[:], true
}

// Every parameter occurrence becomes its argument. An argument with a call is passed through
// once or not at all, never duplicated or dropped. A non-nil result_type goes in front of expr,
// an untyped compound literal.
inline_expression :: proc(
	ctx: ^ActionContext,
	call: ^ast.Call_Expr,
	parent: ^ast.Node,
	expr: ^ast.Expr,
	result_type: ^ast.Expr,
	params: []Param,
	origin: Copy,
) {
	src := ctx.document.ast.src
	callee := origin.callee
	callee_src := callee.ast.src
	written := make([dynamic]^ast.Node, context.temp_allocator)
	append(&written, expr)
	if result_type != nil do append(&written, result_type)
	counts := make([]int, len(params), context.temp_allocator)

	Replacement :: struct {
		start, end: int,
		text:       string,
	}
	replacements := make([dynamic]Replacement, context.temp_allocator)

	for use in collect_ident_uses(expr) {
		i, known := param_index(params, use, callee, origin)
		if !known {
			return
		}
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
		if params[i].defaulted do append(&written, params[i].arg)
		if typed := typed_arg_text(params[i], text); typed != text {
			text = typed
			append(&written, params[i].type_expr)
		}
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
	if result_type != nil {
		strings.write_string(&sb, node_text(callee_src, result_type))
	}
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
	import_edits, fits := copy_imports(ctx, origin, written[:])
	if !fits {
		return
	}
	edits := make([dynamic]TextEdit, context.temp_allocator)
	append(&edits, ..import_edits)
	append(&edits, TextEdit{range = range_of(ctx, call.pos.offset, call.end.offset), newText = text})
	append(ctx.actions, make_code_action(ctx, "Inline procedure call", "refactor.inline", edits[:]))
}

// The body becomes a bare block, with a typed local per parameter the body reads. Passing a
// variable of the parameter's own name needs no local.
inline_statement :: proc(
	ctx: ^ActionContext,
	stmt: ^ast.Expr_Stmt,
	body: ^ast.Block_Stmt,
	params: []Param,
	origin: Copy,
) {
	if !plain_body(body) {
		return
	}
	src := ctx.document.ast.src
	callee := origin.callee
	callee_src := callee.ast.src
	written := make([dynamic]^ast.Node, context.temp_allocator)
	append(&written, body)

	used := make([]bool, len(params), context.temp_allocator)
	for use in collect_ident_uses(body) {
		i, known := param_index(params, use, callee, origin)
		if !known {
			return
		}
		if i >= 0 {
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
			if i, known := param_index(params, use, callee if param.defaulted else ctx.document, origin);
			   !known || i >= 0 {
				return
			}
		}
		if param.type_expr != nil do append(&written, param.type_expr)
		if param.defaulted do append(&written, param.arg)
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

	import_edits, fits := copy_imports(ctx, origin, written[:])
	if !fits {
		return
	}
	edits := make([dynamic]TextEdit, context.temp_allocator)
	append(&edits, ..import_edits)
	append(&edits, TextEdit{range = range_of(ctx, stmt.pos.offset, stmt.end.offset), newText = strings.to_string(sb)})
	append(ctx.actions, make_code_action(ctx, "Inline procedure call", "refactor.inline", edits[:]))
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

// The declaration that symbol names. A callee with per-target variants is refused, since the copy
// would carry one target's body, unless it sits outside any `when` in a file that builds on the same
// targets as the caller's file.
find_proc_lit :: proc(ctx: ^ActionContext, symbol: Symbol) -> (^Document, ^ast.Proc_Lit) {
	h := Call_Hierarchy{ctx.files, make(map[string]^Document, context.temp_allocator)}
	document := ctx.document
	if !strings.equal_fold(symbol.uri, document.uri.uri) {
		document = hierarchy_document(&h, symbol.uri)
	}
	if document == nil {
		return nil, nil
	}
	// The range is the name from the index, and the procedure type from the current file's globals.
	offset, valid := common.get_absolute_position(symbol.range.start, document.text[:document.used_text])
	decl: ^ast.Value_Decl
	for d in top_level_value_decls(document.ast) {
		if valid && d.pos.offset <= offset && offset < d.end.offset do decl = d
	}
	if decl == nil || len(decl.names) != 1 || len(decl.values) != 1 {
		return nil, nil
	}
	if len(top_level_variants(&h, document, decl)) > 0 {
		callee_tags := parser.parse_file_tags(document.ast, context.temp_allocator)
		caller_tags := parser.parse_file_tags(ctx.document.ast, context.temp_allocator)
		if !slice.contains(document.ast.decls[:], (^ast.Stmt)(decl)) ||
		   !same_build_targets(document.fullpath, callee_tags, ctx.document.fullpath, caller_tags) {
			return nil, nil
		}
	}
	return document, decl.values[0].derived.(^ast.Proc_Lit) or_else nil
}

// The source of roots is copied from the callee's file into the caller's, so it must mean the same
// there. A use that a local or parameter of lit binds keeps its meaning. From another file, any other
// use may not name a file-private declaration of the callee's file. It may name an import of the
// callee's file that the caller's file lacks only when that name is free in the caller's file, and
// the import is then returned for the caller to add. In either file, a name the copy takes from
// outside lit may not be bound otherwise at the call: by a local there, a file-private declaration
// of the caller's file or an import of another package.
borrows_from_file :: proc(
	ctx: ^ActionContext,
	origin: Copy,
	roots: []^ast.Node,
) -> (
	imports: []^ast.Import_Decl,
	borrows: bool,
) {
	callee, lit, call := origin.callee, origin.lit, origin.call
	caller := ctx.document
	same_file := callee == caller
	private_names := file_private_names(callee)
	caller_private := file_private_names(caller)
	caller_locals := locals_at(caller, ctx.position_context^, call.pos.offset)
	added := make([dynamic]^ast.Import_Decl, context.temp_allocator)
	for root in roots {
		for use in collect_ident_uses(root) {
			name := use.ident.name
			private := !same_file && name in private_names
			missing_import := !same_file && unmatched_import(callee.ast.imports[:], caller.ast.imports[:], name)
			_, captured := get_local(caller_locals, ast.Ident{name = name, pos = call.pos})
			if !same_file {
				captured ||= name in caller_private
				captured ||= unmatched_import(caller.ast.imports[:], callee.ast.imports[:], name)
			}
			if !private && !missing_import && !captured {
				continue
			}
			kind := use_kind(use, callee, origin)
			if kind == .Field {
				continue
			}
			// Only a use that a local of lit binds keeps its meaning in the copy.
			callee_locals := locals_at(callee, {function = lit}, use.ident.pos.offset)
			if _, local := get_local(callee_locals, use.ident^); local {
				continue
			}
			if private || captured || kind == .Unknown {
				return nil, true
			}
			imp := import_named(callee.ast.imports[:], name)
			if imp == nil || !import_fits(ctx, callee, imp, name, call.pos.offset) {
				return nil, true
			}
			if import_named(added[:], name) == nil {
				append(&added, imp)
			}
		}
	}
	return added[:], false
}

// Whether the caller's file can take imp of the callee's file under name: it does not import the
// same path, nothing in the file or the package binds name, and it builds only where the callee's
// file does.
import_fits :: proc(ctx: ^ActionContext, callee: ^Document, imp: ^ast.Import_Decl, name: string, offset: int) -> bool {
	caller := ctx.document
	for other in caller.ast.imports {
		if other.fullpath == imp.fullpath {
			return false
		}
	}
	if name_taken(caller, offset, name, strings.trim(imp.fullpath, "\"`")) {
		return false
	}
	if _, declared := memory_index_lookup(&indexer.index, name, ctx.ast_context.document_package); declared {
		return false
	}
	// A file restricted by build tags or a name suffix may import a package other targets lack.
	callee_tags := parser.parse_file_tags(callee.ast, context.temp_allocator)
	restricted := !same_build_targets(callee.fullpath, callee_tags, "x.odin", {})
	caller_tags := parser.parse_file_tags(caller.ast, context.temp_allocator)
	return !restricted || same_build_targets(callee.fullpath, callee_tags, caller.fullpath, caller_tags)
}

// The import that binds name, or nil.
import_named :: proc(imports: []^ast.Import_Decl, name: string) -> ^ast.Import_Decl {
	for imp in imports {
		if pattern_import_name(imp) == name {
			return imp
		}
	}
	return nil
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

Use_Kind :: enum {
	Name, // a name in scope
	Field, // a field name
	Unknown, // a key or a field name of a literal whose type does not resolve
}

// Whether the use is a field name, as in `p.x`, `.x` or `{x = 1}` of a struct or bit_field, rather
// than a name in scope. A key of a map or array literal is a name. The type of a literal is resolved
// in document, which holds the use, once per literal of origin.
use_kind :: proc(use: IdentUse, document: ^Document, origin: Copy) -> Use_Kind {
	n := len(use.parents)
	if n == 0 {
		return .Name
	}
	#partial switch p in use.parents[n - 1].derived {
	case ^ast.Selector_Expr:
		return p.field == use.ident ? .Field : .Name
	case ^ast.Implicit_Selector_Expr:
		return .Field
	case ^ast.Field_Value:
		if p.field != use.ident {
			return .Name
		}
		lit: ^ast.Comp_Lit
		if n >= 2 {
			lit = use.parents[n - 2].derived.(^ast.Comp_Lit) or_else nil
		}
		if lit == nil {
			return .Unknown
		}
		if kind, cached := origin.lit_kinds[lit]; cached {
			return kind
		}
		kind := key_kind(lit, use, document)
		origin.lit_kinds[lit] = kind
		return kind
	}
	return .Name
}

// What a field name of lit is: the same for every field name of lit, which use names.
key_kind :: proc(lit: ^ast.Comp_Lit, use: IdentUse, document: ^Document) -> Use_Kind {
	symbol: Symbol
	ok: bool
	if lit.type == nil {
		// An untyped literal takes its type from where it stands.
		ast_context: AstContext
		position_context: DocumentPositionContext
		position := common.get_token_range(use.ident^, document.ast.src).start
		if ast_context_at(document, position, &ast_context, &position_context) {
			symbol, ok = resolve_comp_literal(&ast_context, &position_context)
		}
		ok &&= position_context.comp_lit == lit
	} else {
		#partial switch _ in lit.type.derived {
		case ^ast.Map_Type, ^ast.Array_Type, ^ast.Dynamic_Array_Type:
			return .Name
		}
		symbol, ok = resolve_type_in_package(document, document.package_name, lit.type)
	}
	if !ok {
		return .Unknown
	}
	#partial switch _ in symbol.value {
	case SymbolMapValue, SymbolFixedArrayValue, SymbolSliceValue, SymbolDynamicArrayValue:
		return .Name
	case SymbolStructValue, SymbolBitFieldValue:
		return .Field
	}
	return lit.type == nil ? .Unknown : .Field
}

// Index of the parameter the use reads, or -1 for other names and for field names. Not known when
// the use is named like a parameter but use_kind cannot tell a field from a key.
param_index :: proc(params: []Param, use: IdentUse, document: ^Document, origin: Copy) -> (index: int, known: bool) {
	for param, i in params {
		if param.name != use.ident.name {
			continue
		}
		switch use_kind(use, document, origin) {
		case .Name:
			return i, true
		case .Field:
			return -1, true
		case .Unknown:
			return -1, false
		}
	}
	return -1, true
}

// Whether the argument binds tighter than any operator around the parameter it replaces.
is_atom :: proc(expr: ^ast.Expr) -> bool {
	#partial switch _ in expr.derived {
	case ^ast.Ident,
	     ^ast.Basic_Lit,
	     ^ast.Selector_Expr,
	     ^ast.Implicit_Selector_Expr,
	     ^ast.Call_Expr,
	     ^ast.Paren_Expr,
	     ^ast.Index_Expr,
	     ^ast.Slice_Expr,
	     ^ast.Deref_Expr,
	     ^ast.Type_Assertion:
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
