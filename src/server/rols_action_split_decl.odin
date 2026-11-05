#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:strings"
import "core:unicode"

@(private = "package")
add_split_decl_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_split_decl {
		return
	}
	stmts, index, ok := stmt_at_range(ctx)
	if !ok {
		return
	}
	#partial switch stmt in stmts[index].derived {
	case ^ast.Value_Decl:
		if !plain_decl(ctx, stmt) {
			return
		}
		split_declaration(ctx, stmt)
		split_names(ctx, stmt)
		if index + 1 < len(stmts) {
			if assign, is_assign := stmts[index + 1].derived.(^ast.Assign_Stmt); is_assign {
				join_declaration(ctx, stmt, assign)
			}
		}
	case ^ast.Assign_Stmt:
		if index > 0 {
			if decl, is_decl := stmts[index - 1].derived.(^ast.Value_Decl); is_decl && plain_decl(ctx, decl) {
				join_declaration(ctx, decl, stmt)
			}
		}
	}
}

// An attribute such as `@(static)` gives the declaration a meaning that a separate statement would lose.
plain_decl :: proc(ctx: ^ActionContext, decl: ^ast.Value_Decl) -> bool {
	if !decl.is_mutable || decl.is_using || len(decl.attributes) > 0 || !alone_on_line(ctx.document.ast.src, decl) {
		return false
	}
	for name in decl.names {
		if ident, is_ident := name.derived.(^ast.Ident); !is_ident || ident.name == "_" {
			return false
		}
	}
	return true
}

// Whether root names name outside a member position. A value that reads the name it sets means an outer name in the
// declaration, and the new local after a split.
reads_name :: proc(root: ^ast.Node, name: string) -> bool {
	for use in collect_ident_uses(root) {
		if use.ident.name == name && !is_member_name(use) {
			return true
		}
	}
	return false
}

// `x: T = v` or `x := v` becomes `x: T` and `x = v`.
split_declaration :: proc(ctx: ^ActionContext, decl: ^ast.Value_Decl) {
	if len(decl.names) != 1 || len(decl.values) != 1 {
		return
	}
	src := ctx.document.ast.src
	name := decl.names[0].derived.(^ast.Ident)
	value := decl.values[0]
	#partial switch _ in value.derived {
	case ^ast.Undef, ^ast.Proc_Lit:
		return
	}
	if reads_name(value, name.name) {
		return
	}
	indent := get_line_indentation(src, decl.pos.offset)
	if decl.type != nil {
		if strings.trim_space(src[decl.type.end.offset:value.pos.offset]) != "=" ||
		   !declarable_type(node_text(src, decl.type)) {
			return
		}
		append_replace_range(
			ctx,
			decl.type.end.offset,
			value.pos.offset,
			"Split declaration",
			fmt.tprintf("\n%s%s = ", indent, name.name),
		)
		return
	}
	if strings.trim_space(src[name.end.offset:value.pos.offset]) != ":=" {
		return
	}
	type, ok := inferred_type(ctx, name, value, decl.end.offset)
	if !ok {
		return
	}
	append_replace_range(
		ctx,
		name.end.offset,
		value.pos.offset,
		"Split declaration",
		fmt.tprintf(": %s\n%s%s = ", type, indent, name.name),
	)
}

// `[?]T` takes its length from a literal in the same declaration, and `$T` declares T only in a signature. A written
// `#soa[]T` starts its node after the directive, so the join could not match the text that the split wrote.
declarable_type :: proc(type: string) -> bool {
	return !strings.contains_any(type, "?$#")
}

// The type that `name := value` gives name, as a declaration at offset resolves it. "Split declaration" writes this
// text and "Join declaration with inferred type" compares it, so a split always has the join that restores it. Convert
// to constant and to variable compare the uses with it, so each has the other as its reverse.
@(private = "package")
inferred_type :: proc(ctx: ^ActionContext, name: ^ast.Ident, value: ^ast.Expr, offset: int) -> (string, bool) {
	gather_locals_at(ctx, offset)
	defer restore_locals(ctx)
	if !names_a_value(ctx, value) || mixes_untyped_kinds(ctx, value) {
		return "", false
	}
	names := []^ast.Expr{name}
	values := []^ast.Expr{value}
	get_locals_value_decl(ctx.ast_context.file, {names = names, values = values, is_mutable = true}, ctx.ast_context)
	ctx.ast_context.use_locals = true
	symbol, ok := resolve_type_expression(ctx.ast_context, name)
	if !ok {
		return "", false
	}
	text, printed := symbol_type_text(ctx.ast_context, symbol, name.name, require_import = true)
	if !printed {
		return "", false
	}
	// A copy of a variable or a field with an unnamed type, such as `x := arr` or `x := h.min`, carries that name, which
	// is no type. The printed name stands only if it declares this very type.
	if !declares_type(ctx, name, symbol) {
		text, printed = symbol_type_text(ctx.ast_context, symbol, symbol.name, require_import = true)
		printed = printed && spelled_names_hold(ctx, name, text, symbol.pkg)
	}
	return text, printed && declarable_type(text)
}

