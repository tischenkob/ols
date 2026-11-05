#+private file

package server

import "core:fmt"
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
	replaced := 0
	for candidate in find_exprs(stmt, start, end, exact) {
		if count == MAX_EXTRACT_WIDTHS || replaced == MAX_EXTRACT_WIDTHS {
			break
		}
		expr := candidate.expr
		single := extractable(ctx, stmt, expr, candidate.chain, exact)
		if single {
			name := pick_name(ctx, expr)

			edits := make([]TextEdit, 2, context.temp_allocator)
			edits[0] = TextEdit {
				range   = range_of(ctx, line_start, line_start),
				newText = strings.concatenate(
					{
						get_line_indentation(src, stmt.pos.offset),
						name,
						" := ",
						src[expr.pos.offset:expr.end.offset],
						"\n",
					},
					context.temp_allocator,
				),
			}
			edits[1] = TextEdit {
				range   = range_of(ctx, expr.pos.offset, expr.end.offset),
				newText = name,
			}

			append(ctx.actions, make_code_action(ctx, "Extract variable", "refactor.extract", edits))
			count += 1
		}
		// An inexact selection means the one smallest expression around it.
		inexact := start != end && !exact
		if !(inexact && replaced > 0) && add_replace_all(ctx, function, list.stmts, expr) {
			replaced += 1
		}
		if inexact && single {
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

	return runs_with_stmt(ctx, stmt, expr, chain)
}

// Whether the expression runs once, with the statement that holds it and after nothing it could depend on, so that a
// declaration above the statement can take its place.
runs_with_stmt :: proc(ctx: ^ActionContext, stmt: ^ast.Stmt, expr: ^ast.Expr, chain: []^ast.Node) -> bool {
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
		}
		// Part of a type is resolved at compile time, so a variable cannot stand in.
		if is_type_node(chain[i]) {
			return false
		}
		child = chain[i]
	}
	return true
}

is_type_node :: proc(node: ^ast.Node) -> bool {
	#partial switch _ in node.derived {
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
		return true
	}
	return false
}

// `value := 2` is an int whatever the literal fed, so the place the literal feeds must take its default type.
literal_type_holds :: proc(ctx: ^ActionContext, expr: ^ast.Expr, parent: ^ast.Node) -> bool {
	literal := expr.derived.(^ast.Basic_Lit)
	#partial switch literal.tok.kind {
	case .Integer:
		return place_takes_default(ctx, expr, parent, "int")
	case .Float:
		return place_takes_default(ctx, expr, parent, "f64")
	case .Rune:
		return place_takes_default(ctx, expr, parent, "rune")
	case .String:
		return place_takes_default(ctx, expr, parent, "string")
	}
	return false
}

