#+private file

package server

import "core:odin/ast"
import "core:slice"
import "core:strings"

@(private = "package")
add_extract_variable_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_extract_variable {
		return
	}

	function := ctx.position_context.function
	if function == nil || function.body == nil {
		return
	}

	src := ctx.document.ast.src
	start, end := trim_selection(src, ctx.range.start, ctx.range.end)

	list, found := find_stmt_list_at(function.body, start, end)
	if !found || list.first != list.last {
		return
	}
	stmt := list.stmts[list.first]
	if stmt.pos.offset > start || end > stmt.end.offset {
		return
	}

	line_start := stmt.pos.offset
	for line_start > 0 && src[line_start - 1] != '\n' {
		line_start -= 1
	}
	// A statement sharing its line with something else (a `do` body, a semicolon) would get the
	// declaration hoisted above that, out of the conditional it runs under.
	if !only_marks_stmt(stmt, src[line_start:stmt.pos.offset]) {
		return
	}

	exact := selects_exact_node(stmt, start, end)
	count := 0
	for candidate in find_exprs(stmt, start, end, exact) {
		if count == MAX_EXTRACT_WIDTHS {
			break
		}
		expr := candidate.expr
		if !extractable(ctx, stmt, expr, candidate.chain, exact) {
			continue
		}
		name := pick_name(ctx, expr)

		edits := make([]TextEdit, 2, context.temp_allocator)
		edits[0] = TextEdit {
			range   = range_of(ctx, line_start, line_start),
			newText = strings.concatenate(
				{get_line_indentation(src, stmt.pos.offset), name, " := ", src[expr.pos.offset:expr.end.offset], "\n"},
				context.temp_allocator,
			),
		}
		edits[1] = TextEdit {
			range   = range_of(ctx, expr.pos.offset, expr.end.offset),
			newText = name,
		}

		append(ctx.actions, make_code_action(ctx, "Extract variable", "refactor.extract", edits))
		count += 1
		// An inexact selection means the one smallest expression around it.
		if start != end && !exact {
			break
		}
	}
}

// Whether the text before a statement on its line holds only the statement's own label and a directive
// that does not change how the hoisted expression evaluates. Such a text stays with the statement.
only_marks_stmt :: proc(stmt: ^ast.Stmt, prefix: string) -> bool {
	label: ^ast.Expr
	#partial switch s in stmt.derived {
	case ^ast.For_Stmt:
		label = s.label
	case ^ast.Range_Stmt:
		label = s.label
	case ^ast.Switch_Stmt:
		label = s.label
	case ^ast.Type_Switch_Stmt:
		label = s.label
	case ^ast.If_Stmt:
		label = s.label
	case ^ast.Block_Stmt:
		label = s.label
	}
	rest := strings.trim_space(prefix)
	if label != nil {
		if ident, is_ident := label.derived.(^ast.Ident); is_ident {
			rest = strings.trim_prefix(rest, ident.name)
			rest = strings.trim_prefix(strings.trim_space(rest), ":")
			rest = strings.trim_space(rest)
		}
	}
	switch rest {
	case "", "#partial", "#reverse":
		return true
	}
	return false
}

// Expressions that produce a value on their own. A literal counts too. Parenthesized expressions
// only count when selected, since the cursor alone should pick the operation around them.
is_value_expr :: proc(node: ^ast.Node, selected: bool) -> bool {
	#partial switch n in node.derived {
	case ^ast.Binary_Expr:
		#partial switch n.op.kind {
		case .Range_Half, .Range_Full, .Ellipsis, .In, .Not_In:
			// A range has no value outside its clause.
			return false
		}
		return true
	case ^ast.Call_Expr,
	     ^ast.Selector_Expr,
	     ^ast.Selector_Call_Expr,
	     ^ast.Index_Expr,
	     ^ast.Matrix_Index_Expr,
	     ^ast.Slice_Expr,
	     ^ast.Deref_Expr,
	     ^ast.Ternary_If_Expr,
	     ^ast.Or_Else_Expr,
	     ^ast.Type_Cast,
	     ^ast.Auto_Cast,
	     ^ast.Type_Assertion:
		return true
	case ^ast.Unary_Expr:
		return n.expr != nil
	case ^ast.Comp_Lit:
		return n.type != nil
	case ^ast.Basic_Lit:
		return true
	case ^ast.Paren_Expr:
		return selected
	}
	return false
}