// Whether the name of symbol, looked up where symbol lives, finds a type at the place that symbol came from. A field's
// symbol takes the name of the field, and a type can share that name and even its text (`Sl :: distinct []int`).
@(private = "package")
declares_type :: proc(ctx: ^ActionContext, at: ^ast.Ident, symbol: Symbol) -> bool {
	set_ast_package_set_scoped(ctx.ast_context, symbol.pkg)
	ctx.ast_context.use_locals = symbol.pkg == ctx.ast_context.document_package
	found, ok := resolve_name_at(ctx, at, symbol.name)
	// The index keeps a package's variable with the type of its value, so only the flag tells it from a type.
	if !ok || .Mutable in found.flags {
		return false
	}
	#partial switch found.type {
	case .Keyword:
		_, is_basic := symbol.value.(SymbolBasicValue)
		return is_basic
	case .Function, .Package, .Variable, .Constant, .Field, .EnumMember:
		return false
	}
	return found.uri == symbol.uri && found.range == symbol.range
}

// A re-printed type is spelled as its declaration in pkg wrote it, so each name in text must mean the same at the
// cursor. In another package only a builtin type can be sure to: `[]Item` there means that package's Item, and `[2]int`
// that package's own `int`, if it declares one. `distinct` is no name here, so an inline `distinct [3]int`, which
// declares a new type each time it is written, refuses.
@(private = "package")
spelled_names_hold :: proc(ctx: ^ActionContext, at: ^ast.Ident, text: string, pkg: string) -> bool {
	is_separator :: proc(r: rune) -> bool {
		return r != '_' && r != '.' && !unicode.is_letter(r) && !unicode.is_digit(r)
	}
	for word in strings.fields_proc(text, is_separator, context.temp_allocator) {
		switch word {
		case "map", "dynamic", "matrix", "bit_set", "soa", "simd":
			continue
		}
		if unicode.is_digit(rune(word[0])) {
			continue
		}
		first, dot, _ := strings.partition(word, ".")
		ctx.ast_context.use_locals = true
		found, ok := resolve_name_at(ctx, at, first)
		if !ok {
			return false
		}
		if pkg != ctx.ast_context.document_package {
			if !builtin_without_decl(first, pkg) {
				return false
			}
			continue
		}
		if (found.type == .Package) != (dot != "") {
			return false
		}
		#partial switch found.type {
		case .Function, .Variable, .Field, .EnumMember:
			return false
		}
	}
	return true
}

// What name means at the position of at. A local counts only below its declaration, so the position matters.
resolve_name_at :: proc(ctx: ^ActionContext, at: ^ast.Ident, name: string) -> (Symbol, bool) {
	ident := new_type(ast.Ident, at.pos, at.end, context.temp_allocator)
	ident.name = name
	found, ok := resolve_type_identifier(ctx.ast_context, ident^)
	// The resolver answers a builtin type's name before it looks at the locals and globals that can shadow it. A
	// distinct type of a builtin has the same kind and is a declaration of its own.
	if ok && found.type == .Keyword && .Distinct not_in found.flags {
		_, is_local := get_local(ctx.ast_context^, ident^)
		_, is_global := ctx.ast_context.globals[name]
		if is_local || is_global {
			return {}, false
		}
	}
	return found, ok
}

// A procedure's name or a type's name as a value gives the local a type that only the value's own symbol tells, and
// symbol_type_text then prints that name.
names_a_value :: proc(ctx: ^ActionContext, value: ^ast.Expr) -> bool {
	inner := unparen(value)
	#partial switch v in inner.derived {
	case ^ast.Ident:
		if v.name == "true" || v.name == "false" {
			return true
		}
	case ^ast.Selector_Expr:
	case:
		return true
	}
	ctx.ast_context.use_locals = true
	symbol, ok := resolve_type_expression(ctx.ast_context, value)
	if !ok {
		return false
	}
	#partial switch symbol.type {
	case .Variable, .Constant, .EnumMember, .Field:
		_, is_proc := symbol.value.(SymbolProcedureValue)
		return !is_proc
	}
	return false
}

