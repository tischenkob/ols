package server

import "core:odin/ast"

// Appends the enum and bit_set values that each tied member of a group call takes at the parameter at
// parameter_index, or at the parameter that a named argument at the cursor names. Each label appears once.
append_tied_member_arg_completions :: proc(
	ast_context: ^AstContext,
	position_context: ^DocumentPositionContext,
	members: []Symbol,
	parameter_index: int,
	results: ^[dynamic]CompletionResult,
) {
	start := len(results)
	for member in members {
		append_member_arg_completions(ast_context, position_context, member, parameter_index, results)
	}

	seen := make(map[string]struct{}, context.temp_allocator)
	kept := start
	for i in start ..< len(results) {
		if item, is_item := results[i].completion_item.?; is_item {
			if item.label in seen {
				continue
			}
			seen[item.label] = {}
		}
		results[kept] = results[i]
		kept += 1
	}
	resize(results, kept)
}

// The values of one member's parameter, read as the procedure case of `get_implicit_completion` reads them.
@(private = "file")
append_member_arg_completions :: proc(
	ast_context: ^AstContext,
	position_context: ^DocumentPositionContext,
	member: Symbol,
	parameter_index: int,
	results: ^[dynamic]CompletionResult,
) {
	value, is_proc := member.value.(SymbolProcedureValue)
	if !is_proc {
		return
	}
	set_ast_package_from_symbol_scoped(ast_context, member)

	arg, has_arg := get_proc_arg_type_from_index(value, parameter_index)
	if !has_arg {
		return
	}
	if position_context.field_value != nil {
		if name, is_ident := position_context.field_value.field.derived.(^ast.Ident); is_ident {
			if i, found := get_field_list_name_index(name.name, value.arg_types); found {
				arg = value.arg_types[i]
			}
		}
	}

	type := arg.type
	if type == nil && arg.default_value != nil {
		#partial switch default in arg.default_value.derived {
		case ^ast.Comp_Lit:
			type = default.type
		case ^ast.Selector_Expr:
			type = default.expr
		case:
			type = arg.default_value
		}
	}

	if type == nil {
		return
	}
	if enum_value, unwrapped_super_enum, ok := unwrap_enum(ast_context, type); ok {
		append_enum_completion_items(enum_value, ast_context, position_context, results, unwrapped_super_enum)
		return
	}
	if bitset_symbol, ok := resolve_type_expression(ast_context, type); ok {
		if enum_value, ok := unwrap_bitset(ast_context, bitset_symbol); ok {
			append_enum_completion_items(enum_value, ast_context, position_context, results)
		}
	}
}