Candidate :: struct {
	expr:  ^ast.Expr,
	// The ancestors from stmt down to the parent of expr.
	chain: []^ast.Node,
}

// The selected expression (exact match), or every value expression around the cursor or the inexact
// selection, innermost first.
find_exprs :: proc(stmt: ^ast.Stmt, start, end: int, exact: bool) -> []Candidate {
	Data :: struct {
		start, end: int,
		exact:      bool,
		stack:      [dynamic]^ast.Node,
		found:      [dynamic]Candidate,
	}

	data := Data {
		start = start,
		end   = end,
		exact = exact,
		stack = make([dynamic]^ast.Node, context.temp_allocator),
		found = make([dynamic]Candidate, context.temp_allocator),
	}

	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil {
				pop(&data.stack)
				return nil
			}
			if node.pos.offset > data.start || data.end > node.end.offset {
				return nil
			}

			if data.exact && len(data.found) > 0 {
				return nil
			}
			at_selection := node.pos.offset == data.start && node.end.offset == data.end
			if (!data.exact || at_selection) && is_value_expr(node, data.start != data.end) {
				chain := slice.clone(data.stack[:], context.temp_allocator)
				append(&data.found, Candidate{cast(^ast.Expr)node, chain})
				if data.exact {
					return nil
				}
			}

			append(&data.stack, node)
			return visitor
		},
	}

	ast.walk(&visitor, stmt)
	slice.reverse(data.found[:])
	return data.found[:]
}

