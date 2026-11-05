#+private file

package server

import "core:odin/ast"
import "core:slice"
import "core:strings"

// `.A` and `Enum.A`, `Foo{}` and `{}`, where the place of the expression supplies the type.
@(private = "package")
add_qualify_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_qualify {
		return
	}
	nodes := nodes_at(ctx.document.ast.decls[:], ctx.range.start)
	add_enum_form(ctx, nodes)
	add_literal_type_form(ctx, nodes)
}

// The type a place expects. type is nil when the place only has a value, such as the left side of an assignment.
@(private = "package")
Expected :: struct {
	symbol: Symbol,
	type:   ^ast.Expr,
	pkg:    string,
}

add_enum_form :: proc(ctx: ^ActionContext, nodes: []Node_At) {
	#reverse for at in nodes {
		#partial switch n in at.node.derived {
		case ^ast.Proc_Lit, ^ast.Comp_Lit, ^ast.Call_Expr:
			return
		case ^ast.Implicit_Selector_Expr:
			add_qualify_member(ctx, n)
			return
		case ^ast.Selector_Expr:
			if add_drop_enum_type(ctx, nodes, n) {
				return
			}
		}
	}
}

add_qualify_member :: proc(ctx: ^ActionContext, selector: ^ast.Implicit_Selector_Expr) {
	reset_ast_context(ctx.ast_context)
	symbol, ok := resolve_implicit_selector(ctx.ast_context, ctx.position_context)
	if !ok || selector.field == nil {
		return
	}
	// An element of a bit set literal resolves to the set.
	if set, is_set := symbol.value.(SymbolBitSetValue); is_set {
		element, element_ok := type_at(ctx, set.expr, symbol.pkg)
		if !element_ok {
			return
		}
		symbol = element.symbol
	}
	value, is_enum := symbol.value.(SymbolEnumValue)
	if !is_enum || !slice.contains(value.names, selector.field.name) || .Anonymous in symbol.flags {
		return
	}
	if symbol.pkg != ctx.ast_context.document_package && symbol.flags & {.PrivateFile, .PrivatePackage} != {} {
		return
	}
	at := position_ident(selector, symbol.name)
	if !declares_type(ctx, at, symbol) {
		return
	}
	edits := make([dynamic]TextEdit, context.temp_allocator)
	// A name without a file counts as a name of symbol.pkg, not of this document.
	name := new_clone(at^, context.temp_allocator)
	name.pos.file = ""
	text, printed := requalified_type_text(ctx, name, symbol.pkg, &edits)
	if !printed || (len(edits) == 0 && !name_holds(ctx, at, text)) {
		return
	}
	offset := selector.pos.offset
	append(&edits, TextEdit{range = range_of(ctx, offset, offset), newText = text})
	append(ctx.actions, make_code_action(ctx, "Qualify enum member", "refactor.rewrite", edits[:]))
}

add_drop_enum_type :: proc(ctx: ^ActionContext, nodes: []Node_At, selector: ^ast.Selector_Expr) -> bool {
	if selector.op.kind != .Period || selector.field == nil {
		return false
	}
	#partial switch _ in selector.expr.derived {
	case ^ast.Ident, ^ast.Selector_Expr:
	case:
		return false
	}
	reset_ast_context(ctx.ast_context)
	symbol, ok := resolve_type_expression(ctx.ast_context, selector.expr)
	if !ok || symbol.flags & {.Mutable, .Parameter, .Local} != {} {
		return false
	}
	value, is_enum := symbol.value.(SymbolEnumValue)
	if !is_enum || !slice.contains(value.names, selector.field.name) {
		return false
	}
	if expects_enum(ctx, nodes, selector, symbol) {
		append_replace_range(ctx, selector.pos.offset, selector.field.pos.offset, "Drop enum type", ".")
	}
	return true
}

