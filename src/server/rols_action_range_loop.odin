#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:strconv"
import "core:strings"

Iterable :: enum {
	Unknown,
	Array,
	Slice,
	Dynamic,
	String,
	Bit_Set,
	Map,
	Range,
	Enum,
}

// Edits the header of the range loop at the cursor: an index, by reference or by value, `#reverse`, and the form
// of an integer range.
@(private = "package")
add_range_loop_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_range_loop {
		return
	}

	function := ctx.position_context.function
	if function == nil || function.body == nil {
		return
	}

	loop := loop_with_header_at(ctx, function.body)
	if loop == nil || loop.init != nil || len(loop.vals) == 0 {
		return
	}

	gather_locals_at(ctx, loop.pos.offset)
	defer restore_locals(ctx)

	iterable := iterable_kind(ctx, loop.expr)
	add_index(ctx, loop, iterable)
	switch_binding(ctx, loop, iterable)
	toggle_reverse(ctx, loop, iterable)
	convert_range(ctx, loop)
}

// The innermost range loop whose header, from a label or `#reverse` up to the body, holds the range.
loop_with_header_at :: proc(ctx: ^ActionContext, root: ^ast.Stmt) -> ^ast.Range_Stmt {
	Data :: struct {
		src:        string,
		start, end: int,
		found:      ^ast.Range_Stmt,
	}
	data := Data {
		src   = ctx.document.ast.src,
		start = ctx.range.start,
		end   = ctx.range.end,
	}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil {
				return nil
			}
			if loop, is_loop := node.derived.(^ast.Range_Stmt); is_loop && loop.body != nil {
				header := loop.pos.offset
				if loop.label != nil {
					header = min(header, loop.label.pos.offset)
				}
				if at, _ := reverse_directive(data.src, loop); at >= 0 {
					header = min(header, at)
				}
				if header <= data.start && data.end <= loop.body.pos.offset && data.start < loop.body.pos.offset {
					data.found = loop
				}
			}
			return visitor
		},
	}
	ast.walk(&visitor, root)
	return data.found
}

// Where `#reverse` of the loop starts, and where the code after it starts. -1 when the loop has none in reach, such
// as behind a comment.
reverse_directive :: proc(src: string, loop: ^ast.Range_Stmt) -> (start, end: int) {
	if !loop.reverse {
		return -1, -1
	}
	// `#reverse name: for` and `name: #reverse for` both compile.
	ends := [2]int{loop.for_pos.offset, loop.label != nil ? loop.label.pos.offset : loop.for_pos.offset}
	for after in ends {
		before := strings.trim_right_space(src[:after])
		if strings.has_suffix(before, "#reverse") {
			return len(before) - len("#reverse"), after
		}
	}
	return -1, -1
}

iterable_kind :: proc(ctx: ^ActionContext, expr: ^ast.Expr) -> Iterable {
	expr := unparen(expr)
	if binary, is_binary := expr.derived.(^ast.Binary_Expr); is_binary {
		#partial switch binary.op.kind {
		case .Range_Half, .Range_Full, .Ellipsis:
			return .Range
		}
		return .Unknown
	}

	ctx.ast_context.use_locals = true
	symbol, ok := resolve_type_expression(ctx.ast_context, expr)
	if !ok {
		return .Unknown
	}
	// A call resolves to the procedure. Only a single result can be anything but an iterator.
	if callee, is_proc := symbol.value.(SymbolProcedureValue); is_proc {
		_, is_call := expr.derived.(^ast.Call_Expr)
		if !is_call || callee.generic || len(callee.return_types) != 1 || len(callee.return_types[0].names) > 1 {
			return .Unknown
		}
		result := callee.return_types[0].type
		if result == nil {
			return .Unknown
		}
		set_ast_package_set_scoped(ctx.ast_context, symbol.pkg)
		symbol, ok = resolve_type_expression(ctx.ast_context, result)
		if !ok {
			return .Unknown
		}
	}

	if symbol.pointers > 1 {
		return .Unknown
	}
	#partial switch v in symbol.value {
	case SymbolFixedArrayValue:
		return .Array
	case SymbolSliceValue:
		return .Slice
	case SymbolDynamicArrayValue:
		return .Dynamic
	case SymbolMapValue:
		return .Map
	case SymbolBitSetValue:
		return symbol.pointers == 0 ? .Bit_Set : .Unknown
	case SymbolEnumValue:
		return symbol.pointers == 0 ? .Enum : .Unknown
	case SymbolBasicValue:
		if symbol.pointers == 0 && v.ident != nil && v.ident.name == "string" {
			return .String
		}
	case SymbolUntypedValue:
		if symbol.pointers == 0 && v.type == .String {
			return .String
		}
	}
	return .Unknown
}

