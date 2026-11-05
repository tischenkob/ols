#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:slice"
import "core:strings"

// "Create local variable", "Create global variable" and "Create constant" on an unresolved name whose use gives a type,
// and "Create struct" on the type of an unresolved `Foo{a = 1}`. A name that resolves costs one lookup here.
@(private = "package")
add_create_decl_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_create_decl {
		return
	}
	nodes := nodes_at(ctx.document.ast.decls[:], ctx.range.start)
	if len(nodes) == 0 {
		return
	}
	at := nodes[len(nodes) - 1]
	ident, is_ident := at.node.derived.(^ast.Ident)
	if !is_ident || at.parent == nil || ctx.range.end > ident.end.offset {
		return
	}
	#partial switch p in at.parent.derived {
	case ^ast.Comp_Lit:
		if p.type == ident {
			if is_unresolved(ctx, ident) {
				add_create_struct(ctx, nodes, ident, p)
			}
			return
		}
	case ^ast.Assign_Stmt, ^ast.Binary_Expr, ^ast.Value_Decl, ^ast.Return_Stmt, ^ast.Call_Expr, ^ast.Field_Value:
	case:
		return
	}
	function := ctx.position_context.function
	if function == nil || function.body == nil || !is_unresolved(ctx, ident) {
		return
	}
	add_create_name(ctx, nodes, function, ident, at.parent)
}

is_unresolved :: proc(ctx: ^ActionContext, ident: ^ast.Ident) -> bool {
	if ident.name == "_" || ident.name == "context" || ident.name in keyword_map {
		return false
	}
	reset_ast_context(ctx.ast_context)
	ctx.ast_context.use_locals = true
	if _, resolved := resolve_type_identifier(ctx.ast_context, ident^); resolved {
		return false
	}
	return !is_taken(ctx, ident^)
}

add_create_name :: proc(
	ctx: ^ActionContext,
	nodes: []Node_At,
	function: ^ast.Proc_Lit,
	ident: ^ast.Ident,
	parent: ^ast.Node,
) {
	// A declaration of the name further down makes a new declaration here a question of scopes.
	uses := make([dynamic]IdentUse, context.temp_allocator)
	for use in collect_ident_uses(function.body) {
		if use.ident.name != ident.name || is_member_name(use) {
			continue
		}
		if declared_by(use) {
			return
		}
		append(&uses, use)
	}

	imports := make([dynamic]TextEdit, context.temp_allocator)
	type, known := received_type(ctx, nodes, ident, &imports)
	if !known {
		return
	}

	// The whole statement `x = v`, when the parent is a statement of a list: only that one can turn into a declaration.
	stmts, index, in_stmt := stmt_at_range(ctx)
	value: ^ast.Expr
	if assign, is_assign := parent.derived.(^ast.Assign_Stmt); is_assign && in_stmt && stmts[index] == assign {
		if assign.op.kind == .Eq && len(assign.lhs) == 1 && len(assign.rhs) == 1 {
			value = assign.rhs[0]
		}
	}

	if in_stmt {
		add_local_form(ctx, stmts, index, ident, uses[:], value, type, imports[:])
	}
	if len(imports) > 0 || holds_at_file_scope(ctx, type, ctx.ast_context.document_package) {
		text := fmt.tprintf("%s: %s", ident.name, type)
		edits := make([dynamic]TextEdit, context.temp_allocator)
		append(&edits, ..imports[:])
		if insert, ok := insert_after_decl(ctx, ident.pos.offset, text); ok {
			append(&edits, insert)
			title := fmt.tprintf("Create global variable %s", ident.name)
			append(ctx.actions, make_code_action(ctx, title, "quickfix", edits[:]))
		}
	}
	if in_stmt && value != nil {
		add_constant_form(ctx, stmts[index], ident, uses[:], value)
	}
}

// Whether the use is a name that a declaration in the procedure declares.
declared_by :: proc(use: IdentUse) -> bool {
	if len(use.parents) == 0 {
		return false
	}
	decl, is_decl := use.parents[len(use.parents) - 1].derived.(^ast.Value_Decl)
	return is_decl && slice.contains(decl.names, use.ident)
}

