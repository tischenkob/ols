#+private file
package server

import "core:fmt"
import "core:odin/ast"
import "core:strconv"

// Sizes are for a 64-bit target: pointers are 8 bytes and `int`/`uint` follow them.
// ponytail: no ODIN_ARCH switch, add one if 32-bit targets ever matter.
POINTER_SIZE :: 8

LAYOUT_MAX_DEPTH :: 32

// write_hover_content is shared with completion and signature help, where resolving
// every field of every struct in a list would be wasted work.
@(private = "package")
hover_layout_scope: bool

@(private = "package")
struct_layout_hover :: proc(ast_context: ^AstContext, symbol: Symbol) -> string {
	if !hover_layout_scope || !layout_enabled() || symbol.pointers > 0 {
		return ""
	}

	v, is_struct := symbol.value.(SymbolStructValue)
	if !is_struct {
		return ""
	}

	size, align, ok := struct_layout(ast_context, v, 0)
	if !ok {
		return ""
	}

	return fmt.tprintf("size: %d bytes, align: %d", size, align)
}

@(private = "package")
struct_field_layout_hover :: proc(ast_context: ^AstContext, v: SymbolStructValue, index: int) -> string {
	if !layout_enabled() || index >= len(v.types) {
		return ""
	}

	offsets := make([]int, len(v.types), context.temp_allocator)
	if _, _, ok := struct_layout(ast_context, v, 0, offsets); !ok {
		return ""
	}

	size, _, ok := type_layout(ast_context, v.types[index], 0)
	if !ok {
		return ""
	}

	return fmt.tprintf("offset: %d, size: %d", offsets[index], size)
}

layout_enabled :: proc() -> bool {
	config := indexer.index.collection.config
	return config != nil && config.enable_hover_struct_size
}

layout_align_up :: proc(n, align: int) -> int {
	if align <= 1 {
		return n
	}
	return (n + align - 1) / align * align
}

type_layout :: proc(ast_context: ^AstContext, expr: ^ast.Expr, depth: int) -> (size, align: int, ok: bool) {
	if expr == nil || depth > LAYOUT_MAX_DEPTH {
		return
	}
	symbol := resolve_type_expression(ast_context, expr) or_return
	return symbol_layout(ast_context, symbol, depth + 1)
}

symbol_layout :: proc(ast_context: ^AstContext, symbol: Symbol, depth: int) -> (size, align: int, ok: bool) {
	if depth > LAYOUT_MAX_DEPTH {
		return
	}
	if symbol.pointers > 0 {
		return POINTER_SIZE, POINTER_SIZE, true
	}

	set_ast_package_set_scoped(ast_context, symbol.pkg)

	#partial switch v in symbol.value {
	case SymbolBasicValue:
		if v.ident == nil {
			return
		}
		return basic_layout(v.ident.name)
	case SymbolSliceValue:
		return 2 * POINTER_SIZE, POINTER_SIZE, true
	case SymbolDynamicArrayValue:
		// base.runtime.Raw_Dynamic_Array: data, len, cap, allocator
		return 5 * POINTER_SIZE, POINTER_SIZE, true
	case SymbolMapValue:
		// base.runtime.Raw_Map: data, len, allocator
		return 4 * POINTER_SIZE, POINTER_SIZE, true
	case SymbolMultiPointerValue, SymbolProcedureValue:
		return POINTER_SIZE, POINTER_SIZE, true
	case SymbolBitFieldValue:
		return type_layout(ast_context, v.backing_type, depth + 1)
	case SymbolEnumValue:
		if v.base_type == nil {
			return POINTER_SIZE, POINTER_SIZE, true
		}
		return type_layout(ast_context, v.base_type, depth + 1)
	case SymbolFixedArrayValue:
		size, align = type_layout(ast_context, v.expr, depth + 1) or_return
		length := array_length(ast_context, v.len, depth) or_return
		return size * length, align, true
	case SymbolMatrixValue:
		size, align = type_layout(ast_context, v.expr, depth + 1) or_return
		rows := const_int(ast_context, v.x) or_return
		columns := const_int(ast_context, v.y) or_return
		return size * rows * columns, align, true
	case SymbolBitSetValue:
		return bit_set_layout(ast_context, v, depth)
	case SymbolStructValue:
		return struct_layout(ast_context, v, depth)
	case SymbolUnionValue:
		return union_layout(ast_context, v, depth)
	}

	return
}

basic_layout :: proc(name: string) -> (size, align: int, ok: bool) {
	switch name {
	case "bool", "b8", "u8", "i8", "byte":
		return 1, 1, true
	case "b16", "u16", "i16", "f16":
		return 2, 2, true
	case "b32", "u32", "i32", "f32", "rune":
		return 4, 4, true
	case "complex32":
		return 4, 2, true
	case "int", "uint", "uintptr", "b64", "u64", "i64", "f64", "rawptr", "typeid", "cstring":
		return 8, 8, true
	case "complex64":
		return 8, 4, true
	case "quaternion64":
		return 8, 2, true
	case "i128", "u128":
		return 16, 16, true
	case "complex128":
		return 16, 8, true
	case "quaternion128":
		return 16, 4, true
	case "quaternion256":
		return 32, 8, true
	case "string", "any":
		return 2 * POINTER_SIZE, POINTER_SIZE, true
	}
	return
}