// Whether the place of selector gives `.A` the enum: the places of expected_of, an operand of a comparison with a value
// of that enum, and a case of a switch over one.
expects_enum :: proc(
	ctx: ^ActionContext,
	nodes: []Node_At,
	selector: ^ast.Selector_Expr,
	enum_symbol: Symbol,
) -> bool {
	parent := parent_of_node(nodes, selector)
	if parent == nil {
		return false
	}
	other: ^ast.Expr
	#partial switch p in parent.derived {
	case ^ast.Binary_Expr:
		#partial switch p.op.kind {
		case .Cmp_Eq, .Not_Eq, .Lt, .Gt, .Lt_Eq, .Gt_Eq:
			other = p.left == selector ? p.right : p.left
		case:
			return false
		}
		if _, implicit := other.derived.(^ast.Implicit_Selector_Expr); implicit {
			return false
		}
	case ^ast.Case_Clause:
		#reverse for at in nodes {
			if s, is_switch := at.node.derived.(^ast.Switch_Stmt); is_switch {
				other = s.cond
				break
			}
		}
		if other == nil {
			return false
		}
	}
	if other != nil {
		reset_ast_context(ctx.ast_context)
		symbol, ok := resolve_type_expression(ctx.ast_context, other)
		return ok && same_named(symbol, enum_symbol)
	}
	expected, ok := expected_of(ctx, nodes, selector)
	return ok && same_named(expected.symbol, enum_symbol)
}

add_literal_type_form :: proc(ctx: ^ActionContext, nodes: []Node_At) {
	lit: ^ast.Comp_Lit
	#reverse for at in nodes {
		if _, is_proc := at.node.derived.(^ast.Proc_Lit); is_proc {
			return
		}
		if l, is_lit := at.node.derived.(^ast.Comp_Lit); is_lit {
			lit = l
			break
		}
	}
	if lit == nil {
		return
	}
	expected, ok := expected_of(ctx, nodes, lit)
	if !ok {
		return
	}
	if lit.type != nil {
		written, known := type_at(ctx, lit.type, ctx.ast_context.document_package)
		if known && same_type_written(ctx, written, expected) {
			append_replace_range(ctx, lit.pos.offset, lit.open.offset, "Drop literal type", "")
		}
		return
	}
	// A typed literal does not parse in the header of a statement.
	if in_header(nodes, lit) {
		return
	}
	edits := make([dynamic]TextEdit, context.temp_allocator)
	at := position_ident(lit, "")
	text, printed := expected_text(ctx, at, expected, &edits)
	if !printed || !takes_literal(text) || (len(edits) == 0 && !name_holds(ctx, at, text)) {
		return
	}
	offset := lit.pos.offset
	append(&edits, TextEdit{range = range_of(ctx, offset, offset), newText = text})
	append(ctx.actions, make_code_action(ctx, "Add literal type", "refactor.rewrite", edits[:]))
}

// The type that the place of node supplies: a typed declaration, a plain assignment, a return, a parameter, a field, or
// an element of an array or a bit set. A place that is not listed, such as `x := Foo{}`, supplies none.
@(private = "package")
expected_of :: proc(ctx: ^ActionContext, nodes: []Node_At, node: ^ast.Node) -> (expected: Expected, ok: bool) {
	parent := parent_of_node(nodes, node)
	if parent == nil {
		return
	}
	#partial switch p in parent.derived {
	case ^ast.Value_Decl:
		if p.type == nil || len(p.names) != len(p.values) || !contains_node(p.values, node) {
			return
		}
		return type_at(ctx, p.type, ctx.ast_context.document_package)
	case ^ast.Assign_Stmt:
		if p.op.kind != .Eq || len(p.lhs) != len(p.rhs) {
			return
		}
		for value, i in p.rhs {
			if value == node {
				reset_ast_context(ctx.ast_context)
				symbol := resolve_type_expression(ctx.ast_context, p.lhs[i]) or_return
				return {symbol = symbol}, true
			}
		}
	case ^ast.Return_Stmt:
		return expected_result(ctx, nodes, p, node)
	case ^ast.Call_Expr:
		for arg, i in p.args {
			if arg == node {
				return expected_param(ctx, p, i)
			}
		}
	case ^ast.Field_Value:
		if p.value != node {
			return
		}
		above := parent_of_node(nodes, parent)
		if above == nil {
			return
		}
		#partial switch owner in above.derived {
		case ^ast.Call_Expr:
			for arg, i in owner.args {
				if arg == parent {
					return expected_param(ctx, owner, i)
				}
			}
		case ^ast.Comp_Lit:
			return expected_element(ctx, nodes, owner, parent)
		}
	case ^ast.Comp_Lit:
		return expected_element(ctx, nodes, p, node)
	}
	return
}

