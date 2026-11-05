#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:strings"

// On the name of a top-level struct: "Reorder fields to reduce padding (A to B bytes)" sorts the fields by descending
// alignment, keeping the order of fields with the same alignment, when that makes the struct smaller. Sizes are those
// of a 64-bit target.
@(private = "package")
add_reorder_fields_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_reorder_fields {
		return
	}
	decl, found := top_decl_at(ctx.document, ctx.range.start)
	if !found || decl.is_mutable || decl.type != nil || len(decl.values) != 1 {
		return
	}
	type, is_struct := decl.values[0].derived.(^ast.Struct_Type)
	if !is_struct || type.fields == nil || len(type.fields.list) < 2 {
		return
	}
	// These fix the layout, or make it depend on the arguments.
	if type.is_packed ||
	   type.is_raw_union ||
	   type.align != nil ||
	   type.min_field_align != nil ||
	   type.max_field_align != nil ||
	   type.poly_params != nil {
		return
	}
	src := ctx.document.ast.src
	list := type.fields.list
	layouts := make([]Layout, len(list), context.temp_allocator)
	for field, i in list {
		// `using` and `#subtype` give the first field a meaning, and a `_` field pads on purpose.
		if field.flags & {.Using, .Subtype} != {} || field.type == nil {
			return
		}
		for name in field.names {
			if node_text(src, name) == "_" {
				return
			}
		}
		layout, known := type_layout(ctx, field.type, ctx.document.package_name, 0)
		if !known {
			return
		}
		layouts[i] = layout
	}

	order := make([]int, len(list), context.temp_allocator)
	for i in 0 ..< len(order) {
		order[i] = i
	}
	// An insertion sort keeps fields of one alignment in their order.
	for i in 1 ..< len(order) {
		for j := i; j > 0 && layouts[order[j]].align > layouts[order[j - 1]].align; j -= 1 {
			order[j], order[j - 1] = order[j - 1], order[j]
		}
	}
	before := struct_size(list, layouts, nil)
	after := struct_size(list, layouts, order)
	if after >= before {
		return
	}
	name := node_text(src, decl.names[0])
	if layout_exposed(ctx, name) {
		return
	}
	start, end, text, ok := reordered_text(src, type, order)
	if !ok {
		return
	}
	append_replace_range(
		ctx,
		start,
		end,
		fmt.tprintf("Reorder fields to reduce padding (%d to %d bytes)", before, after),
		text,
	)
}

Layout :: struct {
	size, align: int,
}

align_up :: proc(offset, align: int) -> int {
	return (offset + align - 1) / align * align
}

// The size of a struct with these fields, in order when given, each layout counted once per name.
struct_size :: proc(list: []^ast.Field, layouts: []Layout, order: []int) -> int {
	offset, align := 0, 1
	for i in 0 ..< len(list) {
		at := order[i] if order != nil else i
		layout := layouts[at]
		for _ in list[at].names {
			offset = align_up(offset, layout.align) + layout.size
		}
		align = max(align, layout.align)
	}
	return align_up(offset, align)
}

// The size and alignment of a type written in pkg, on a 64-bit target. known is false for a type whose layout this does
// not compute, such as a union, an enumerated array or a struct with layout tags.
type_layout :: proc(ctx: ^ActionContext, type: ^ast.Expr, pkg: string, depth: int) -> (layout: Layout, known: bool) {
	if type == nil || depth > 8 {
		return {}, false
	}
	#partial switch t in type.derived {
	case ^ast.Pointer_Type, ^ast.Multi_Pointer_Type, ^ast.Proc_Type:
		return {8, 8}, true
	case ^ast.Map_Type:
		return {32, 8}, true
	case ^ast.Dynamic_Array_Type:
		if t.tag != nil {
			return {}, false
		}
		return {40, 8}, true
	case ^ast.Array_Type:
		if t.tag != nil {
			return {}, false
		}
		if t.len == nil {
			return {16, 8}, true
		}
		return array_layout(ctx, t.len, t.elem, pkg, depth)
	case ^ast.Paren_Expr:
		return type_layout(ctx, t.expr, pkg, depth)
	}
	expected, resolved := type_at(ctx, type, pkg)
	if !resolved {
		return {}, false
	}
	symbol := expected.symbol
	if symbol.pointers > 0 {
		return {8, 8}, true
	}
	if symbol.flags & {.Soa, .SoaPointer, .Simd, .Mutable, .Variable} != {} {
		return {}, false
	}
	#partial switch v in symbol.value {
	case SymbolBasicValue:
		if v.ident == nil {
			return {}, false
		}
		return basic_layout(v.ident.name)
	case SymbolMultiPointerValue, SymbolProcedureValue:
		return {8, 8}, true
	case SymbolSliceValue:
		return {16, 8}, true
	case SymbolMapValue:
		return {32, 8}, true
	case SymbolDynamicArrayValue:
		if v.cap != nil {
			return {}, false
		}
		return {40, 8}, true
	case SymbolFixedArrayValue:
		return array_layout(ctx, v.len, v.expr, symbol.pkg, depth)
	case SymbolEnumValue:
		if v.base_type == nil {
			return {8, 8}, true
		}
		return type_layout(ctx, v.base_type, symbol.pkg, depth + 1)
	case SymbolBitSetValue:
		if v.underlying == nil {
			return {}, false
		}
		return type_layout(ctx, v.underlying, symbol.pkg, depth + 1)
	case SymbolStructValue:
		if v.poly != nil ||
		   v.align != nil ||
		   v.min_field_align != nil ||
		   v.max_field_align != nil ||
		   v.tags & {.Is_Packed, .Is_Raw_Union} != {} ||
		   len(v.objc_ivars) > 0 {
			return {}, false
		}
		offset, align := 0, 1
		for field_type in v.types {
			field := type_layout(ctx, field_type, symbol.pkg, depth + 1) or_return
			offset = align_up(offset, field.align) + field.size
			align = max(align, field.align)
		}
		return {align_up(offset, align), align}, true
	}
	return {}, false
}