// The length of `[N]T`, or of `[Enum]T` where the index is an enum.
array_length :: proc(ast_context: ^AstContext, expr: ^ast.Expr, depth: int) -> (length: int, ok: bool) {
	if length, ok = const_int(ast_context, expr); ok {
		return
	}
	symbol := resolve_type_expression(ast_context, expr) or_return
	enum_value := symbol.value.(SymbolEnumValue) or_return
	low, high := enum_range(ast_context, enum_value) or_return
	return high - low + 1, true
}

// The lowest and highest values of an enum, only when every value is a constant.
enum_range :: proc(ast_context: ^AstContext, v: SymbolEnumValue) -> (low, high: int, ok: bool) {
	if len(v.names) == 0 {
		return
	}

	next := 0
	for i in 0 ..< len(v.names) {
		if i < len(v.values) && v.values[i] != nil {
			next = const_int(ast_context, v.values[i]) or_return
		}
		if i == 0 {
			low, high = next, next
		}
		low = min(low, next)
		high = max(high, next)
		next += 1
	}

	return low, high, true
}

bit_set_layout :: proc(ast_context: ^AstContext, v: SymbolBitSetValue, depth: int) -> (size, align: int, ok: bool) {
	if v.underlying != nil {
		return type_layout(ast_context, v.underlying, depth + 1)
	}
	if v.expr == nil {
		return
	}

	bits: int
	if range, is_binary := v.expr.derived.(^ast.Binary_Expr);
	   is_binary && (range.op.kind == .Range_Half || range.op.kind == .Range_Full) {
		low := const_int(ast_context, range.left) or_return
		high := const_int(ast_context, range.right) or_return
		if range.op.kind == .Range_Half {
			high -= 1
		}
		bits = high - low + 1
	} else {
		symbol := resolve_type_expression(ast_context, v.expr) or_return
		enum_value := symbol.value.(SymbolEnumValue) or_return
		low, high := enum_range(ast_context, enum_value) or_return
		bits = high - low + 1
	}

	switch {
	case bits <= 8:
		return 1, 1, true
	case bits <= 16:
		return 2, 2, true
	case bits <= 32:
		return 4, 4, true
	case bits <= 64:
		return 8, 8, true
	case bits <= 128:
		return 16, 16, true
	}
	return
}

// Fills `offsets` with each field's byte offset when it is non-nil.
struct_layout :: proc(
	ast_context: ^AstContext,
	v: SymbolStructValue,
	depth: int,
	offsets: []int = nil,
) -> (
	size, align: int,
	ok: bool,
) {
	if depth > LAYOUT_MAX_DEPTH || v.poly != nil || v.min_field_align != nil || v.max_field_align != nil {
		return
	}

	packed := .Is_Packed in v.tags
	raw_union := .Is_Raw_Union in v.tags
	align = 1

	for type, i in v.types {
		field_size, field_align := type_layout(ast_context, type, depth + 1) or_return
		if packed {
			field_align = 1
		}

		if raw_union {
			size = max(size, field_size)
			if i < len(offsets) {
				offsets[i] = 0
			}
		} else {
			size = layout_align_up(size, field_align)
			if i < len(offsets) {
				offsets[i] = size
			}
			size += field_size
		}
		align = max(align, field_align)
	}

	if v.align != nil {
		align = const_int(ast_context, v.align) or_return
	}

	return layout_align_up(size, align), align, true
}

union_layout :: proc(ast_context: ^AstContext, v: SymbolUnionValue, depth: int) -> (size, align: int, ok: bool) {
	if depth > LAYOUT_MAX_DEPTH || v.poly != nil || v.kind == .maybe || len(v.types) == 0 {
		return
	}

	align = 1
	for type in v.types {
		variant_size, variant_align := type_layout(ast_context, type, depth + 1) or_return
		size = max(size, variant_size)
		align = max(align, variant_align)
	}

	if v.align != nil {
		align = const_int(ast_context, v.align) or_return
	}

	// The tag is the smallest integer holding every variant, plus nil unless #no_nil.
	tags := len(v.types) + (v.kind == .no_nil ? 0 : 1)
	tag_size := tags <= 0xff ? 1 : tags <= 0xffff ? 2 : 4

	return layout_align_up(size + tag_size, align), align, true
}

const_int :: proc(ast_context: ^AstContext, expr: ^ast.Expr) -> (value: int, ok: bool) {
	if expr == nil {
		return
	}

	#partial switch v in expr.derived {
	case ^ast.Basic_Lit:
		return strconv.parse_int(v.tok.text, 0)
	case ^ast.Paren_Expr:
		return const_int(ast_context, v.expr)
	case ^ast.Unary_Expr:
		value = const_int(ast_context, v.expr) or_return
		#partial switch v.op.kind {
		case .Sub:
			return -value, true
		case .Add:
			return value, true
		}
	case ^ast.Binary_Expr:
		left := const_int(ast_context, v.left) or_return
		right := const_int(ast_context, v.right) or_return
		#partial switch v.op.kind {
		case .Add:
			return left + right, true
		case .Sub:
			return left - right, true
		case .Mul:
			return left * right, true
		case .Quo:
			if right == 0 {
				return
			}
			return left / right, true
		}
	case ^ast.Ident, ^ast.Selector_Expr:
		symbol := resolve_type_expression(ast_context, expr) or_return
		untyped := symbol.value.(SymbolUntypedValue) or_return
		if untyped.type != .Integer {
			return
		}
		return strconv.parse_int(untyped.tok.text, 0)
	}

	return
}