// Whether the place that expr feeds takes a value of the default type. The cases that cannot establish the type refuse.
place_takes_default :: proc(ctx: ^ActionContext, expr: ^ast.Expr, parent: ^ast.Node, default_type: string) -> bool {
	names_default :: proc(type: ^ast.Expr, default_type: string) -> bool {
		// `name := value` has no type expression, so the type cannot be established.
		if type == nil {
			return false
		}
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
		// The left of a shift takes the type around it, and the right must be unsigned.
		if p.op.kind == .Shl || p.op.kind == .Shr {
			return false
		}
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
			if field.type != nil {
				if ellipsis, is_variadic := field.type.derived.(^ast.Ellipsis); is_variadic {
					return names_default(ellipsis.expr, default_type)
				}
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
	return fresh_name(ctx, pick_base(expr), expr.pos)
}

pick_base :: proc(expr: ^ast.Expr) -> string {
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
	return base
}

Occurrence :: struct {
	expr:  ^ast.Expr,
	chain: []^ast.Node, // the ancestors from the statement of the list down to the parent of expr
	stmt:  int, // the index of that statement in the list
}

// "Extract variable (replace all N)": a declaration above the first occurrence of the expression in the block, and
// its name in place of every occurrence.
add_replace_all :: proc(ctx: ^ActionContext, function: ^ast.Proc_Lit, stmts: []^ast.Stmt, expr: ^ast.Expr) -> bool {
	src := ctx.document.ast.src
	_, is_literal := expr.derived.(^ast.Basic_Lit)
	if !repeats_same_value(expr) {
		return false
	}

	occurrences := make([dynamic]Occurrence, context.temp_allocator)
	for found in find_occurrences(src, stmts, expr) {
		switch occurrence_use(ctx, found) {
		case .Refuse:
			return false
		case .Keep:
		case .Replace:
			append(&occurrences, found)
		}
	}
	if len(occurrences) < 2 {
		return false
	}

	// The first occurrence decides where the value is computed, so it must run whenever any later one does.
	first := occurrences[0]
	first_stmt := stmts[first.stmt]
	if _, is_block := first_stmt.derived.(^ast.Block_Stmt); is_block {
		return false
	}
	for node in first.chain {
		#partial switch _ in node.derived {
		case ^ast.Block_Stmt, ^ast.Case_Clause:
			return false
		}
	}
	line_start, _ := before_on_line(src, first_stmt.pos.offset)
	if !only_marks_stmt(first_stmt, src[line_start:first_stmt.pos.offset]) ||
	   marked_by_line_above(src, first_stmt.pos.offset) ||
	   !runs_with_stmt(ctx, first_stmt, first.expr, first.chain) {
		return false
	}

	region := stmts[first.stmt:occurrences[len(occurrences) - 1].stmt + 1]
	if !is_literal && !value_holds_over(ctx, function, expr, region) {
		return false
	}

	base := pick_base(expr)
	name := fresh_name(ctx, base, expr.pos)
	for i := 2; names_in_stmts(stmts, name); i += 1 {
		name = fresh_name(ctx, fmt.tprintf("%s%d", base, i), expr.pos)
	}

	edits := make([]TextEdit, len(occurrences) + 1, context.temp_allocator)
	edits[0] = TextEdit {
		range   = range_of(ctx, line_start, line_start),
		newText = strings.concatenate(
			{get_line_indentation(src, first_stmt.pos.offset), name, " := ", node_text(src, expr), "\n"},
			context.temp_allocator,
		),
	}
	for occurrence, i in occurrences {
		edits[i + 1] = TextEdit {
			range   = range_of(ctx, occurrence.expr.pos.offset, occurrence.expr.end.offset),
			newText = name,
		}
	}
	title := fmt.tprintf("Extract variable (replace all %d)", len(occurrences))
	append(ctx.actions, make_code_action(ctx, title, "refactor.extract", edits))
	return true
}

// A call could run a different number of times. A composite literal is a fresh value each time, and `context` and a
// directive such as `#line` are not the same at each place.
repeats_same_value :: proc(expr: ^ast.Expr) -> bool {
	found := has_side_effect(expr)
	visitor := ast.Visitor {
		data = &found,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			#partial switch _ in node.derived {
			case ^ast.Selector_Call_Expr, ^ast.Comp_Lit, ^ast.Proc_Lit, ^ast.Implicit, ^ast.Basic_Directive:
				(^bool)(visitor.data)^ = true
				return nil
			}
			return visitor
		},
	}
	ast.walk(&visitor, expr)
	return !found
}

// Each value expression in the statements with the same text as expr, without looking inside one.
find_occurrences :: proc(src: string, stmts: []^ast.Stmt, expr: ^ast.Expr) -> []Occurrence {
	Data :: struct {
		src, text: string,
		stmt:      int,
		stack:     [dynamic]^ast.Node,
		found:     [dynamic]Occurrence,
	}
	data := Data {
		src   = src,
		text  = node_text(src, expr),
		stack = make([dynamic]^ast.Node, context.temp_allocator),
		found = make([dynamic]Occurrence, context.temp_allocator),
	}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil {
				pop(&data.stack)
				return nil
			}
			if node_text(data.src, node) == data.text && is_value_expr(node, true) {
				chain := slice.clone(data.stack[:], context.temp_allocator)
				append(&data.found, Occurrence{cast(^ast.Expr)node, chain, data.stmt})
				return nil
			}
			append(&data.stack, node)
			return visitor
		},
	}
	for stmt, i in stmts {
		data.stmt = i
		ast.walk(&visitor, stmt)
	}
	return data.found[:]
}