expected_result :: proc(
	ctx: ^ActionContext,
	nodes: []Node_At,
	stmt: ^ast.Return_Stmt,
	node: ^ast.Node,
) -> (
	expected: Expected,
	ok: bool,
) {
	function: ^ast.Proc_Lit
	#reverse for at in nodes {
		if f, is_proc := at.node.derived.(^ast.Proc_Lit); is_proc {
			function = f
			break
		}
	}
	if function == nil || function.type == nil || function.type.results == nil {
		return
	}
	types := make([dynamic]^ast.Expr, context.temp_allocator)
	for field in function.type.results.list {
		for _ in 0 ..< max(len(field.names), 1) {
			append(&types, field.type)
		}
	}
	if len(types) != len(stmt.results) {
		return
	}
	for result, i in stmt.results {
		if result == node && types[i] != nil {
			return type_at(ctx, types[i], ctx.ast_context.document_package)
		}
	}
	return
}

// A generic parameter's type depends on the argument, and an empty literal for a variadic one is a question for the
// compiler, so neither supplies a type.
expected_param :: proc(ctx: ^ActionContext, call: ^ast.Call_Expr, index: int) -> (expected: Expected, ok: bool) {
	value, symbol := plain_callee(ctx, call) or_return
	if value.generic || is_polymorphic(value) {
		return
	}
	field := get_call_arg_field(value, call^, index) or_return
	if field.type == nil {
		return
	}
	if _, variadic := field.type.derived.(^ast.Ellipsis); variadic {
		return
	}
	return type_at(ctx, field.type, symbol.pkg)
}

// What an element of lit is: the field that a key or a position names in a struct, or the element type of an array, a
// slice, a dynamic array or a bit set. A generic struct's field type depends on its arguments.
expected_element :: proc(
	ctx: ^ActionContext,
	nodes: []Node_At,
	lit: ^ast.Comp_Lit,
	elem: ^ast.Node,
) -> (
	expected: Expected,
	ok: bool,
) {
	owner: Expected
	if lit.type != nil {
		owner = type_at(ctx, lit.type, ctx.ast_context.document_package) or_return
	} else {
		owner = expected_of(ctx, nodes, lit) or_return
	}
	#partial switch v in owner.symbol.value {
	case SymbolStructValue:
		if v.poly != nil {
			return
		}
		index := -1
		if field, is_named := elem.derived.(^ast.Field_Value); is_named {
			name, is_ident := field.field.derived.(^ast.Ident)
			if !is_ident {
				return
			}
			index = slice.linear_search(v.names, name.name) or_else -1
		} else if len(v.usings) == 0 {
			for item, i in lit.elems {
				if item == elem {
					index = i
				}
			}
		}
		if index < 0 || index >= len(v.names) || v.from_usings[index] != -1 {
			return
		}
		return type_at(ctx, v.types[index], owner.symbol.pkg)
	case SymbolFixedArrayValue:
		return type_at(ctx, v.expr, owner.symbol.pkg)
	case SymbolSliceValue:
		return type_at(ctx, v.expr, owner.symbol.pkg)
	case SymbolDynamicArrayValue:
		return type_at(ctx, v.expr, owner.symbol.pkg)
	case SymbolBitSetValue:
		return type_at(ctx, v.expr, owner.symbol.pkg)
	}
	return
}

// Whether a parameter is written with a `$`. The flag on a resolved call does not always say so.
is_polymorphic :: proc(value: SymbolProcedureValue) -> bool {
	found := false
	visitor := ast.Visitor {
		data = &found,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node != nil {
				if _, is_poly := node.derived.(^ast.Poly_Type); is_poly {
					(^bool)(visitor.data)^ = true
				}
			}
			return visitor
		},
	}
	for field in value.orig_arg_types {
		ast.walk(&visitor, field)
	}
	return found
}