extractable :: proc(ctx: ^ActionContext, stmt: ^ast.Stmt, expr: ^ast.Expr, chain: []^ast.Node, exact: bool) -> bool {
	if len(chain) == 0 {
		return false
	}

	// A literal the cursor is on has a name to gain even as a whole initializer. It takes its default type there.
	_, is_literal := expr.derived.(^ast.Basic_Lit)
	cursor_literal := is_literal && !exact
	if cursor_literal && !literal_type_holds(ctx, expr, chain[len(chain) - 1]) {
		return false
	}

	#partial switch p in chain[len(chain) - 1].derived {
	case ^ast.Value_Decl:
		if expr == p.type || slice.contains(p.names, expr) {
			return false
		}
		if len(p.values) == 1 && p.values[0] == expr && !cursor_literal {
			return false
		}
	case ^ast.Assign_Stmt:
		if slice.contains(p.lhs, expr) {
			return false
		}
		_, is_subject := stmt.derived.(^ast.Type_Switch_Stmt)
		if len(p.rhs) == 1 && p.rhs[0] == expr && !cursor_literal && !is_subject {
			return false
		}
	case ^ast.Expr_Stmt, ^ast.Using_Stmt, ^ast.Selector_Call_Expr:
		return false
	case ^ast.Call_Expr:
		if expr == p.expr {
			return false
		}
	case ^ast.Comp_Lit:
		if expr == p.type {
			return false
		}
	case ^ast.Field_Value:
		if expr == p.field {
			return false
		}
	case ^ast.Type_Cast:
		if expr == p.type {
			return false
		}
	case ^ast.Type_Assertion:
		if expr == p.type {
			return false
		}
	case ^ast.Unary_Expr:
		if p.op.kind == .And {
			return false
		}
	}

	// The direct child of the statement on the path to the expression.
	top: ^ast.Node = len(chain) > 1 ? chain[1] : expr

	#partial switch s in stmt.derived {
	case ^ast.If_Stmt:
		if s.init != nil && (top != s.init || !leaves_init_intact(s.init, expr)) {
			return false
		}
	case ^ast.Switch_Stmt:
		if s.init != nil && (top != s.init || !leaves_init_intact(s.init, expr)) {
			return false
		}
	case ^ast.For_Stmt:
		if s.init == nil || top != s.init || !leaves_init_intact(s.init, expr) {
			return false
		}
	case ^ast.Range_Stmt:
		if top != s.expr || has_address_binding(s.vals) || !iterable_evaluates_once(ctx, s.expr) {
			return false
		}
	case ^ast.Type_Switch_Stmt:
		tag, is_assign := s.tag.derived.(^ast.Assign_Stmt)
		if !is_assign || top != s.tag || has_address_binding(tag.lhs) {
			return false
		}
	case ^ast.Value_Decl:
		if !s.is_mutable {
			return false
		}
	case ^ast.When_Stmt, ^ast.Defer_Stmt, ^ast.Unroll_Range_Stmt, ^ast.Using_Stmt:
		return false
	}

	// Below the statement, only the child on the path decides whether the expression is
	// evaluated conditionally. Any nested statement there is an else-if or a when branch.
	child: ^ast.Node = expr
	for i := len(chain) - 1; i > 0; i -= 1 {
		#partial switch p in chain[i].derived {
		case ^ast.Ternary_If_Expr:
			if child != p.cond {
				return false
			}
		case ^ast.Or_Else_Expr:
			if child == p.y {
				return false
			}
		case ^ast.Binary_Expr:
			if (p.op.kind == .Cmp_And || p.op.kind == .Cmp_Or) && child == p.right {
				return false
			}
		case ^ast.Field_Value:
			// A designator such as `[1 + 2] = x` needs a constant.
			if child == p.field {
				return false
			}
		case ^ast.Ternary_When_Expr, ^ast.Proc_Lit, ^ast.If_Stmt, ^ast.Switch_Stmt, ^ast.When_Stmt:
			return false
		case ^ast.Array_Type,
		     ^ast.Dynamic_Array_Type,
		     ^ast.Multi_Pointer_Type,
		     ^ast.Pointer_Type,
		     ^ast.Map_Type,
		     ^ast.Matrix_Type,
		     ^ast.Bit_Set_Type,
		     ^ast.Struct_Type,
		     ^ast.Union_Type,
		     ^ast.Enum_Type,
		     ^ast.Bit_Field_Type,
		     ^ast.Proc_Type,
		     ^ast.Distinct_Type,
		     ^ast.Poly_Type:
			// Part of a type is resolved at compile time, so a variable cannot stand in.
			return false
		}
		child = chain[i]
	}
	return true
}

