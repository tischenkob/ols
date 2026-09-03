#+private file

package server

import "core:odin/ast"
import "core:strings"

@(private = "package")
add_fill_struct_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_fill_struct {
		return
	}
	lit := ctx.position_context.comp_lit
	if lit == nil {
		return
	}

	symbol: Symbol
	ok: bool
	if lit.type != nil {
		symbol, ok = resolve_type_expression(ctx.ast_context, lit.type)
	} else {
		symbol, ok = resolve_comp_literal(ctx.ast_context, ctx.position_context)
	}
	if !ok {
		return
	}
	value, is_struct := symbol.value.(SymbolStructValue)
	if !is_struct {
		return
	}

	present := make(map[string]struct{}, context.temp_allocator)
	for elem in lit.elems {
		field, is_named := elem.derived.(^ast.Field_Value)
		if !is_named {
			return
		}
		if name, is_ident := field.field.derived.(^ast.Ident); is_ident {
			present[name.name] = {}
		}
	}

	src := ctx.document.ast.src
	ind := get_line_indentation(src, lit.pos.offset)
	deeper := strings.concatenate({ind, indent_unit(src, ind, nil)}, context.temp_allocator)

	sb := strings.builder_make(context.temp_allocator)
	strings.write_byte(&sb, '{')
	if len(lit.elems) > 0 {
		last := lit.elems[len(lit.elems) - 1]
		if lit.open.line == lit.close.line {
			for elem in lit.elems {
				strings.write_byte(&sb, '\n')
				strings.write_string(&sb, deeper)
				strings.write_string(&sb, node_text(src, elem))
				strings.write_byte(&sb, ',')
			}
		} else {
			strings.write_string(&sb, src[lit.open.offset + 1:last.end.offset])
			tail := src[last.end.offset:lit.close.offset]
			if !strings.has_prefix(strings.trim_space(tail), ",") {
				strings.write_byte(&sb, ',')
			}
			strings.write_string(&sb, strings.trim_right_space(tail))
		}
	}

	missing := 0
	for name, i in value.names {
		// Expanded members of a `using` field are filled through the field itself.
		if name == "_" || value.from_usings[i] != -1 || name in present {
			continue
		}
		missing += 1
		strings.write_byte(&sb, '\n')
		strings.write_string(&sb, deeper)
		strings.write_string(&sb, name)
		strings.write_string(&sb, " = ")
		set_ast_package_set_scoped(ctx.ast_context, symbol.pkg)
		field_type, resolved := resolve_type_expression(ctx.ast_context, value.types[i])
		strings.write_string(&sb, zero_value_text(field_type, resolved))
		strings.write_byte(&sb, ',')
	}
	if missing == 0 {
		return
	}
	strings.write_byte(&sb, '\n')
	strings.write_string(&sb, ind)
	strings.write_byte(&sb, '}')

	title := len(lit.elems) == 0 ? "Fill all fields" : "Fill missing fields"
	append_replace_range(ctx, lit.open.offset, lit.close.offset + 1, title, strings.to_string(sb))
}

// `{}` is the zero literal for every aggregate, including enums and unions. The scalar forms are
// the shortest ones the compiler accepts for each basic type.
zero_value_text :: proc(symbol: Symbol, resolved: bool) -> string {
	if !resolved {
		return "{}"
	}
	if symbol.pointers > 0 {
		return "nil"
	}
	#partial switch v in symbol.value {
	case SymbolBasicValue:
		switch v.ident.name {
		case "bool", "b8", "b16", "b32", "b64":
			return "false"
		case "string", "cstring":
			return `""`
		case "rawptr", "any", "typeid":
			return "nil"
		}
		return "0"
	case SymbolMultiPointerValue,
	     SymbolSliceValue,
	     SymbolDynamicArrayValue,
	     SymbolMapValue,
	     SymbolProcedureValue,
	     SymbolProcedureGroupValue:
		return "nil"
	}
	return "{}"
}
