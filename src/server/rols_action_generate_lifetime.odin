#+private file
package server

import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:slice"
import "core:strings"

import "src:common"

// On the name of a top-level non-parametric struct: "Generate destroy_foo", which deletes each `[dynamic]` and map
// field and names in a comment the slices, strings and pointers that can be borrowed, and "Generate init_foo", which
// makes each `[dynamic]` and map field with the allocator it takes. Both go after the struct, in its file.
@(private = "package")
add_generate_lifetime_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_generate_lifetime {
		return
	}
	decl, found := top_decl_at(ctx.document, ctx.range.start)
	if !found || decl.is_mutable || decl.type != nil || len(decl.values) != 1 {
		return
	}
	type, is_struct := decl.values[0].derived.(^ast.Struct_Type)
	// The fields of a raw union overlap, so freeing or making each of them would touch one memory twice.
	if !is_struct || type.poly_params != nil || type.is_raw_union || type.fields == nil {
		return
	}
	src := ctx.document.ast.src
	name := node_text(src, decl.names[0])
	// A package declaration or an import named like these builtins would take the generated calls.
	for builtin in ([]string{"make", "delete", "type_of"}) {
		if package_declares(ctx, builtin) {
			return
		}
	}

	param := strings.to_snake_case(name, context.temp_allocator)
	if !is_plain_name(param) || slice.contains([]string{"make", "delete", "type_of", "allocator"}, param) {
		param = "value"
	}

	owned := make([dynamic]Owned_Field, context.temp_allocator)
	borrowed := make([dynamic]string, context.temp_allocator)
	for field in type.fields.list {
		kind := field_kind(ctx, field.type)
		if kind == .None {
			continue
		}
		type_text := written_type(src, field.type)
		// The parameters shadow a type name that the field type uses, and a type over several lines would break the call.
		if strings.contains_any(type_text, "\r\n") || type_names_clash(type_text, {param, "allocator"}) {
			type_text = ""
		}
		for field_name in field.names {
			text := node_text(src, field_name)
			if text == "_" {
				continue
			}
			if kind == .Owned {
				append(&owned, Owned_Field{text, type_text})
			} else {
				append(&borrowed, text)
			}
		}
	}

	unit := indent_unit(src, "", nil)
	snake := strings.to_snake_case(name, context.temp_allocator)
	if len(owned) > 0 || len(borrowed) > 0 {
		sb := strings.builder_make(context.temp_allocator)
		proc_name := strings.concatenate({"destroy_", snake}, context.temp_allocator)
		fmt.sbprintf(&sb, "%s :: proc(%s: ^%s) {{\n", proc_name, param, name)
		for field in owned {
			fmt.sbprintf(&sb, "%sdelete(%s.%s)\n", unit, param, field.name)
		}
		if len(borrowed) > 0 {
			fmt.sbprintf(
				&sb,
				"%s// Not freed, since these can be borrowed: %s.\n",
				unit,
				strings.join(borrowed[:], ", ", context.temp_allocator),
			)
		}
		strings.write_string(&sb, "}")
		add_generated(ctx, decl, fmt.tprintf("Generate %s", proc_name), proc_name, strings.to_string(sb))
	}
	if len(owned) > 0 {
		sb := strings.builder_make(context.temp_allocator)
		proc_name := strings.concatenate({"init_", snake}, context.temp_allocator)
		fmt.sbprintf(&sb, "%s :: proc(%s: ^%s, allocator := context.allocator) {{\n", proc_name, param, name)
		for field in owned {
			made := field.type_text
			if made == "" {
				made = fmt.tprintf("type_of(%s.%s)", param, field.name)
			}
			fmt.sbprintf(&sb, "%s%s.%s = make(%s, allocator)\n", unit, param, field.name, made)
		}
		strings.write_string(&sb, "}")
		add_generated(ctx, decl, fmt.tprintf("Generate %s", proc_name), proc_name, strings.to_string(sb))
	}
}

Owned_Field :: struct {
	name:      string,
	// The written type, "" when the call has to spell it `type_of(foo.f)`.
	type_text: string,
}

Field_Kind :: enum {
	None,
	// A `[dynamic]` array or a map, which `delete` frees and `make` makes.
	Owned,
	// A slice, string or pointer, which may own memory or point into memory of another value.
	Borrowed,
}

// What a field of this type holds. A type that does not resolve, and a fixed-capacity `[dynamic; N]T`, which `delete`
// and `make` do not take, hold nothing to free.
field_kind :: proc(ctx: ^ActionContext, type: ^ast.Expr) -> Field_Kind {
	if type == nil {
		return .None
	}
	reset_ast_context(ctx.ast_context)
	symbol, resolved := resolve_type_expression(ctx.ast_context, type)
	if !resolved {
		return .None
	}
	if symbol.pointers > 0 {
		return .Borrowed
	}
	#partial switch v in symbol.value {
	case SymbolDynamicArrayValue:
		return .Owned if v.cap == nil else .None
	case SymbolMapValue:
		return .Owned
	case SymbolSliceValue, SymbolMultiPointerValue:
		return .Borrowed
	case SymbolBasicValue:
		if v.ident != nil &&
		   slice.contains([]string{"string", "string16", "cstring", "cstring16", "rawptr"}, v.ident.name) {
			return .Borrowed
		}
	}
	return .None
}

// The type as written, with the `#soa` tag that the node of `#soa[dynamic]T` starts after.
written_type :: proc(src: string, type: ^ast.Expr) -> string {
	start := type.pos.offset
	#partial switch v in type.derived {
	case ^ast.Array_Type:
		if v.tag != nil do start = min(start, v.tag.pos.offset)
	case ^ast.Dynamic_Array_Type:
		if v.tag != nil do start = min(start, v.tag.pos.offset)
	}
	return src[start:type.end.offset]
}

// Whether name is an identifier and not a keyword such as `context` or `map`, nor a builtin type name.
@(private = "package")
is_plain_name :: proc(name: string) -> bool {
	if name in keyword_map {
		return false
	}
	t: tokenizer.Tokenizer
	tokenizer.init(&t, name, "", common.parser_warning_handler)
	tok := tokenizer.scan(&t)
	return tok.kind == .Ident && tok.text == name && tokenizer.scan(&t).kind == .EOF
}

// Whether the package or an import of the document already declares name.
@(private = "package")
package_declares :: proc(ctx: ^ActionContext, name: string) -> bool {
	if name in ctx.ast_context.globals || document_imports_alias(ctx.document, name) {
		return true
	}
	_, indexed := lookup(name, ctx.document.package_name, ctx.document.fullpath)
	return indexed
}

// The action inserting text, a new declaration named name, after decl. A taken name refuses.
@(private = "package")
add_generated :: proc(ctx: ^ActionContext, decl: ^ast.Value_Decl, title, name, text: string) {
	if package_declares(ctx, name) {
		return
	}
	insert, ok := insert_after_decl(ctx, decl.pos.offset, text)
	if !ok {
		return
	}
	edits := make([]TextEdit, 1, context.temp_allocator)
	edits[0] = insert
	append(ctx.actions, make_code_action(ctx, title, "refactor", edits))
}