add_index :: proc(ctx: ^ActionContext, loop: ^ast.Range_Stmt, iterable: Iterable) {
	#partial switch iterable {
	case .Array, .Slice, .Dynamic, .String, .Range, .Enum:
	case:
		return
	}
	if len(loop.vals) != 1 {
		return
	}
	if name := blank_loop_counter(ctx, loop); name != "" {
		append_insert(ctx, loop.vals[0].end.offset, "Add index", "refactor.rewrite", fmt.tprintf(", %s", name))
	}
}

// `for x in xs` to `for &x in xs` and back. The first form copies the element, so a body that reaches the iterable by
// name could tell the two forms apart.
switch_binding :: proc(ctx: ^ActionContext, loop: ^ast.Range_Stmt, iterable: Iterable) {
	if names_iterable(ctx, loop) {
		return
	}
	value := loop.vals[0]
	if unary, is_unary := value.derived.(^ast.Unary_Expr); is_unary {
		name, is_name := unary.expr.derived.(^ast.Ident)
		if !is_name || unary.op.kind != .And || needs_address(loop.body, name.name) {
			return
		}
		append_replace_range(ctx, unary.pos.offset, name.pos.offset, "Iterate by value", "")
		return
	}
	name, is_name := value.derived.(^ast.Ident)
	if is_name && name.name != "_" && elements_addressable(ctx, loop.expr, iterable) {
		append_insert(ctx, value.pos.offset, "Iterate by reference", "refactor.rewrite", "&")
	}
}

// A slice or a dynamic array holds its elements elsewhere, so any such value will do, a constant slice too. A fixed
// array must be a variable or sit behind a pointer.
elements_addressable :: proc(ctx: ^ActionContext, expr: ^ast.Expr, iterable: Iterable) -> bool {
	#partial switch iterable {
	case .Slice, .Dynamic:
		return true
	case .Array:
		ctx.ast_context.use_locals = true
		symbol, ok := resolve_type_expression(ctx.ast_context, expr)
		if !ok {
			return false
		}
		if symbol.pointers > 0 {
			return true
		}
		pc := Postfix_Context {
			ast_context      = ctx.ast_context,
			position_context = ctx.position_context,
		}
		return addressing(&pc, expr) == .Variable
	}
	return false
}

// Whether the body mentions a variable that the iterable reads, such as the slice itself or an argument it came from.
names_iterable :: proc(ctx: ^ActionContext, loop: ^ast.Range_Stmt) -> bool {
	typed := resolve_entire_file(ctx.document)
	body := collect_ident_uses(loop.body)
	for read in collect_ident_uses(loop.expr) {
		if is_member_name(read) || !is_variable(typed, read.ident) {
			continue
		}
		for use in body {
			if use.ident.name == read.ident.name && !is_member_name(use) {
				return true
			}
		}
	}
	return false
}

// Whether the body writes through the value, takes its address, slices it or calls a method on it, which a copy
// without an address cannot do. An inner variable of the same name counts too.
needs_address :: proc(body: ^ast.Stmt, name: string) -> bool {
	for use in collect_ident_uses(body) {
		if use.ident.name != name || is_member_name(use) {
			continue
		}
		if is_write(use) || aliases(use) || reaches_method(use) {
			return true
		}
	}
	return false
}

