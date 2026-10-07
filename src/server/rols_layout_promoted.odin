package server

import "core:odin/ast"

// Returns the byte offset of field `index` of the flattened struct `v`, following `using` fields down to the
// struct that declares it. Fails for a field promoted through a pointer, a bit_field or an unresolved type.
promoted_field_offset :: proc(
	ast_context: ^AstContext,
	v: SymbolStructValue,
	index: int,
	depth := 0,
) -> (
	offset: i64,
	ok: bool,
) {
	if depth > LAYOUT_MAX_DEPTH || index < 0 || index >= len(v.names) {
		return 0, false
	}

	using_index := index < len(v.from_usings) ? v.from_usings[index] : -1
	if using_index == -1 {
		fields := make([dynamic]Field_Layout, context.temp_allocator)
		struct_layout(ast_context, v, depth + 1, &fields) or_return
		for f in fields {
			if f.name == v.names[index] {
				return f.offset, true
			}
		}
		return 0, false
	}

	base := promoted_field_offset(ast_context, v, using_index, depth + 1) or_return
	inner := using_field_struct(ast_context, v.types[using_index]) or_return
	for name, j in inner.names {
		if name == v.names[index] {
			within := promoted_field_offset(ast_context, inner, j, depth + 1) or_return
			return base + within, true
		}
	}
	return 0, false
}

@(private = "file")
using_field_struct :: proc(ast_context: ^AstContext, type: ^ast.Expr) -> (v: SymbolStructValue, ok: bool) {
	symbol := resolve_type_expression(ast_context, type) or_return
	if symbol.pointers > 0 {
		return {}, false
	}
	return symbol.value.(SymbolStructValue)
}
