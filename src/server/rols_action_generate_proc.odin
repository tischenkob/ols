#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"

@(private = "package")
add_generate_proc_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_generate_proc {
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
	if call == nil || parent == nil {
		return
	}
	callee, is_ident := call.expr.derived.(^ast.Ident)
	if !is_ident || callee.name in keyword_map {
		return
	}
	ctx.ast_context.use_locals = true
	if _, resolved := resolve_type_identifier(ctx.ast_context, callee^); resolved {
		return
	}

	src := ctx.document.ast.src
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, callee.name)
	strings.write_string(&sb, " :: proc(")

	names := make([dynamic]string, context.temp_allocator)
	for arg, i in call.args {
		arg := arg
		name := fmt.tprintf("arg%d", i + 1)
		if fv, is_named := arg.derived.(^ast.Field_Value); is_named {
			name = final_name(fv.field)
			arg = fv.value
		} else if n := final_name(arg); n != "" {
			name = n
		}
		base := name
		for k := 2; slice.contains(names[:], name); k += 1 {
			name = fmt.tprintf("%s%d", base, k)
		}
		append(&names, name)

		symbol, ok := resolve_type_expression(ctx.ast_context, arg)
		if !ok {
			return
		}
		// Untyped literals print as their default types only when marked mutable.
		symbol.flags += {.Mutable}
		text, text_ok := symbol_type_text(ctx.ast_context, symbol, name)
		if !text_ok {
			return
		}
		if i > 0 {
			strings.write_string(&sb, ", ")
		}
		strings.write_string(&sb, name)
		strings.write_string(&sb, ": ")
		strings.write_string(&sb, text)
	}
	strings.write_byte(&sb, ')')

	result, zero, has_result, ok := call_result(ctx, function, call, parent)
	if !ok {
		return
	}
	if has_result {
		strings.write_string(&sb, " -> ")
		strings.write_string(&sb, result)
	}
	strings.write_string(&sb, " {\n")
	if has_result {
		strings.write_string(&sb, indent_unit(src, "", nil))
		strings.write_string(&sb, "return ")
		strings.write_string(&sb, zero)
		strings.write_byte(&sb, '\n')
	}
	strings.write_byte(&sb, '}')

	insert, insert_ok := insert_after_decl(ctx, call.pos.offset, strings.to_string(sb))
	if !insert_ok {
		return
	}
	edits := make([]TextEdit, 1, context.temp_allocator)
	edits[0] = insert
	title := fmt.tprintf("Generate procedure %s", callee.name)
	append(ctx.actions, make_code_action(ctx, title, "quickfix", edits))
}

// The result type the call's context demands, as source text with its zero value. ok is false
// when the context needs a result whose type is not stated anywhere.
call_result :: proc(
	ctx: ^ActionContext,
	function: ^ast.Proc_Lit,
	call: ^ast.Call_Expr,
	parent: ^ast.Node,
) -> (
	result, zero: string,
	has_result, ok: bool,
) {
	src := ctx.document.ast.src
	type: ^ast.Expr

	#partial switch p in parent.derived {
	case ^ast.Expr_Stmt:
		return "", "", false, true
	case ^ast.If_Stmt, ^ast.For_Stmt:
		return "bool", "false", true, true
	case ^ast.Unary_Expr:
		if p.op.kind == .Not {
			return "bool", "false", true, true
		}
	case ^ast.Binary_Expr:
		if p.op.kind == .Cmp_And || p.op.kind == .Cmp_Or {
			return "bool", "false", true, true
		}
	case ^ast.Value_Decl:
		if len(p.names) != 1 || len(p.values) != 1 || p.type == nil {
			return
		}
		type = p.type
	case ^ast.Return_Stmt:
		if function.type == nil || function.type.results == nil {
			return
		}
		types := field_types(function.type.results.list)
		i, found := slice.linear_search(p.results, call)
		if !found || len(types) != len(p.results) {
			return
		}
		type = types[i]
	case ^ast.Call_Expr:
		i, found := slice.linear_search(p.args, call)
		symbol, resolved := resolve_type_expression(ctx.ast_context, p.expr)
		if !found || !resolved {
			return
		}
		value, is_proc := symbol.value.(SymbolProcedureValue)
		if !is_proc {
			return
		}
		params := field_types(value.arg_types)
		if i >= len(params) || params[i] == nil {
			return
		}
		set_ast_package_set_scoped(ctx.ast_context, symbol.pkg)
		param, param_ok := resolve_type_expression(ctx.ast_context, params[i])
		if !param_ok {
			return
		}
		result, ok = symbol_type_text(ctx.ast_context, param, "")
		return result, zero_value_text(param, true), true, ok
	}
	if type == nil {
		return
	}
	symbol, resolved := resolve_type_expression(ctx.ast_context, type)
	return node_text(src, type), zero_value_text(symbol, resolved), true, true
}
