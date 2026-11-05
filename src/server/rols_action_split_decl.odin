#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:strings"

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
		if strings.trim_space(src[decl.type.end.offset:value.pos.offset]) != "=" {
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
	gather_locals_at(ctx, decl.end.offset)
	defer restore_locals(ctx)
	type, ok := local_type_text(ctx, name)
	if !ok || !names_a_value(ctx, value) {
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

// A procedure's name or a type's name as a value gives the local a type that only the value's own symbol tells, and
// symbol_type_text then prints that name.
names_a_value :: proc(ctx: ^ActionContext, value: ^ast.Expr) -> bool {
	#partial switch _ in unparen(value).derived {
	case ^ast.Ident, ^ast.Selector_Expr:
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
	// A comment between the two has no place in the result.
	if strings.trim_space(src[decl.end.offset:assign.pos.offset]) != "" ||
	   strings.trim_space(src[target.end.offset:value.pos.offset]) != "=" {
		return
	}
	append_replace_range(ctx, decl.type.end.offset, value.pos.offset, "Join declaration", " = ")

	type := node_text(src, decl.type)
	inferred, ok := constant_default_type(ctx, value)
	if !ok {
		gather_locals_at(ctx, assign.pos.offset)
		defer restore_locals(ctx)
		// As `x := v` resolves it, since a resolved call is the procedure and not its result.
		results := make([dynamic]^ast.Expr, context.temp_allocator)
		calls := make(map[int]struct{}, context.temp_allocator)
		get_generic_assignment(ctx.ast_context.file, value, ctx.ast_context, &results, &calls, {}, true)
		if len(results) != 1 {
			return
		}
		ctx.ast_context.use_locals = true
		symbol, resolved := resolve_type_expression(ctx.ast_context, results[0])
		if !resolved {
			return
		}
		inferred, ok = symbol_type_text(ctx.ast_context, symbol, "", require_import = true)
	}
	if ok && inferred == type {
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