Occurrence_Use :: enum {
	Replace,
	Keep, // not a value at run time: it stays as written and does not count
	Refuse,
}

occurrence_use :: proc(ctx: ^ActionContext, occurrence: Occurrence) -> Occurrence_Use {
	expr := occurrence.expr
	chain := occurrence.chain
	use := Occurrence_Use.Replace
	child: ^ast.Node = expr
	#reverse for node in chain {
		#partial switch n in node.derived {
		case ^ast.Proc_Lit, ^ast.Defer_Stmt:
			// A nested procedure has no access to the variable, and a `defer` runs after anything below it.
			return .Refuse
		case ^ast.When_Stmt:
			if child == n.cond {
				use = .Keep
			}
		case ^ast.Case_Clause:
			if slice.contains(n.list, cast(^ast.Expr)child) {
				use = .Keep
			}
		case:
			if is_type_node(node) {
				use = .Keep
			}
		}
		child = node
	}
	if use == .Keep || len(chain) == 0 {
		return use
	}
	if works_on_original(expr, chain) {
		return .Refuse
	}

	parent := chain[len(chain) - 1]
	#partial switch p in parent.derived {
	case ^ast.Call_Expr:
		if expr == p.expr {
			return .Keep
		}
	case ^ast.Comp_Lit:
		if expr == p.type {
			return .Keep
		}
	case ^ast.Field_Value:
		if expr == p.field {
			return .Keep
		}
	case ^ast.Type_Cast:
		if expr == p.type {
			return .Keep
		}
	case ^ast.Type_Assertion:
		if expr == p.type {
			return .Keep
		}
	case ^ast.Value_Decl:
		if expr == p.type {
			return .Keep
		}
		// `v, ok := m[k]` takes two values from one.
		if len(p.names) != len(p.values) {
			return .Refuse
		}
	case ^ast.Assign_Stmt:
		if len(p.lhs) != len(p.rhs) {
			return .Refuse
		}
	case ^ast.Unary_Expr:
		if p.op.kind == .And {
			return .Refuse
		}
	case ^ast.Selector_Call_Expr, ^ast.Expr_Stmt, ^ast.Using_Stmt:
		return .Refuse
	}
	if _, is_literal := expr.derived.(^ast.Basic_Lit); is_literal && !literal_type_holds(ctx, expr, parent) {
		return .Refuse
	}
	if is_untyped_bool(expr) && !place_takes_bool(ctx, expr, parent) {
		return .Refuse
	}
	return .Replace
}

// Whether a slice or a method reaches the expression through fields and elements. A slice of a copy no longer writes
// to the original, and a method receives the address of what precedes the arrow.
works_on_original :: proc(expr: ^ast.Expr, chain: []^ast.Node) -> bool {
	target: rawptr = expr
	#reverse for parent in chain {
		#partial switch p in parent.derived {
		case ^ast.Selector_Expr:
			if rawptr(p.expr) != target {
				return false
			}
			if p.op.kind == .Arrow_Right {
				return true
			}
		case ^ast.Index_Expr:
			if rawptr(p.expr) != target {
				return false
			}
		case ^ast.Paren_Expr:
		case ^ast.Slice_Expr:
			return rawptr(p.expr) == target
		case:
			return false
		}
		target = parent
	}
	return false
}

// A comparison is an untyped boolean, so `x: b8 = a < b` compiles where `x: b8 = value` does not. An operand of `&&` and
// `||` can be untyped too.
is_untyped_bool :: proc(expr: ^ast.Expr) -> bool {
	#partial switch e in expr.derived {
	case ^ast.Paren_Expr:
		return is_untyped_bool(e.expr)
	case ^ast.Unary_Expr:
		return e.op.kind == .Not && is_untyped_bool(e.expr)
	case ^ast.Binary_Expr:
		#partial switch e.op.kind {
		case .Cmp_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq, .In, .Not_In:
			return true
		case .Cmp_And, .Cmp_Or:
			return is_untyped_bool(e.left) || is_untyped_bool(e.right)
		}
	}
	return false
}