// `[N]T` with N written as an integer literal.
array_layout :: proc(
	ctx: ^ActionContext,
	count, elem: ^ast.Expr,
	pkg: string,
	depth: int,
) -> (
	layout: Layout,
	known: bool,
) {
	lit, is_lit := count.derived.(^ast.Basic_Lit)
	if !is_lit || lit.tok.kind != .Integer {
		return {}, false
	}
	n, parsed := parse_integer_literal(lit.tok.text)
	if !parsed || n < 0 {
		return {}, false
	}
	inner := type_layout(ctx, elem, pkg, depth + 1) or_return
	return {inner.size * n, inner.align}, true
}

parse_integer_literal :: proc(text: string) -> (int, bool) {
	digits, _ := strings.replace_all(text, "_", "", context.temp_allocator)
	base := 10
	if len(digits) > 2 && digits[0] == '0' {
		switch digits[1] {
		case 'x':
			base = 16
		case 'o':
			base = 8
		case 'b':
			base = 2
		}
		if base != 10 {
			digits = digits[2:]
		}
	}
	n := 0
	for c in digits {
		d: int
		switch c {
		case '0' ..= '9':
			d = int(c - '0')
		case 'a' ..= 'f':
			d = int(c - 'a') + 10
		case 'A' ..= 'F':
			d = int(c - 'A') + 10
		case:
			return 0, false
		}
		if d >= base || n > 1 << 40 {
			return 0, false
		}
		n = n * base + d
	}
	return n, true
}

basic_layout :: proc(name: string) -> (Layout, bool) {
	base := name
	for suffix in ([]string{"le", "be"}) {
		if len(base) > 3 && strings.has_suffix(base, suffix) {
			base = base[:len(base) - 2]
		}
	}
	switch base {
	case "bool", "b8", "i8", "u8":
		return {1, 1}, true
	case "b16", "i16", "u16", "f16":
		return {2, 2}, true
	case "b32", "i32", "u32", "f32", "rune":
		return {4, 4}, true
	case "b64", "i64", "u64", "f64", "int", "uint", "uintptr", "rawptr", "cstring", "cstring16", "typeid":
		return {8, 8}, true
	case "i128", "u128":
		return {16, 16}, true
	case "complex32":
		return {4, 2}, true
	case "complex64":
		return {8, 4}, true
	case "complex128":
		return {16, 8}, true
	case "quaternion64":
		return {8, 2}, true
	case "quaternion128":
		return {16, 4}, true
	case "quaternion256":
		return {32, 8}, true
	case "string", "string16", "any":
		return {16, 8}, true
	}
	return {}, false
}