// `x->f()` and `x.y->f()` pass the address of what precedes the arrow.
reaches_method :: proc(use: IdentUse) -> bool {
	#reverse for parent in use.parents {
		#partial switch p in parent.derived {
		case ^ast.Selector_Expr:
			if p.op.kind == .Arrow_Right {
				return true
			}
		case ^ast.Index_Expr, ^ast.Paren_Expr:
		case:
			return false
		}
	}
	return false
}

// `odin check` rejects `#reverse` on a map, a range, an enum type and an iterator call.
toggle_reverse :: proc(ctx: ^ActionContext, loop: ^ast.Range_Stmt, iterable: Iterable) {
	TITLE :: "Toggle #reverse"
	if loop.reverse {
		start, end := reverse_directive(ctx.document.ast.src, loop)
		if start >= 0 {
			append_replace_range(ctx, start, end, TITLE, "")
		}
		return
	}
	#partial switch iterable {
	case .Array, .Slice, .Dynamic, .String, .Bit_Set:
		append_insert(ctx, loop.for_pos.offset, TITLE, "refactor.rewrite", "#reverse ")
	}
}

// `a..<10` and `a..=9`. The end must be a plain decimal literal, so the new text is a literal too.
convert_range :: proc(ctx: ^ActionContext, loop: ^ast.Range_Stmt) {
	bounds, is_binary := unparen(loop.expr).derived.(^ast.Binary_Expr)
	if !is_binary {
		return
	}
	literal, is_literal := bounds.right.derived.(^ast.Basic_Lit)
	if !is_literal || literal.tok.kind != .Integer {
		return
	}
	for c in literal.tok.text {
		if c < '0' || c > '9' {
			return
		}
	}
	value, parsed := strconv.parse_i64_of_base(literal.tok.text, 10)
	if !parsed {
		return
	}

	title, operator: string
	#partial switch bounds.op.kind {
	case .Range_Half:
		// `0..=-1` has no literal end, and `a..<0` is never a useful range.
		if value == 0 {
			return
		}
		title, operator = "Convert to ..= range", "..="
		value -= 1
	case .Range_Full:
		title, operator = "Convert to ..< range", "..<"
		value += 1
	case:
		return
	}
	if !integer_start_holds(ctx, bounds.left, value) {
		return
	}

	src := ctx.document.ast.src
	operator_end := bounds.op.pos.offset + len(operator)
	append_replace_range(
		ctx,
		bounds.op.pos.offset,
		literal.end.offset,
		title,
		fmt.tprintf("%s%s%d", operator, src[operator_end:literal.pos.offset], value),
	)
}

// Whether the range counts whole numbers from start, and its type holds the new end. `0.5..<3` counts through 2.5, and
// `lo..=255` over a u8 has no form with 256.
integer_start_holds :: proc(ctx: ^ActionContext, start: ^ast.Expr, end: i64) -> bool {
	start := unparen(start)
	if unary, is_unary := start.derived.(^ast.Unary_Expr); is_unary && unary.op.kind == .Sub {
		start = unparen(unary.expr)
	}
	if literal, is_literal := start.derived.(^ast.Basic_Lit); is_literal {
		return literal.tok.kind == .Integer || literal.tok.kind == .Rune
	}
	ctx.ast_context.use_locals = true
	symbol, ok := resolve_type_expression(ctx.ast_context, start)
	if !ok || symbol.pointers > 0 {
		return false
	}
	#partial switch v in symbol.value {
	case SymbolUntypedValue:
		return v.type == .Integer
	case SymbolBasicValue:
		if v.ident == nil {
			return false
		}
		switch v.ident.name {
		case "int", "uint", "uintptr", "i64", "u64", "i128", "u128":
			return true
		case "i32", "u32", "rune":
			return end <= 1 << 31 - 1
		case "u16":
			return end <= 1 << 16 - 1
		case "i16":
			return end <= 1 << 15 - 1
		case "u8", "byte":
			return end <= 1 << 8 - 1
		case "i8":
			return end <= 1 << 7 - 1
		}
	}
	return false
}