// `'a' + 1` is a rune, and the resolver takes the kind of the right operand. An operation on two untyped kinds has no
// type this server can trust.
mixes_untyped_kinds :: proc(ctx: ^ActionContext, expr: ^ast.Expr) -> bool {
	#partial switch e in expr.derived {
	case ^ast.Paren_Expr:
		return mixes_untyped_kinds(ctx, e.expr)
	case ^ast.Unary_Expr:
		return mixes_untyped_kinds(ctx, e.expr)
	case ^ast.Binary_Expr:
		if is_comparison(e.op.kind) {
			return false
		}
		if mixes_untyped_kinds(ctx, e.left) || mixes_untyped_kinds(ctx, e.right) {
			return true
		}
		ctx.ast_context.use_locals = true
		left, left_ok := resolve_type_expression(ctx.ast_context, e.left)
		ctx.ast_context.use_locals = true
		right, right_ok := resolve_type_expression(ctx.ast_context, e.right)
		if !left_ok || !right_ok {
			return false
		}
		left_value, left_untyped := left.value.(SymbolUntypedValue)
		right_value, right_untyped := right.value.(SymbolUntypedValue)
		return left_untyped && right_untyped && left_value.type != right_value.type
	}
	return false
}

// `x: T` then `x = v` becomes `x: T = v`, and `x := v` where v has the type T.
join_declaration :: proc(ctx: ^ActionContext, decl: ^ast.Value_Decl, assign: ^ast.Assign_Stmt) {
	if len(decl.names) != 1 || len(decl.values) != 0 || decl.type == nil {
		return
	}
	if assign.op.kind != .Eq || len(assign.lhs) != 1 || len(assign.rhs) != 1 {
		return
	}
	src := ctx.document.ast.src
	name := decl.names[0].derived.(^ast.Ident)
	target, is_ident := assign.lhs[0].derived.(^ast.Ident)
	value := assign.rhs[0]
	if !is_ident || target.name != name.name || reads_name(value, name.name) {
		return
	}
	// The assignment must start on the next line. A comment or a blank line between has no place in the result.
	if strings.trim_space(src[decl.end.offset:assign.pos.offset]) != "" ||
	   strings.count(src[decl.end.offset:assign.pos.offset], "\n") != 1 ||
	   strings.trim_space(src[target.end.offset:value.pos.offset]) != "=" {
		return
	}
	append_replace_range(ctx, decl.type.end.offset, value.pos.offset, "Join declaration", " = ")

	inferred, ok := inferred_type(ctx, name, value, assign.pos.offset)
	if ok && inferred == node_text(src, decl.type) {
		append_replace_range(ctx, name.end.offset, value.pos.offset, "Join declaration with inferred type", " := ")
	}
}

// `a, b := 1, 2` becomes two lines.
split_names :: proc(ctx: ^ActionContext, decl: ^ast.Value_Decl) {
	if len(decl.names) < 2 || len(decl.values) != len(decl.names) || !can_restate_type(decl.type) {
		return
	}
	src := ctx.document.ast.src
	for group in ctx.document.ast.comments {
		if decl.pos.offset <= group.pos.offset && group.end.offset <= decl.end.offset {
			return
		}
	}
	for value, i in decl.values {
		// The list reads every value before it declares a name. Separate lines read the names above them.
		for earlier in decl.names[:i] {
			name := earlier.derived.(^ast.Ident).name
			if reads_name(value, name) || decl.type != nil && reads_name(decl.type, name) {
				return
			}
		}
		// A call can write what another operand reads, and the compiler gives no order within the list.
		if has_side_effect(value) {
			for other, j in decl.values {
				if j != i && !is_constant(ctx, other) {
					return
				}
			}
		}
	}

	indent := get_line_indentation(src, decl.pos.offset)
	text := strings.builder_make(context.temp_allocator)
	for value, i in decl.values {
		if i > 0 {
			fmt.sbprintf(&text, "\n%s", indent)
		}
		name := decl.names[i].derived.(^ast.Ident).name
		if decl.type != nil {
			fmt.sbprintf(&text, "%s: %s = %s", name, node_text(src, decl.type), node_text(src, value))
		} else {
			fmt.sbprintf(&text, "%s := %s", name, node_text(src, value))
		}
	}
	append_replace_range(
		ctx,
		decl.pos.offset,
		decl.end.offset,
		"Split into separate declarations",
		strings.to_string(text),
	)
}
