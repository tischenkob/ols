#+private file

package server

import "core:odin/ast"
import "core:slice"
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
	if array, is_array := symbol.value.(SymbolFixedArrayValue); is_array {
		add_fill_keys(ctx, lit, symbol, array)
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
	ind, deeper := literal_indents(src, lit)
	sb := strings.builder_make(context.temp_allocator)
	write_present_elems(&sb, src, lit, deeper)

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

literal_indents :: proc(src: string, lit: ^ast.Comp_Lit) -> (ind, deeper: string) {
	ind = get_line_indentation(src, lit.pos.offset)
	deeper = strings.concatenate({ind, indent_unit(src, ind, nil)}, context.temp_allocator)
	return
}

// The opening brace and the elements already written, each ending with a comma.
write_present_elems :: proc(sb: ^strings.Builder, src: string, lit: ^ast.Comp_Lit, deeper: string) {
	strings.write_byte(sb, '{')
	if len(lit.elems) == 0 {
		return
	}
	last := lit.elems[len(lit.elems) - 1]
	if lit.open.line == lit.close.line {
		for elem in lit.elems {
			strings.write_byte(sb, '\n')
			strings.write_string(sb, deeper)
			strings.write_string(sb, node_text(src, elem))
			strings.write_byte(sb, ',')
		}
	} else {
		strings.write_string(sb, src[lit.open.offset + 1:last.end.offset])
		tail := src[last.end.offset:lit.close.offset]
		if !strings.has_prefix(strings.trim_space(tail), ",") {
			strings.write_byte(sb, ',')
		}
		strings.write_string(sb, strings.trim_right_space(tail))
	}
}

// An enumerated array: one line per value of the enum that no key covers. An alias shares the value of its member, and
// `odin check` rejects a second key for one value. A positional element, or a range as a key, refuses.
add_fill_keys :: proc(ctx: ^ActionContext, lit: ^ast.Comp_Lit, symbol: Symbol, array: SymbolFixedArrayValue) {
	if array.len == nil || array.expr == nil {
		return
	}
	set_ast_package_set_scoped(ctx.ast_context, symbol.pkg)
	reset_ast_context(ctx.ast_context)
	index, index_ok := resolve_type_expression(ctx.ast_context, array.len)
	if !index_ok {
		return
	}
	members, is_enum := index.value.(SymbolEnumValue)
	if !is_enum {
		return
	}
	_, classes := enum_member_values(ctx.ast_context, members)
	covered := make([]bool, len(members.names), context.temp_allocator)
	for elem in lit.elems {
		field, is_keyed := elem.derived.(^ast.Field_Value)
		if !is_keyed {
			return
		}
		name: string
		#partial switch key in field.field.derived {
		case ^ast.Implicit_Selector_Expr:
			name = key.field.name
		case ^ast.Selector_Expr:
			name = key.field.name
		case:
			return
		}
		member, found := slice.linear_search(members.names, name)
		if !found {
			return
		}
		covered[classes[member]] = true
	}
	reset_ast_context(ctx.ast_context)
	element, element_ok := resolve_type_expression(ctx.ast_context, array.expr)
	zero := zero_value_text(element, element_ok)

	src := ctx.document.ast.src
	ind, deeper := literal_indents(src, lit)
	sb := strings.builder_make(context.temp_allocator)
	write_present_elems(&sb, src, lit, deeper)
	missing := 0
	for name, i in members.names {
		if classes[i] != i || covered[i] {
			continue
		}
		missing += 1
		strings.write_byte(&sb, '\n')
		strings.write_string(&sb, deeper)
		strings.write_byte(&sb, '.')
		strings.write_string(&sb, name)
		strings.write_string(&sb, " = ")
		strings.write_string(&sb, zero)
		strings.write_byte(&sb, ',')
	}
	if missing == 0 {
		return
	}
	strings.write_byte(&sb, '\n')
	strings.write_string(&sb, ind)
	strings.write_byte(&sb, '}')
	append_replace_range(ctx, lit.open.offset, lit.close.offset + 1, "Fill missing keys", strings.to_string(sb))
}