// Whether code of the workspace depends on the field order of the struct named name: a literal that lists its values
// by position, a `transmute`, or a foreign procedure. A memory cast through a pointer goes unseen.
layout_exposed :: proc(ctx: ^ActionContext, name: string) -> bool {
	documents, ok := workspace_documents(ctx, name)
	if !ok {
		return true
	}
	Data :: struct {
		name:  string,
		found: bool,
	}
	data := Data {
		name = name,
	}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil || data.found {
				return nil
			}
			#partial switch n in node.derived {
			case ^ast.Comp_Lit:
				if n.type == nil {
					break
				}
				if names_type(n.type, data.name) {
					data.found ||= is_positional(n)
				}
				// `[]Foo{{1, 2}}` lists the values of each element by position.
				elem: ^ast.Expr
				#partial switch t in n.type.derived {
				case ^ast.Array_Type:
					elem = t.elem
				case ^ast.Dynamic_Array_Type:
					elem = t.elem
				}
				if elem != nil && names_type(elem, data.name) {
					for value in n.elems {
						if inner, is_lit := value.derived.(^ast.Comp_Lit); is_lit && inner.type == nil {
							data.found ||= is_positional(inner)
						}
					}
				}
			case ^ast.Value_Decl:
				if n.type != nil && names_type(n.type, data.name) {
					for value in n.values {
						if inner, is_lit := value.derived.(^ast.Comp_Lit); is_lit && inner.type == nil {
							data.found ||= is_positional(inner)
						}
					}
				}
			case ^ast.Type_Cast:
				data.found ||= n.tok.kind == .Transmute
			case ^ast.Foreign_Block_Decl:
				if n.body != nil {
					for use in collect_ident_uses(n.body) {
						data.found ||= use.ident.name == data.name
					}
				}
				return nil
			}
			return visitor
		},
	}
	for document in documents {
		for decl in document.ast.decls {
			ast.walk(&visitor, decl)
		}
	}
	return data.found
}

is_positional :: proc(lit: ^ast.Comp_Lit) -> bool {
	for elem in lit.elems {
		if _, is_named := elem.derived.(^ast.Field_Value); !is_named {
			return true
		}
	}
	return false
}

// The text of the fields in the new order and the range it replaces. On one line the fields join with commas. Over
// several lines each field takes its line and the comment lines above it, and every field ends with a comma. ok is
// false for another shape, such as two fields on one line.
reordered_text :: proc(
	src: string,
	type: ^ast.Struct_Type,
	order: []int,
) -> (
	start, end: int,
	text: string,
	ok: bool,
) {
	list := type.fields.list
	open := type.pos.offset + strings.index_byte(src[type.pos.offset:type.end.offset], '{')
	close := type.end.offset - 1
	if open < type.pos.offset || src[close] != '}' {
		return
	}
	ends := make([]int, len(list), context.temp_allocator)
	for field, i in list {
		ends[i] = field.type.end.offset
		if field.tag.text != "" {
			ends[i] = field.tag.pos.offset + len(field.tag.text)
		}
	}
	inner := src[open + 1:close]
	if !strings.contains_rune(inner, '\n') {
		if strings.contains(inner, "//") || strings.contains(inner, "/*") {
			return
		}
		parts := make([]string, len(list), context.temp_allocator)
		for at, i in order {
			parts[i] = src[list[at].pos.offset:ends[at]]
		}
		return list[0].pos.offset, ends[len(list) - 1], strings.join(parts, ", ", context.temp_allocator), true
	}

	// Each chunk runs from the line after the previous one to the end of the line of its field.
	chunks := make([]string, len(list), context.temp_allocator)
	chunk_start := open + 1 + strings.index_byte(src[open + 1:close], '\n') + 1
	if chunk_start <= open + 1 {
		return
	}
	first := chunk_start
	for field, i in list {
		line_start := field.pos.offset
		for line_start > 0 && src[line_start - 1] != '\n' {
			line_start -= 1
		}
		if line_start < chunk_start || strings.trim_space(src[line_start:field.pos.offset]) != "" {
			return
		}
		newline := strings.index_byte(src[ends[i]:close], '\n')
		if newline < 0 {
			return
		}
		line_end := ends[i] + newline + 1
		rest := strings.trim_space(src[ends[i]:line_end])
		has_comma := strings.has_prefix(rest, ",")
		if has_comma {
			rest = strings.trim_space(rest[1:])
		}
		if rest != "" && !strings.has_prefix(rest, "//") {
			return
		}
		chunk := src[chunk_start:line_end]
		if !has_comma {
			at := ends[i] - chunk_start
			chunk = strings.concatenate({chunk[:at], ",", chunk[at:]}, context.temp_allocator)
		}
		// A blank line between fields stays with no field.
		for {
			nl := strings.index_byte(chunk, '\n')
			if nl < 0 || strings.trim_space(chunk[:nl]) != "" {
				break
			}
			chunk = chunk[nl + 1:]
		}
		chunks[i] = chunk
		chunk_start = line_end
	}
	sb := strings.builder_make(context.temp_allocator)
	for at in order {
		strings.write_string(&sb, chunks[at])
	}
	return first, chunk_start, strings.to_string(sb), true
}