// A condition takes any boolean, and any other place must take `bool`, which `value := a < b` declares.
place_takes_bool :: proc(ctx: ^ActionContext, expr: ^ast.Expr, parent: ^ast.Node) -> bool {
	#partial switch p in parent.derived {
	case ^ast.If_Stmt:
		return p.cond == expr
	case ^ast.For_Stmt:
		return p.cond == expr
	case ^ast.Ternary_If_Expr:
		return p.cond == expr
	}
	return place_takes_default(ctx, expr, parent, "bool")
}

// `c ? 1 : 2`, `1 << n` and `auto_cast n` take their type from the place they feed, where a variable has one type of
// its own. Any ternary counts, as its branches may not show their type.
takes_type_from_place :: proc(typed: SymbolAndNodeMap, expr: ^ast.Expr) -> bool {
	Data :: struct {
		typed: SymbolAndNodeMap,
		found: bool,
	}
	data := Data {
		typed = typed,
	}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil || data.found {
				return nil
			}
			#partial switch n in node.derived {
			case ^ast.Ternary_If_Expr, ^ast.Ternary_When_Expr, ^ast.Auto_Cast:
				data.found = true
			case ^ast.Binary_Expr:
				if n.op.kind == .Shl || n.op.kind == .Shr {
					data.found = !reads_a_variable(data.typed, n.left)
				}
			}
			return visitor
		},
	}
	ast.walk(&visitor, expr)
	return data.found
}

reads_a_variable :: proc(typed: SymbolAndNodeMap, expr: ^ast.Expr) -> bool {
	for use in collect_ident_uses(expr) {
		if !is_member_name(use) && is_variable(typed, use.ident) {
			return true
		}
	}
	return false
}

// Whether every occurrence in the statements reads the value that the first one computes. The expression must read a
// variable and must not take its type from each place it feeds, as a constant expression does.
value_holds_over :: proc(ctx: ^ActionContext, function: ^ast.Proc_Lit, expr: ^ast.Expr, region: []^ast.Stmt) -> bool {
	typed := resolve_entire_file(ctx.document)
	names := make([dynamic]string, context.temp_allocator)
	for use in collect_ident_uses(expr) {
		if is_member_name(use) {
			continue
		}
		resolved, found := typed[uintptr(use.ident)]
		if !found || resolved.is_unresolved {
			return false
		}
		append(&names, use.ident.name)
	}
	if !reads_a_variable(typed, expr) || takes_type_from_place(typed, expr) {
		return false
	}

	for stmt in region {
		if writes_or_declares(stmt, names[:]) {
			return false
		}
	}

	symbols := resolve_entire_file_for_references(ctx.document, context.temp_allocator, .Identifier, "")
	// A nested procedure sees the static locals of the procedures around it.
	top: ^ast.Node = function.body
	for decl in ctx.document.ast.decls {
		if decl.pos.offset <= function.pos.offset && function.end.offset <= decl.end.offset {
			top = decl
		}
	}
	stable := stable_locals(ctx, symbols, typed, top, collect_ident_uses(function.body))
	if !reads_shared_state(typed, stable, expr) {
		return true
	}
	for stmt in region {
		if may_write_memory(typed, stable, stmt) {
			return false
		}
	}
	return true
}

// Whether the statement writes one of the names, or declares one so that the same text means something else. A `using`
// can bring in any name.
writes_or_declares :: proc(stmt: ^ast.Stmt, names: []string) -> bool {
	for use in collect_ident_uses(stmt) {
		if is_member_name(use) || !slice.contains(names, use.ident.name) {
			continue
		}
		if is_write(use) {
			return true
		}
		if len(use.parents) == 0 {
			continue
		}
		#partial switch p in use.parents[len(use.parents) - 1].derived {
		case ^ast.Value_Decl:
			if slice.contains(p.names, use.ident) {
				return true
			}
		case ^ast.Range_Stmt:
			if slice.contains(p.vals, use.ident) {
				return true
			}
		case ^ast.Unroll_Range_Stmt:
			if p.val0 == use.ident || p.val1 == use.ident {
				return true
			}
		case ^ast.Field:
			if slice.contains(p.names, use.ident) {
				return true
			}
		}
	}

	found := false
	visitor := ast.Visitor {
		data = &found,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			#partial switch n in node.derived {
			case ^ast.Using_Stmt:
				(^bool)(visitor.data)^ = true
			case ^ast.Value_Decl:
				(^bool)(visitor.data)^ ||= n.is_using
			}
			return visitor
		},
	}
	ast.walk(&visitor, stmt)
	return found
}

