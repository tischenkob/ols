#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:strings"

Cast_Kind :: enum {
	Cast,
	Call,
	Auto,
	Transmute,
}

Cast_Form :: struct {
	kind:      Cast_Kind,
	node:      ^ast.Node,
	parent:    ^ast.Node,
	type:      ^ast.Expr, // nil for auto_cast
	type_text: string,
	operand:   ^ast.Expr,
}

// `cast(T)x`, `T(x)`, `auto_cast x` and `transmute(T)x` for the innermost of them around the cursor.
@(private = "package")
add_cast_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_cast {
		return
	}
	nodes := nodes_at(ctx.document.ast.decls[:], ctx.range.start)
	#reverse for at in nodes {
		if _, is_proc := at.node.derived.(^ast.Proc_Lit); is_proc {
			return
		}
		if ctx.range.end > at.node.end.offset {
			continue
		}
		form := form_of(ctx, at) or_continue
		switch form.kind {
		case .Cast:
			replace_form(ctx, form, "Convert to T(x)", call_form(ctx, form))
			add_auto_form(ctx, nodes, form)
			add_transmute_form(ctx, form)
		case .Call:
			add_cast_form(ctx, form)
			add_auto_form(ctx, nodes, form)
			add_transmute_form(ctx, form)
		case .Auto:
			add_from_auto(ctx, nodes, form)
		case .Transmute:
			if pointers_only(ctx, form) {
				add_cast_form(ctx, form)
			}
		}
		return
	}
}

form_of :: proc(ctx: ^ActionContext, at: Node_At) -> (form: Cast_Form, ok: bool) {
	src := ctx.document.ast.src
	form.node = at.node
	form.parent = at.parent
	#partial switch n in at.node.derived {
	case ^ast.Type_Cast:
		form.kind = n.tok.kind == .Transmute ? .Transmute : .Cast
		form.type = n.type
		form.type_text = strings.trim_space(src[n.open.offset + 1:n.close.offset])
		form.operand = n.expr
		return form, true
	case ^ast.Auto_Cast:
		form.kind = .Auto
		form.operand = n.expr
		return form, true
	case ^ast.Call_Expr:
		if len(n.args) != 1 || n.inlining != .None || n.ellipsis.kind != .Invalid {
			return
		}
		if _, named := n.args[0].derived.(^ast.Field_Value); named {
			return
		}
		form.kind = .Call
		form.type = strip_parens(n.expr)
		form.type_text = node_text(src, form.type)
		form.operand = n.args[0]
		return form, names_conversion_type(ctx, n.expr)
	}
	return
}

strip_parens :: proc(expr: ^ast.Expr) -> ^ast.Expr {
	expr := expr
	for {
		paren := expr.derived.(^ast.Paren_Expr) or_break
		expr = paren.expr
	}
	return expr
}

// Whether the callee of a one-argument call is a type: a written type or a name that declares one. A parametric type
// takes a type as its argument, which is no conversion.
names_conversion_type :: proc(ctx: ^ActionContext, callee: ^ast.Expr) -> bool {
	callee := strip_parens(callee)
	#partial switch _ in callee.derived {
	case ^ast.Pointer_Type,
	     ^ast.Multi_Pointer_Type,
	     ^ast.Proc_Type,
	     ^ast.Array_Type,
	     ^ast.Dynamic_Array_Type,
	     ^ast.Map_Type,
	     ^ast.Matrix_Type,
	     ^ast.Bit_Set_Type:
		return true
	case ^ast.Ident, ^ast.Selector_Expr:
	case:
		return false
	}
	reset_ast_context(ctx.ast_context)
	symbol, ok := resolve_type_expression(ctx.ast_context, callee)
	if !ok {
		return false
	}
	#partial switch v in symbol.value {
	case SymbolStructValue:
		if v.poly != nil || len(v.poly_names) > 0 {
			return false
		}
	case SymbolUnionValue:
		if v.poly != nil || len(v.poly_names) > 0 {
			return false
		}
	}
	return declares_type(ctx, position_ident(callee, ""), symbol)
}

replace_form :: proc(ctx: ^ActionContext, form: Cast_Form, title, text: string) {
	append_replace_range(ctx, form.node.pos.offset, form.node.end.offset, title, text)
}

// A type other than a name needs parentheses to take a call: `^T(x)` converts to T and points, and `[]u8(s)` is ambiguous.
call_form :: proc(ctx: ^ActionContext, form: Cast_Form) -> string {
	src := ctx.document.ast.src
	operand := node_text(src, strip_parens(form.operand))
	#partial switch _ in form.type.derived {
	case ^ast.Ident, ^ast.Selector_Expr, ^ast.Call_Expr:
		return fmt.tprintf("%s(%s)", form.type_text, operand)
	}
	return fmt.tprintf("(%s)(%s)", form.type_text, operand)
}