// A declaration above the statement is visible only below it, in its own list, so every use must be there.
add_local_form :: proc(
	ctx: ^ActionContext,
	stmts: []^ast.Stmt,
	index: int,
	ident: ^ast.Ident,
	uses: []IdentUse,
	value: ^ast.Expr,
	type: string,
	imports: []TextEdit,
) {
	stmt := stmts[index]
	src := ctx.document.ast.src
	line_start, _ := before_on_line(src, stmt.pos.offset)
	if strings.trim_space(src[line_start:stmt.pos.offset]) != "" || marked_by_line_above(src, stmt.pos.offset) {
		return
	}
	last := stmts[len(stmts) - 1].end.offset
	reads_itself := false
	for use in uses {
		offset := use.ident.pos.offset
		if offset < stmt.pos.offset || last < offset {
			return
		}
		if value != nil && value.pos.offset <= offset && offset < value.end.offset {
			reads_itself = true
		}
	}
	edits := make([dynamic]TextEdit, context.temp_allocator)
	append(&edits, ..imports)
	if assign, is_assign := stmt.derived.(^ast.Assign_Stmt); is_assign && value != nil && !reads_itself {
		op := assign.op.pos.offset
		append(&edits, TextEdit{range = range_of(ctx, op, op + 1), newText = ":="})
	} else {
		indent := src[line_start:stmt.pos.offset]
		text := fmt.tprintf("%s%s: %s\n", indent, ident.name, type)
		append(&edits, TextEdit{range = range_of(ctx, line_start, line_start), newText = text})
	}
	title := fmt.tprintf("Create local variable %s", ident.name)
	append(ctx.actions, make_code_action(ctx, title, "quickfix", edits[:]))
}

// `x = 1` becomes `x :: 1` at file scope, as an unused local constant does not compile. Its statement goes away, so it
// must have its lines to itself, and nothing may write to the name.
add_constant_form :: proc(
	ctx: ^ActionContext,
	stmt: ^ast.Stmt,
	ident: ^ast.Ident,
	uses: []IdentUse,
	value: ^ast.Expr,
) {
	if !is_constant_value(value) {
		return
	}
	for use in uses {
		if use.ident != ident && is_write(use) {
			return
		}
	}
	src := ctx.document.ast.src
	line_start, _ := before_on_line(src, stmt.pos.offset)
	line_end := strings.index_byte(src[stmt.end.offset:], '\n')
	rest := line_end < 0 ? src[stmt.end.offset:] : src[stmt.end.offset:stmt.end.offset + line_end]
	if strings.trim_space(src[line_start:stmt.pos.offset]) != "" ||
	   strings.trim_space(rest) != "" ||
	   marked_by_line_above(src, stmt.pos.offset) {
		return
	}
	text := fmt.tprintf("%s :: %s", ident.name, node_text(src, value))
	insert, ok := insert_after_decl(ctx, ident.pos.offset, text)
	if !ok {
		return
	}
	edits := make([]TextEdit, 2, context.temp_allocator)
	edits[0] = delete_lines_edit(ctx, stmt.pos.line - 1, stmt.end.line - 1)
	edits[1] = insert
	title := fmt.tprintf("Create constant %s", ident.name)
	append(ctx.actions, make_code_action(ctx, title, "quickfix", edits))
}

// A literal, or an operation on literals.
is_constant_value :: proc(value: ^ast.Expr) -> bool {
	#partial switch v in value.derived {
	case ^ast.Basic_Lit:
		return true
	case ^ast.Ident:
		return v.name == "true" || v.name == "false"
	case ^ast.Paren_Expr:
		return is_constant_value(v.expr)
	case ^ast.Unary_Expr:
		#partial switch v.op.kind {
		case .Add, .Sub, .Not, .Xor:
			return is_constant_value(v.expr)
		}
	case ^ast.Binary_Expr:
		return is_constant_value(v.left) && is_constant_value(v.right)
	}
	return false
}

add_create_struct :: proc(ctx: ^ActionContext, nodes: []Node_At, ident: ^ast.Ident, lit: ^ast.Comp_Lit) {
	// A new struct is not the type that the place of the literal already has.
	if _, expects := place_type(ctx, nodes, lit); expects {
		return
	}
	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "%s :: struct {{", ident.name)
	if len(lit.elems) > 0 {
		strings.write_byte(&sb, '\n')
	}
	unit := indent_unit(ctx.document.ast.src, "", nil)
	names := make([dynamic]string, context.temp_allocator)
	types := make([dynamic]string, context.temp_allocator)
	for elem in lit.elems {
		field, is_named := elem.derived.(^ast.Field_Value)
		if !is_named {
			return
		}
		name, is_ident := field.field.derived.(^ast.Ident)
		if !is_ident || slice.contains(names[:], name.name) {
			return
		}
		type, known := value_type(ctx, field.value, field)
		if !known || !holds_at_file_scope(ctx, type, ctx.ast_context.document_package) {
			return
		}
		append(&names, name.name)
		append(&types, type)
		fmt.sbprintf(&sb, "%s%s: %s,\n", unit, name.name, type)
	}
	for type in types {
		if type_names_clash(type, names[:]) {
			return
		}
	}
	strings.write_byte(&sb, '}')
	insert, ok := insert_after_decl(ctx, ident.pos.offset, strings.to_string(sb))
	if !ok {
		return
	}
	edits := make([]TextEdit, 1, context.temp_allocator)
	edits[0] = insert
	append(ctx.actions, make_code_action(ctx, fmt.tprintf("Create struct %s", ident.name), "quickfix", edits))
}