// Whether the value depends on memory that code without the names in the expression can change: a global, a static
// local, a local whose address is taken, or anything reached through a pointer, a slice or a map.
reads_shared_state :: proc(typed: SymbolAndNodeMap, stable: map[^ast.Ident]bool, expr: ^ast.Expr) -> bool {
	for use in collect_ident_uses(expr) {
		if !is_member_name(use) && is_variable(typed, use.ident) && !stable[use.ident] {
			return true
		}
	}

	Data :: struct {
		typed: SymbolAndNodeMap,
		found: bool,
	}
	data := Data {
		typed = typed,
	}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil || data.found {
				return nil
			}
			#partial switch n in node.derived {
			case ^ast.Deref_Expr, ^ast.Slice_Expr, ^ast.Matrix_Index_Expr:
				data.found = true
			case ^ast.Selector_Expr:
				data.found = reaches_through(data.typed, n.expr, n)
			case ^ast.Index_Expr:
				data.found = reaches_through(data.typed, n.expr, n)
			}
			return visitor
		},
	}
	ast.walk(&visitor, expr)
	return data.found
}

// Whether the field or element `access` of base lives outside base. A base the resolver misses counts, and so does a
// variable of another package.
reaches_through :: proc(typed: SymbolAndNodeMap, base: ^ast.Expr, access: ^ast.Node) -> bool {
	resolved, found := typed[uintptr(base)]
	if !found || resolved.is_unresolved || resolved.symbol.pointers > 0 {
		return true
	}
	#partial switch _ in resolved.symbol.value {
	case SymbolPackageValue:
		return is_variable(typed, access)
	case SymbolStructValue, SymbolFixedArrayValue, SymbolEnumValue, SymbolBitFieldValue:
		return false
	}
	return true
}

// Whether the statement calls a procedure or writes anything but a local that nothing else reaches. A conversion and a
// pure builtin do neither. A `for &e` writes through e.
may_write_memory :: proc(typed: SymbolAndNodeMap, stable: map[^ast.Ident]bool, stmt: ^ast.Stmt) -> bool {
	Data :: struct {
		typed:  SymbolAndNodeMap,
		stable: map[^ast.Ident]bool,
		found:  bool,
	}
	data := Data {
		typed  = typed,
		stable = stable,
	}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil || data.found {
				return nil
			}
			#partial switch n in node.derived {
			case ^ast.Selector_Call_Expr:
				data.found = true
			case ^ast.Call_Expr:
				data.found = !calls_nothing(data.typed, n)
			case ^ast.Assign_Stmt:
				for lhs in n.lhs {
					name, is_name := lhs.derived.(^ast.Ident)
					data.found ||= !is_name || (name.name != "_" && !data.stable[name])
				}
			case ^ast.Range_Stmt:
				data.found = has_address_binding(n.vals)
			case ^ast.Unroll_Range_Stmt:
				data.found = is_address_of(n.val0) || is_address_of(n.val1)
			}
			return visitor
		},
	}
	ast.walk(&visitor, stmt)
	return data.found
}

calls_nothing :: proc(typed: SymbolAndNodeMap, call: ^ast.Call_Expr) -> bool {
	if builtin_call(typed, call) != .Other {
		return true
	}
	resolved, found := typed[uintptr(call.expr)]
	if !found || resolved.is_unresolved {
		return false
	}
	#partial switch _ in resolved.symbol.value {
	case SymbolProcedureValue, SymbolProcedureGroupValue, SymbolAggregateValue:
		return false
	}
	return .Mutable not_in resolved.symbol.flags && .Parameter not_in resolved.symbol.flags
}

names_in_stmts :: proc(stmts: []^ast.Stmt, name: string) -> bool {
	for stmt in stmts {
		if mentions_any(stmt, name) {
			return true
		}
	}
	return false
}