// `value := 2` is an int whatever the literal fed, so the place the literal feeds must take its default type.
// The cases that cannot establish the type refuse.
literal_type_holds :: proc(ctx: ^ActionContext, expr: ^ast.Expr, parent: ^ast.Node) -> bool {
	literal := expr.derived.(^ast.Basic_Lit)
	default_type: string
	#partial switch literal.tok.kind {
	case .Integer:
		default_type = "int"
	case .Float:
		default_type = "f64"
	case .Rune:
		default_type = "rune"
	case .String:
		default_type = "string"
	case:
		return false
	}

	names_default :: proc(type: ^ast.Expr, default_type: string) -> bool {
		name, is_name := type.derived.(^ast.Ident)
		return is_name && (name.name == default_type || name.name == "any")
	}
	value_has_default :: proc(ctx: ^ActionContext, value: ^ast.Expr, default_type: string) -> bool {
		ctx.ast_context.use_locals = true
		symbol, ok := resolve_type_expression(ctx.ast_context, value)
		if !ok {
			return false
		}
		text, text_ok := symbol_type_text(ctx.ast_context, symbol, "")
		return text_ok && text == default_type
	}

	#partial switch p in parent.derived {
	case ^ast.Value_Decl:
		return p.type == nil || names_default(p.type, default_type)
	case ^ast.Assign_Stmt:
		index, found := slice.linear_search(p.rhs, expr)
		return found && len(p.lhs) == len(p.rhs) && value_has_default(ctx, p.lhs[index], default_type)
	case ^ast.Binary_Expr:
		return value_has_default(ctx, p.left == expr ? p.right : p.left, default_type)
	case ^ast.Return_Stmt:
		function := ctx.position_context.function
		index, found := slice.linear_search(p.results, expr)
		if !found || function == nil || function.type.results == nil {
			return false
		}
		results := field_types(function.type.results.list)
		return index < len(results) && len(results) == len(p.results) && names_default(results[index], default_type)
	case ^ast.Call_Expr:
		index, found := slice.linear_search(p.args, expr)
		if !found {
			return false
		}
		ctx.ast_context.use_locals = true
		symbol, resolved := resolve_type_expression(ctx.ast_context, p.expr)
		if !resolved {
			// An undefined name has no signature to break. A directive or an unindexed package may have one.
			_, is_name := p.expr.derived.(^ast.Ident)
			return is_name
		}
		callee, is_proc := symbol.value.(SymbolProcedureValue)
		if !is_proc {
			return false
		}
		for field in callee.arg_types {
			if ellipsis, is_variadic := field.type.derived.(^ast.Ellipsis); is_variadic {
				return names_default(ellipsis.expr, default_type)
			}
			for name in field.names {
				if index == 0 {
					_, is_poly := name.derived.(^ast.Poly_Type)
					return !is_poly && names_default(field.type, default_type)
				}
				index -= 1
			}
		}
	}
	return false
}

// A declaration above the statement must not lose a name the init declares, nor overtake a call the
// init runs first.
leaves_init_intact :: proc(init: ^ast.Stmt, expr: ^ast.Expr) -> bool {
	if decl, is_decl := init.derived.(^ast.Value_Decl); is_decl {
		for use in collect_ident_uses(expr) {
			for name in decl.names {
				if ident, is_ident := name.derived.(^ast.Ident); is_ident && ident.name == use.ident.name {
					return false
				}
			}
		}
	}

	Data :: struct {
		limit: int,
		found: bool,
	}
	data := Data {
		limit = expr.pos.offset,
	}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil {
				return nil
			}
			#partial switch _ in node.derived {
			case ^ast.Call_Expr, ^ast.Selector_Call_Expr:
				data.found ||= node.end.offset <= data.limit
			}
			return visitor
		},
	}
	ast.walk(&visitor, init)
	return !data.found
}

has_address_binding :: proc(names: []^ast.Expr) -> bool {
	for name in names {
		if unary, is_unary := name.derived.(^ast.Unary_Expr); is_unary && unary.op.kind == .And {
			return true
		}
	}
	return false
}

// A call that returns several values with a final ok is an iterator, which the loop calls every round.
iterable_evaluates_once :: proc(ctx: ^ActionContext, iterable: ^ast.Expr) -> bool {
	#partial switch n in iterable.derived {
	case ^ast.Selector_Call_Expr:
		return false
	case ^ast.Call_Expr:
		ctx.ast_context.use_locals = true
		symbol, ok := resolve_type_expression(ctx.ast_context, n.expr)
		if !ok {
			return false
		}
		#partial switch v in symbol.value {
		case SymbolProcedureValue:
			return get_proc_return_value_count(v.return_types) == 1
		case SymbolProcedureGroupValue:
			return false
		}
	}
	return true
}

pick_name :: proc(ctx: ^ActionContext, expr: ^ast.Expr) -> string {
	base := "value"
	#partial switch e in expr.derived {
	case ^ast.Call_Expr:
		#partial switch callee in e.expr.derived {
		case ^ast.Ident:
			base = callee.name
		case ^ast.Selector_Expr:
			base = callee.field.name
		}
	case ^ast.Selector_Expr:
		base = e.field.name
	}

	return fresh_name(ctx, base, expr.pos)
}