@(private = "package")
type_at :: proc(ctx: ^ActionContext, type: ^ast.Expr, pkg: string) -> (expected: Expected, ok: bool) {
	set_ast_package_set_scoped(ctx.ast_context, pkg)
	reset_ast_context(ctx.ast_context)
	ctx.ast_context.use_locals = pkg == ctx.ast_context.document_package
	symbol := resolve_type_expression(ctx.ast_context, type) or_return
	reset_ast_context(ctx.ast_context)
	return {symbol, type, pkg}, true
}

// Named types compare by their declaration. A field's symbol takes the name of the field, so the range tells them apart.
same_named :: proc(a, b: Symbol) -> bool {
	return(
		a.name != "" &&
		a.name == b.name &&
		a.pkg == b.pkg &&
		a.range == b.range &&
		a.pointers == 0 &&
		b.pointers == 0 &&
		.Anonymous not_in a.flags &&
		.Anonymous not_in b.flags \
	)
}

// Whether a literal written with its type has the type that the place expects. An unnamed type compares by its text.
@(private = "package")
same_type_written :: proc(ctx: ^ActionContext, written, expected: Expected) -> bool {
	if same_named(written.symbol, expected.symbol) {
		return true
	}
	if expected.type == nil {
		return false
	}
	ignored := make([dynamic]TextEdit, context.temp_allocator)
	a, a_ok := requalified_type_text(ctx, written.type, written.pkg, &ignored)
	b, b_ok := requalified_type_text(ctx, expected.type, expected.pkg, &ignored)
	return a_ok && b_ok && a == b
}

@(private = "package")
expected_text :: proc(
	ctx: ^ActionContext,
	at: ^ast.Ident,
	expected: Expected,
	edits: ^[dynamic]TextEdit,
) -> (
	string,
	bool,
) {
	if expected.type != nil {
		return requalified_type_text(ctx, expected.type, expected.pkg, edits)
	}
	if !declares_type(ctx, at, expected.symbol) {
		return "", false
	}
	return symbol_type_text(ctx.ast_context, expected.symbol, "", require_import = true)
}

// A pointer has no literal, and an inline struct or union written again is a new type.
takes_literal :: proc(text: string) -> bool {
	for prefix in ([]string{"^", "[^]", "proc", "struct", "union", "distinct"}) {
		if strings.has_prefix(text, prefix) {
			return false
		}
	}
	return true
}

// Whether the names in text mean types at the position of at.
@(private = "package")
name_holds :: proc(ctx: ^ActionContext, at: ^ast.Ident, text: string) -> bool {
	return spelled_names_hold(ctx, at, text, ctx.ast_context.document_package)
}

in_header :: proc(nodes: []Node_At, lit: ^ast.Comp_Lit) -> bool {
	for at in nodes {
		body: ^ast.Stmt
		#partial switch s in at.node.derived {
		case ^ast.If_Stmt:
			body = s.body
		case ^ast.For_Stmt:
			body = s.body
		case ^ast.Range_Stmt:
			body = s.body
		case ^ast.Switch_Stmt:
			body = s.body
		case ^ast.Type_Switch_Stmt:
			body = s.body
		case ^ast.When_Stmt:
			body = s.body
		case:
			continue
		}
		if body != nil && lit.pos.offset < body.pos.offset {
			return true
		}
	}
	return false
}

// An identifier with the position of node, which a name lookup takes as the place of the lookup.
@(private = "package")
position_ident :: proc(node: ^ast.Node, name: string) -> ^ast.Ident {
	ident := new_type(ast.Ident, node.pos, node.pos, context.temp_allocator)
	ident.name = name
	return ident
}

contains_node :: proc(list: []^ast.Expr, node: ^ast.Node) -> bool {
	for item in list {
		if item == node {
			return true
		}
	}
	return false
}

@(private = "package")
parent_of_node :: proc(nodes: []Node_At, node: ^ast.Node) -> ^ast.Node {
	for at in nodes {
		if at.node == node {
			return at.parent
		}
	}
	return nil
}