// The text of the operand after a unary `cast(T)`, `auto_cast` or `transmute(T)`.
unary_operand :: proc(ctx: ^ActionContext, form: Cast_Form) -> string {
	text := node_text(ctx.document.ast.src, form.operand)
	if form.kind != .Call {
		return text
	}
	#partial switch _ in form.operand.derived {
	case ^ast.Ident,
	     ^ast.Basic_Lit,
	     ^ast.Call_Expr,
	     ^ast.Selector_Expr,
	     ^ast.Selector_Call_Expr,
	     ^ast.Index_Expr,
	     ^ast.Slice_Expr,
	     ^ast.Deref_Expr,
	     ^ast.Paren_Expr,
	     ^ast.Unary_Expr,
	     ^ast.Type_Cast,
	     ^ast.Auto_Cast:
		return text
	}
	return fmt.tprintf("(%s)", text)
}

// A unary form binds looser than a postfix operator, so `T(x).y` needs `(cast(T)x).y`.
unary_form :: proc(form: Cast_Form, text: string) -> string {
	if form.kind != .Call || form.parent == nil {
		return text
	}
	inner: ^ast.Expr
	#partial switch p in form.parent.derived {
	case ^ast.Selector_Expr:
		inner = p.expr
	case ^ast.Selector_Call_Expr:
		inner = p.expr
	case ^ast.Index_Expr:
		inner = p.expr
	case ^ast.Slice_Expr:
		inner = p.expr
	case ^ast.Deref_Expr:
		inner = p.expr
	case ^ast.Call_Expr:
		inner = p.expr
	case ^ast.Type_Assertion:
		inner = p.expr
	}
	if inner == form.node {
		return fmt.tprintf("(%s)", text)
	}
	return text
}

add_cast_form :: proc(ctx: ^ActionContext, form: Cast_Form) {
	text := fmt.tprintf("cast(%s)%s", form.type_text, unary_operand(ctx, form))
	replace_form(ctx, form, "Convert to cast(T)x", unary_form(form, text))
}

add_auto_form :: proc(ctx: ^ActionContext, nodes: []Node_At, form: Cast_Form) {
	expected, ok := expected_of(ctx, nodes, form.node)
	if !ok {
		return
	}
	written, known := type_at(ctx, form.type, ctx.ast_context.document_package)
	if !known || !same_type_written(ctx, written, expected) {
		return
	}
	replace_form(ctx, form, "Convert to auto_cast", fmt.tprintf("auto_cast %s", unary_operand(ctx, form)))
}

add_transmute_form :: proc(ctx: ^ActionContext, form: Cast_Form) {
	if !pointers_only(ctx, form) {
		return
	}
	text := fmt.tprintf("transmute(%s)%s", form.type_text, unary_operand(ctx, form))
	replace_form(ctx, form, "Convert to transmute", unary_form(form, text))
}

add_from_auto :: proc(ctx: ^ActionContext, nodes: []Node_At, form: Cast_Form) {
	expected, ok := expected_of(ctx, nodes, form.node)
	if !ok {
		return
	}
	edits := make([dynamic]TextEdit, context.temp_allocator)
	at := position_ident(form.node, "")
	text, printed := "", false
	if basic, is_basic := expected.symbol.value.(SymbolBasicValue);
	   is_basic && expected.type == nil && expected.symbol.pointers == 0 && basic.ident != nil {
		text, printed = basic.ident.name, true
	} else {
		text, printed = expected_text(ctx, at, expected, &edits)
	}
	if !printed || writes_new_type(text) || (len(edits) == 0 && !name_holds(ctx, at, text)) {
		return
	}
	replacement := fmt.tprintf("cast(%s)%s", text, node_text(ctx.document.ast.src, form.operand))
	append(&edits, TextEdit{range = range_of(ctx, form.node.pos.offset, form.node.end.offset), newText = replacement})
	append(ctx.actions, make_code_action(ctx, "Convert to cast(T)x", "refactor.rewrite", edits[:]))
}

// An inline struct or union written again is a new type, which the place would not accept.
writes_new_type :: proc(text: string) -> bool {
	return strings.has_prefix(text, "struct") || strings.has_prefix(text, "union")
}

pointers_only :: proc(ctx: ^ActionContext, form: Cast_Form) -> bool {
	return is_pointer(ctx, form.type) && is_pointer(ctx, form.operand)
}

is_pointer :: proc(ctx: ^ActionContext, expr: ^ast.Expr) -> bool {
	reset_ast_context(ctx.ast_context)
	symbol, ok := resolve_type_expression(ctx.ast_context, expr)
	if !ok {
		return false
	}
	if symbol.pointers > 0 {
		return true
	}
	#partial switch v in symbol.value {
	case SymbolMultiPointerValue:
		return true
	case SymbolBasicValue:
		return v.ident != nil && v.ident.name == "rawptr"
	}
	return false
}