// The type that the place of node gives it: the value of an assignment to it, the other operand of an operation, or the
// places of expected_of. An import that the type needs goes into imports.
@(private = "package")
received_type :: proc(
	ctx: ^ActionContext,
	nodes: []Node_At,
	node: ^ast.Node,
	imports: ^[dynamic]TextEdit,
) -> (
	string,
	bool,
) {
	parent := parent_of_node(nodes, node)
	if parent == nil {
		return "", false
	}
	#partial switch p in parent.derived {
	case ^ast.Assign_Stmt:
		if len(p.lhs) == len(p.rhs) {
			for lhs, i in p.lhs {
				if lhs == node {
					if !shares_operand_type(p.op.kind) {
						return "", false
					}
					return value_type(ctx, p.rhs[i], node)
				}
			}
		}
	case ^ast.Binary_Expr:
		if !shares_operand_type(p.op.kind) {
			return "", false
		}
		return value_type(ctx, p.left == node ? p.right : p.left, node)
	}
	expected, ok := place_type(ctx, nodes, node)
	if !ok {
		return "", false
	}
	at := position_ident(node, "")
	text, printed := expected_text(ctx, at, expected, imports)
	// An inline struct or union written again is a new type.
	if !printed || strings.contains(text, "{") || (len(imports) == 0 && !name_holds(ctx, at, text)) {
		return "", false
	}
	return text, true
}

// expected_of, except that `_ = v` takes any type.
place_type :: proc(ctx: ^ActionContext, nodes: []Node_At, node: ^ast.Node) -> (Expected, bool) {
	if assign, is_assign := parent_of_node(nodes, node).derived.(^ast.Assign_Stmt);
	   is_assign && len(assign.lhs) == len(assign.rhs) {
		for value, i in assign.rhs {
			if blank, is_ident := assign.lhs[i].derived.(^ast.Ident); value == node && is_ident && blank.name == "_" {
				return {}, false
			}
		}
	}
	return expected_of(ctx, nodes, node)
}

// The type of a single value, as a declaration named by the source text of node gives it. The resolver takes the name of a
// declaration from the source, and that of a whole `x.a` or `a = a` is no name that the value can read, as a plain `a` is
// in `Foo{a = a}` and `x.a = a`.
value_type :: proc(ctx: ^ActionContext, value: ^ast.Expr, node: ^ast.Node) -> (string, bool) {
	if call, is_call := value.derived.(^ast.Call_Expr); is_call {
		ctx.ast_context.use_locals = true
		if callee, resolved := resolve_type_expression(ctx.ast_context, call.expr); resolved {
			if procedure, is_proc := callee.value.(SymbolProcedureValue); is_proc {
				count := 0
				for result in procedure.return_types {
					count += max(len(result.names), 1)
				}
				if count != 1 {
					return "", false
				}
			}
		}
	}
	name := new_type(ast.Ident, node.pos, node.end, context.temp_allocator)
	name.name = node_text(ctx.document.ast.src, node)
	return inferred_type(ctx, name, value, node.pos.offset)
}

// Whether both operands have one type. A shift takes any unsigned amount, and `in` the element of a set.
shares_operand_type :: proc(kind: tokenizer.Token_Kind) -> bool {
	#partial switch kind {
	case .Eq, .Add_Eq, .Sub_Eq, .Mul_Eq, .Quo_Eq, .Mod_Eq, .Mod_Mod_Eq, .And_Eq, .Or_Eq, .Xor_Eq, .And_Not_Eq:
		return true
	case .Add, .Sub, .Mul, .Quo, .Mod, .Mod_Mod, .And, .Or, .Xor, .And_Not, .Cmp_And, .Cmp_Or:
		return true
	case .Cmp_Eq, .Not_Eq, .Lt, .Gt, .Lt_Eq, .Gt_Eq:
		return true
	}
	return false
}

// Whether the names of a printed type mean types at file scope. No local counts there, and a local constant such as a
// local type counts at every position of its procedure, so the locals go away for the lookup.
@(private = "package")
holds_at_file_scope :: proc(ctx: ^ActionContext, type, pkg: string) -> bool {
	clear_locals(ctx.ast_context)
	defer restore_locals(ctx)
	return spelled_names_hold(ctx, new_type(ast.Ident, {}, {}, context.temp_allocator), type, pkg)
}

// A struct's field names shadow type names inside that struct, so `Bar: int` next to `foo: Bar` is a cycle.
@(private = "package")
type_names_clash :: proc(type: string, fields: []string) -> bool {
	for word in type_words(type) {
		first, _, _ := strings.partition(word, ".")
		if slice.contains(fields, first) {
			return true
		}
	}
	return false
}

// The names in a printed type, with their package qualifiers.
@(private = "package")
type_words :: proc(type: string) -> []string {
	is_separator :: proc(r: rune) -> bool {
		is_word := r == '_' || r == '.' || ('0' <= r && r <= '9') || ('a' <= r && r <= 'z') || ('A' <= r && r <= 'Z')
		return !is_word && r < 0x80
	}
	return strings.fields_proc(type, is_separator, context.temp_allocator)
}
