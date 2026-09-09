package server

import "core:fmt"
import "core:odin/ast"
import "core:strings"

Simplification :: struct {
	start, end: int, // byte range replaced
	code:       string, // one per rule
	title:      string, // quickfix title
	text:       string, // replacement
}

@(private = "file")
Rule :: proc(src: string, node: ^ast.Node, parents: []^ast.Node, out: ^[dynamic]Simplification)

@(private = "file")
rules := [?]Rule {
	simplify_array_broadcast,
	simplify_bool_return,
	simplify_bool_compare,
	simplify_double_negation,
	simplify_bool_ternary,
	simplify_redundant_parens,
	simplify_full_slice,
	simplify_for_true,
	simplify_make_zero,
	simplify_empty_else,
	simplify_compound_assign,
	simplify_nested_if,
	simplify_range_loop,
	simplify_or_else,
	simplify_or_return,
	simplify_redundant_else,
	simplify_trailing_return,
}

// Every rule is syntactic; none resolves a symbol. Results are in walk order.
simplifications :: proc(document: ^Document) -> []Simplification {
	Walker :: struct {
		src:   string,
		stack: [dynamic]^ast.Node,
		out:   [dynamic]Simplification,
	}
	w := Walker {
		src   = document.ast.src,
		stack = make([dynamic]^ast.Node, context.temp_allocator),
		out   = make([dynamic]Simplification, context.temp_allocator),
	}
	visitor := ast.Visitor {
		data = &w,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			w := (^Walker)(visitor.data)
			if node == nil {
				pop(&w.stack)
				return nil
			}
			for rule in rules {
				rule(w.src, node, w.stack[:], &w.out)
			}
			append(&w.stack, node)
			return visitor
		},
	}
	for decl in document.ast.decls {
		ast.walk(&visitor, decl)
	}
	return w.out[:]
}

simplification_message :: proc(s: Simplification) -> string {
	text := s.text
	if i := strings.index_byte(text, '\n'); i >= 0 {
		text = text[:i]
	}
	if text == "" {
		return "can be removed"
	}
	return fmt.tprintf("can be simplified to %s", text)
}

@(private = "file")
enclosing_proc :: proc(parents: []^ast.Node) -> ^ast.Proc_Lit {
	#reverse for parent in parents {
		if lit, ok := parent.derived.(^ast.Proc_Lit); ok {
			return lit
		}
	}
	return nil
}

@(private = "file")
bool_lit :: proc(expr: ^ast.Expr) -> (value: bool, ok: bool) {
	ident := expr.derived.(^ast.Ident) or_return
	switch ident.name {
	case "true":
		return true, true
	case "false":
		return false, true
	}
	return false, false
}

@(private = "file")
is_lit :: proc(expr: ^ast.Expr, text: string) -> bool {
	lit, ok := expr.derived.(^ast.Basic_Lit)
	return ok && lit.tok.text == text
}

@(private = "file")
return_of :: proc(stmt: ^ast.Stmt) -> (value: bool, ok: bool) {
	ret := stmt.derived.(^ast.Return_Stmt) or_return
	if len(ret.results) != 1 {
		return false, false
	}
	return bool_lit(ret.results[0])
}

@(private = "file")
sized_array :: proc(type: ^ast.Expr) -> bool {
	if type == nil {
		return false
	}
	array, ok := type.derived.(^ast.Array_Type)
	if !ok || array.len == nil {
		return false
	}
	_, is_unknown := array.len.derived.(^ast.Unary_Expr)
	return !is_unknown
}

// The one number every element of the literal repeats.
@(private = "file")
broadcast_elem :: proc(src: string, lit: ^ast.Comp_Lit) -> (string, bool) {
	if len(lit.elems) < 2 {
		return "", false
	}
	first := strip_space(node_text(src, lit.elems[0]))
	for elem in lit.elems {
		if !is_number_lit(elem) || strip_space(node_text(src, elem)) != first {
			return "", false
		}
	}
	return node_text(src, lit.elems[0]), true
}

is_number_lit :: proc(expr: ^ast.Expr) -> bool {
	e := expr
	if neg, ok := e.derived.(^ast.Unary_Expr); ok && neg.op.kind == .Sub && neg.expr != nil {
		e = neg.expr
	}
	lit, ok := e.derived.(^ast.Basic_Lit)
	return ok && (lit.tok.kind == .Integer || lit.tok.kind == .Float)
}

@(private = "file")
simplify_array_broadcast :: proc(src: string, node: ^ast.Node, _: []^ast.Node, out: ^[dynamic]Simplification) {
	type, value: ^ast.Expr
	decl: ^ast.Value_Decl
	#partial switch n in node.derived {
	case ^ast.Value_Decl:
		if len(n.names) != 1 || len(n.values) != 1 {
			return
		}
		decl, type, value = n, n.type, n.values[0]
	case ^ast.Field:
		if len(n.names) != 1 {
			return
		}
		type, value = n.type, n.default_value
	case:
		return
	}
	if value == nil {
		return
	}
	lit, is_lit := value.derived.(^ast.Comp_Lit)
	if !is_lit {
		return
	}
	elem, has_elem := broadcast_elem(src, lit)
	if !has_elem {
		return
	}

	if sized_array(type) {
		if lit.type != nil && strip_space(node_text(src, lit.type)) != strip_space(node_text(src, type)) {
			return
		}
		append(
			out,
			Simplification{lit.pos.offset, lit.end.offset, "array-broadcast", "Use scalar for array literal", elem},
		)
		return
	}
	if decl == nil || type != nil || !sized_array(lit.type) {
		return
	}
	sep := decl.is_mutable ? "=" : ":"
	text := fmt.tprintf("%s: %s %s %s", node_text(src, decl.names[0]), node_text(src, lit.type), sep, elem)
	append(
		out,
		Simplification {
			decl.names[0].pos.offset,
			lit.end.offset,
			"array-broadcast",
			"Use scalar for array literal",
			text,
		},
	)
}

@(private = "file")
returns_bool :: proc(lit: ^ast.Proc_Lit) -> bool {
	if lit == nil || lit.type == nil || lit.type.results == nil || len(lit.type.results.list) != 1 {
		return false
	}
	field := lit.type.results.list[0]
	if len(field.names) > 1 || field.type == nil {
		return false
	}
	ident, ok := field.type.derived.(^ast.Ident)
	return ok && ident.name == "bool"
}

// Matches at the statement list so the `if … { return true }` / `return false` pair is visible.
@(private = "file")
simplify_bool_return :: proc(src: string, node: ^ast.Node, parents: []^ast.Node, out: ^[dynamic]Simplification) {
	stmts: []^ast.Stmt
	#partial switch n in node.derived {
	case ^ast.Block_Stmt:
		stmts = n.stmts
	case ^ast.Case_Clause:
		stmts = n.body
	case:
		return
	}
	if !returns_bool(enclosing_proc(parents)) {
		return
	}
	for stmt, i in stmts {
		if_stmt, is_if := stmt.derived.(^ast.If_Stmt)
		if !is_if || if_stmt.init != nil || if_stmt.label != nil {
			continue
		}
		then := single_stmt(src, if_stmt.body) or_continue
		then_value := return_of(then) or_continue
		end := if_stmt.end.offset
		if if_stmt.else_stmt != nil {
			else_stmt := single_stmt(src, if_stmt.else_stmt) or_continue
			else_value := return_of(else_stmt) or_continue
			if else_value == then_value {
				continue
			}
		} else {
			if i + 1 >= len(stmts) {
				continue
			}
			next_value := return_of(stmts[i + 1]) or_continue
			if next_value == then_value {
				continue
			}
			end = stmts[i + 1].end.offset
		}
		cond := node_text(src, if_stmt.cond)
		if !then_value {
			cond = inverted(src, if_stmt.cond) or_continue
		}
		text := strings.concatenate({"return ", cond}, context.temp_allocator)
		append(out, Simplification{if_stmt.pos.offset, end, "bool-return", "Return the condition", text})
	}
}

// invert_condition turns `x < 1` into `x >= 1`, which differs for NaN.
@(private = "file")
inverted :: proc(src: string, cond: ^ast.Expr) -> (string, bool) {
	if bin, is_binary := unparen(cond).derived.(^ast.Binary_Expr); is_binary {
		#partial switch bin.op.kind {
		case .Lt, .Gt, .Lt_Eq, .Gt_Eq:
			return negated(src, cond), true
		}
	}
	return invert_condition(src, cond)
}

@(private = "file")
negated :: proc(src: string, expr: ^ast.Expr) -> string {
	if _, is_binary := expr.derived.(^ast.Binary_Expr); is_binary {
		return strings.concatenate({"!(", node_text(src, expr), ")"}, context.temp_allocator)
	}
	return strings.concatenate({"!", node_text(src, expr)}, context.temp_allocator)
}

@(private = "file")
simplify_bool_compare :: proc(src: string, node: ^ast.Node, _: []^ast.Node, out: ^[dynamic]Simplification) {
	bin, ok := node.derived.(^ast.Binary_Expr)
	if !ok || (bin.op.kind != .Cmp_Eq && bin.op.kind != .Not_Eq) {
		return
	}
	other := bin.right
	value, is_bool := bool_lit(bin.left)
	if !is_bool {
		other = bin.left
		value, is_bool = bool_lit(bin.right)
		if !is_bool {
			return
		}
	}
	title := value ? "Remove comparison with true" : "Remove comparison with false"
	text := value == (bin.op.kind == .Cmp_Eq) ? node_text(src, other) : negated(src, other)
	append(out, Simplification{bin.pos.offset, bin.end.offset, "bool-compare", title, text})
}

@(private = "file")
simplify_double_negation :: proc(src: string, node: ^ast.Node, _: []^ast.Node, out: ^[dynamic]Simplification) {
	not, ok := node.derived.(^ast.Unary_Expr)
	if !ok || not.op.kind != .Not || not.expr == nil {
		return
	}
	text: string
	#partial switch inner in unparen(not.expr).derived {
	case ^ast.Unary_Expr:
		if inner.op.kind != .Not || inner.expr == nil {
			return
		}
		text = node_text(src, inner.expr)
	case ^ast.Binary_Expr:
		op: string
		#partial switch inner.op.kind {
		case .Cmp_Eq:
			op = "!="
		case .Not_Eq:
			op = "=="
		case:
			return
		}
		text = fmt.tprintf("%s %s %s", node_text(src, inner.left), op, node_text(src, inner.right))
	case:
		return
	}
	append(out, Simplification{not.pos.offset, not.end.offset, "double-negation", "Remove double negation", text})
}

@(private = "file")
simplify_bool_ternary :: proc(src: string, node: ^ast.Node, _: []^ast.Node, out: ^[dynamic]Simplification) {
	ternary, ok := node.derived.(^ast.Ternary_If_Expr)
	if !ok {
		return
	}
	x, x_ok := bool_lit(ternary.x)
	y, y_ok := bool_lit(ternary.y)
	if !x_ok || !y_ok || x == y {
		return
	}
	text, ok_text := node_text(src, ternary.cond), true
	if !x {
		text, ok_text = inverted(src, ternary.cond)
	}
	if !ok_text {
		return
	}
	append(
		out,
		Simplification{ternary.pos.offset, ternary.end.offset, "bool-ternary", "Replace ternary with condition", text},
	)
}

// Compound literals and `in` need parentheses where the parser expects a block next.
@(private = "file")
needs_parens :: proc(expr: ^ast.Expr) -> bool {
	found: bool
	visitor := ast.Visitor {
		data = &found,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			#partial switch n in node.derived {
			case ^ast.Comp_Lit:
				(^bool)(visitor.data)^ = true
				return nil
			case ^ast.Binary_Expr:
				if n.op.kind == .In || n.op.kind == .Not_In {
					(^bool)(visitor.data)^ = true
					return nil
				}
			}
			return visitor
		},
	}
	ast.walk(&visitor, expr)
	return found
}

@(private = "file")
simplify_redundant_parens :: proc(src: string, node: ^ast.Node, _: []^ast.Node, out: ^[dynamic]Simplification) {
	exprs: []^ast.Expr
	#partial switch n in node.derived {
	case ^ast.If_Stmt:
		exprs = {n.cond}
	case ^ast.For_Stmt:
		exprs = {n.cond}
	case ^ast.Switch_Stmt:
		exprs = {n.cond}
	case ^ast.When_Stmt:
		exprs = {n.cond}
	case ^ast.Return_Stmt:
		exprs = n.results
	case:
		return
	}
	for expr in exprs {
		if expr == nil {
			continue
		}
		paren, is_paren := expr.derived.(^ast.Paren_Expr)
		if !is_paren || needs_parens(paren.expr) {
			continue
		}
		append(
			out,
			Simplification {
				paren.pos.offset,
				paren.end.offset,
				"redundant-parens",
				"Remove redundant parentheses",
				node_text(src, paren.expr),
			},
		)
	}
}

@(private = "file")
simplify_full_slice :: proc(src: string, node: ^ast.Node, _: []^ast.Node, out: ^[dynamic]Simplification) {
	slice, ok := node.derived.(^ast.Slice_Expr)
	if !ok || (slice.low == nil && slice.high == nil) || contains_call(slice.expr) {
		return
	}
	if slice.low != nil && !is_lit(slice.low, "0") {
		return
	}
	if slice.high != nil {
		call, is_call := slice.high.derived.(^ast.Call_Expr)
		if !is_call || len(call.args) != 1 {
			return
		}
		callee, is_ident := call.expr.derived.(^ast.Ident)
		if !is_ident || callee.name != "len" {
			return
		}
		if strip_space(node_text(src, call.args[0])) != strip_space(node_text(src, slice.expr)) {
			return
		}
	}
	text := strings.concatenate({node_text(src, slice.expr), "[:]"}, context.temp_allocator)
	append(out, Simplification{slice.pos.offset, slice.end.offset, "full-slice", "Use full slice", text})
}

@(private = "file")
simplify_for_true :: proc(src: string, node: ^ast.Node, _: []^ast.Node, out: ^[dynamic]Simplification) {
	loop, ok := node.derived.(^ast.For_Stmt)
	if !ok || loop.init != nil || loop.post != nil || loop.cond == nil || loop.body == nil {
		return
	}
	if value, is_bool := bool_lit(loop.cond); !is_bool || !value {
		return
	}
	// `for ; true; {` has the same AST, but the semicolons would remain.
	head := src[loop.for_pos.offset + len("for"):loop.body.pos.offset]
	if strings.trim_space(head) != "true" {
		return
	}
	append(out, Simplification{loop.for_pos.offset, loop.cond.end.offset, "for-true", "Remove redundant true", "for"})
}

@(private = "file")
simplify_make_zero :: proc(src: string, node: ^ast.Node, _: []^ast.Node, out: ^[dynamic]Simplification) {
	call, ok := node.derived.(^ast.Call_Expr)
	if !ok || len(call.args) != 2 {
		return
	}
	callee, is_ident := call.expr.derived.(^ast.Ident)
	if !is_ident || callee.name != "make" {
		return
	}
	if _, is_dynamic := call.args[0].derived.(^ast.Dynamic_Array_Type); !is_dynamic || !is_lit(call.args[1], "0") {
		return
	}
	text := strings.concatenate({"make(", node_text(src, call.args[0]), ")"}, context.temp_allocator)
	append(out, Simplification{call.pos.offset, call.end.offset, "make-zero", "Remove zero length", text})
}

@(private = "file")
simplify_empty_else :: proc(src: string, node: ^ast.Node, _: []^ast.Node, out: ^[dynamic]Simplification) {
	if_stmt, ok := node.derived.(^ast.If_Stmt)
	if !ok || if_stmt.else_stmt == nil || if_stmt.body == nil {
		return
	}
	block, is_block := if_stmt.else_stmt.derived.(^ast.Block_Stmt)
	if !is_block || block.uses_do || len(block.stmts) != 0 {
		return
	}
	if strings.trim_space(src[block.open.offset + 1:block.close.offset]) != "" {
		return
	}
	append(out, Simplification{if_stmt.body.end.offset, block.end.offset, "empty-else", "Remove empty else", ""})
}

@(private = "file")
simplify_compound_assign :: proc(src: string, node: ^ast.Node, _: []^ast.Node, out: ^[dynamic]Simplification) {
	assign, ok := node.derived.(^ast.Assign_Stmt)
	if !ok {
		return
	}
	text, has_text := compound_assignment_text(src, assign)
	if !has_text {
		return
	}
	append(
		out,
		Simplification{assign.pos.offset, assign.end.offset, "compound-assign", "Use compound assignment", text},
	)
}

@(private = "file")
simplify_nested_if :: proc(src: string, node: ^ast.Node, _: []^ast.Node, out: ^[dynamic]Simplification) {
	if_stmt, ok := node.derived.(^ast.If_Stmt)
	if !ok {
		return
	}
	text, has_text := merge_if_text(src, if_stmt)
	if !has_text {
		return
	}
	append(out, Simplification{if_stmt.pos.offset, if_stmt.end.offset, "nested-if", "Merge nested if", text})
}

@(private = "file")
ident_named :: proc(expr: ^ast.Expr, name: string) -> bool {
	ident, ok := expr.derived.(^ast.Ident)
	return ok && ident.name == name
}

// `i += 1` or `i = i + 1`.
@(private = "file")
is_increment :: proc(stmt: ^ast.Stmt, name: string) -> bool {
	assign, ok := stmt.derived.(^ast.Assign_Stmt)
	if !ok || len(assign.lhs) != 1 || len(assign.rhs) != 1 || !ident_named(assign.lhs[0], name) {
		return false
	}
	#partial switch assign.op.kind {
	case .Add_Eq:
		return is_lit(assign.rhs[0], "1")
	case .Eq:
		bin, is_binary := assign.rhs[0].derived.(^ast.Binary_Expr)
		return is_binary && bin.op.kind == .Add && ident_named(bin.left, name) && is_lit(bin.right, "1")
	}
	return false
}

// A range bound may call `len(y)` on a name or field and nothing else, since it is evaluated once.
@(private = "file")
bound_calls_ok :: proc(expr: ^ast.Expr) -> bool {
	ok := true
	visitor := ast.Visitor {
		data = &ok,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			#partial switch n in node.derived {
			case ^ast.Call_Expr:
				if ident_named(n.expr, "len") && len(n.args) == 1 {
					#partial switch _ in n.args[0].derived {
					case ^ast.Ident, ^ast.Selector_Expr:
						return nil
					}
				}
				(^bool)(visitor.data)^ = false
				return nil
			case ^ast.Selector_Call_Expr:
				(^bool)(visitor.data)^ = false
				return nil
			}
			return visitor
		},
	}
	ast.walk(&visitor, expr)
	return ok
}

@(private = "file")
simplify_range_loop :: proc(src: string, node: ^ast.Node, _: []^ast.Node, out: ^[dynamic]Simplification) {
	loop, ok := node.derived.(^ast.For_Stmt)
	if !ok || loop.init == nil || loop.cond == nil || loop.post == nil || loop.body == nil {
		return
	}
	decl, is_decl := loop.init.derived.(^ast.Value_Decl)
	if !is_decl || !decl.is_mutable || len(decl.names) != 1 || decl.type != nil || len(decl.values) != 1 {
		return
	}
	name, is_ident := decl.names[0].derived.(^ast.Ident)
	if !is_ident || contains_call(decl.values[0]) {
		return
	}
	cond, is_binary := loop.cond.derived.(^ast.Binary_Expr)
	if !is_binary || (cond.op.kind != .Lt && cond.op.kind != .Lt_Eq) || !ident_named(cond.left, name.name) {
		return
	}
	if !bound_calls_ok(cond.right) || !is_increment(loop.post, name.name) {
		return
	}
	bound_names := make(map[string]bool, context.temp_allocator)
	for use in collect_ident_uses(cond.right) {
		bound_names[use.ident.name] = true
	}
	for use in collect_ident_uses(loop.body) {
		if is_write(use) && (use.ident.name == name.name || use.ident.name in bound_names) {
			return
		}
	}
	op := cond.op.kind == .Lt ? "..<" : "..="
	text := fmt.tprintf("for %s in %s%s%s ", name.name, node_text(src, decl.values[0]), op, node_text(src, cond.right))
	append(out, Simplification{loop.for_pos.offset, loop.body.pos.offset, "range-loop", "Use range loop", text})
}

// Names an `if`'s init declares live only inside the statement, so text that mentions
// them cannot be lifted out of it.
@(private = "file")
mentions_any :: proc(node: ^ast.Node, names: ..string) -> bool {
	for use in collect_ident_uses(node) {
		for name in names {
			if use.ident.name == name {
				return true
			}
		}
	}
	return false
}

@(private = "file")
simplify_or_else :: proc(src: string, node: ^ast.Node, _: []^ast.Node, out: ^[dynamic]Simplification) {
	if_stmt, ok := node.derived.(^ast.If_Stmt)
	if !ok || if_stmt.init == nil || if_stmt.else_stmt == nil || if_stmt.label != nil {
		return
	}
	decl, is_decl := if_stmt.init.derived.(^ast.Value_Decl)
	if !is_decl || len(decl.names) != 2 || len(decl.values) != 1 {
		return
	}
	#partial switch _ in decl.values[0].derived {
	case ^ast.Index_Expr, ^ast.Type_Assertion:
	case:
		return
	}
	v, v_ok := decl.names[0].derived.(^ast.Ident)
	flag, flag_ok := decl.names[1].derived.(^ast.Ident)
	if !v_ok || !flag_ok || !ident_named(if_stmt.cond, flag.name) {
		return
	}
	then, then_ok := single_stmt(src, if_stmt.body)
	other, other_ok := single_stmt(src, if_stmt.else_stmt)
	if !then_ok || !other_ok {
		return
	}
	expr := node_text(src, decl.values[0])
	text: string
	#partial switch t in then.derived {
	case ^ast.Return_Stmt:
		o, is_return := other.derived.(^ast.Return_Stmt)
		if !is_return || len(t.results) != 1 || len(o.results) != 1 {
			return
		}
		if !ident_named(t.results[0], v.name) || contains_call(o.results[0]) {
			return
		}
		if mentions_any(o.results[0], v.name, flag.name) {
			return
		}
		text = fmt.tprintf("return %s or_else %s", expr, node_text(src, o.results[0]))
	case ^ast.Assign_Stmt:
		o, is_assign := other.derived.(^ast.Assign_Stmt)
		if !is_assign || !is_single_assign(t) || !is_single_assign(o) {
			return
		}
		if !ident_named(t.rhs[0], v.name) || contains_call(o.rhs[0]) {
			return
		}
		if mentions_any(o.rhs[0], v.name, flag.name) || mentions_any(t.lhs[0], v.name, flag.name) {
			return
		}
		lhs := node_text(src, t.lhs[0])
		if strip_space(lhs) != strip_space(node_text(src, o.lhs[0])) {
			return
		}
		text = fmt.tprintf("%s = %s or_else %s", lhs, expr, node_text(src, o.rhs[0]))
	case:
		return
	}
	append(out, Simplification{if_stmt.pos.offset, if_stmt.end.offset, "or-else", "Use or_else", text})
}

// Result names of a proc in order, "" where unnamed. or_return needs one result or all named.
// The parser gives every unnamed result in a parenthesised list the placeholder name `_`.
@(private = "file")
or_return_results :: proc(lit: ^ast.Proc_Lit) -> ([]string, bool) {
	if lit == nil || lit.type == nil || lit.type.results == nil {
		return nil, false
	}
	names := make([dynamic]string, context.temp_allocator)
	all_named := true
	for field in lit.type.results.list {
		if len(field.names) == 0 {
			append(&names, "")
			all_named = false
		}
		for name in field.names {
			ident, is_ident := name.derived.(^ast.Ident)
			if !is_ident {
				return nil, false
			}
			if ident.name == "_" || ident.name == "" {
				all_named = false
				append(&names, "")
				continue
			}
			append(&names, ident.name)
		}
	}
	return names[:], len(names) == 1 || all_named
}

@(private = "file")
is_zero_result :: proc(expr: ^ast.Expr, named: string) -> bool {
	#partial switch e in expr.derived {
	case ^ast.Comp_Lit:
		return e.type == nil && len(e.elems) == 0
	case ^ast.Basic_Lit:
		return e.tok.text == "0" || e.tok.text == `""`
	case ^ast.Ident:
		return e.name == "nil" || e.name == "false" || (named != "" && e.name == named)
	}
	return false
}

@(private = "file")
simplify_or_return :: proc(src: string, node: ^ast.Node, parents: []^ast.Node, out: ^[dynamic]Simplification) {
	stmts: []^ast.Stmt
	#partial switch n in node.derived {
	case ^ast.Block_Stmt:
		stmts = n.stmts
	case ^ast.Case_Clause:
		stmts = n.body
	case:
		return
	}
	results, results_ok := or_return_results(enclosing_proc(parents))
	if !results_ok {
		return
	}
	for stmt, i in stmts[:max(len(stmts) - 1, 0)] {
		decl, is_decl := stmt.derived.(^ast.Value_Decl)
		if !is_decl || !decl.is_mutable || len(decl.names) == 0 || len(decl.values) != 1 {
			continue
		}
		if _, is_call := decl.values[0].derived.(^ast.Call_Expr); !is_call {
			continue
		}
		err, is_ident := decl.names[len(decl.names) - 1].derived.(^ast.Ident)
		if !is_ident {
			continue
		}
		if_stmt, is_if := stmts[i + 1].derived.(^ast.If_Stmt)
		if !is_if || if_stmt.init != nil || if_stmt.else_stmt != nil || if_stmt.label != nil {
			continue
		}
		last := "nil"
		#partial switch c in if_stmt.cond.derived {
		case ^ast.Binary_Expr:
			if c.op.kind != .Not_Eq || !ident_named(c.left, err.name) || !ident_named(c.right, "nil") {
				continue
			}
			last = err.name
		case ^ast.Unary_Expr:
			if c.op.kind != .Not || c.expr == nil || !ident_named(c.expr, err.name) {
				continue
			}
			last = "false"
		case:
			continue
		}
		then := single_stmt(src, if_stmt.body) or_continue
		ret, is_return := then.derived.(^ast.Return_Stmt)
		if !is_return || len(ret.results) != len(results) || !ident_named(ret.results[len(results) - 1], last) {
			continue
		}
		zero := true
		for result, j in ret.results[:len(results) - 1] {
			zero &&= is_zero_result(result, results[j])
		}
		if !zero {
			continue
		}
		used := false
		for later in stmts[i + 2:] {
			for use in collect_ident_uses(later) {
				used ||= use.ident.name == err.name
			}
		}
		if used {
			continue
		}
		sb := strings.builder_make(context.temp_allocator)
		for name, j in decl.names[:len(decl.names) - 1] {
			strings.write_string(&sb, j > 0 ? ", " : "")
			strings.write_string(&sb, node_text(src, name))
		}
		if len(decl.names) > 1 {
			strings.write_string(&sb, decl.type == nil ? " := " : fmt.tprintf(": %s = ", node_text(src, decl.type)))
		}
		strings.write_string(&sb, node_text(src, decl.values[0]))
		strings.write_string(&sb, " or_return")
		append(
			out,
			Simplification{decl.pos.offset, if_stmt.end.offset, "or-return", "Use or_return", strings.to_string(sb)},
		)
	}
}

@(private = "file")
simplify_redundant_else :: proc(src: string, node: ^ast.Node, _: []^ast.Node, out: ^[dynamic]Simplification) {
	if_stmt, ok := node.derived.(^ast.If_Stmt)
	if !ok || if_stmt.else_stmt == nil || if_stmt.body == nil {
		return
	}
	body, is_block := if_stmt.body.derived.(^ast.Block_Stmt)
	if !is_block || body.uses_do || len(body.stmts) == 0 {
		return
	}
	#partial switch _ in body.stmts[len(body.stmts) - 1].derived {
	case ^ast.Return_Stmt, ^ast.Branch_Stmt:
	case:
		return
	}
	else_block, else_is_block := if_stmt.else_stmt.derived.(^ast.Block_Stmt)
	if !else_is_block || else_block.uses_do || len(else_block.stmts) == 0 {
		return
	}
	declared := make([dynamic]string, context.temp_allocator)
	if if_stmt.init != nil {
		if init, is_decl := if_stmt.init.derived.(^ast.Value_Decl); is_decl {
			for name in init.names {
				if ident, is_ident := name.derived.(^ast.Ident); is_ident {
					append(&declared, ident.name)
				}
			}
		}
	}
	if mentions_any(if_stmt.else_stmt, ..declared[:]) {
		return
	}
	from := get_line_indentation(src, else_block.stmts[0].pos.offset)
	to := get_line_indentation(src, if_stmt.pos.offset)
	text := fmt.tprintf("\n%s", reindent(block_inner_text(src, else_block), from, to))
	append(
		out,
		Simplification {
			if_stmt.body.end.offset,
			else_block.end.offset,
			"redundant-else",
			"Remove redundant else",
			text,
		},
	)
}

@(private = "file")
simplify_trailing_return :: proc(src: string, node: ^ast.Node, _: []^ast.Node, out: ^[dynamic]Simplification) {
	lit, ok := node.derived.(^ast.Proc_Lit)
	if !ok || lit.type == nil || lit.type.results != nil || lit.body == nil {
		return
	}
	body, is_block := lit.body.derived.(^ast.Block_Stmt)
	if !is_block || len(body.stmts) == 0 {
		return
	}
	ret, is_return := body.stmts[len(body.stmts) - 1].derived.(^ast.Return_Stmt)
	if !is_return || len(ret.results) != 0 {
		return
	}
	start := ret.pos.offset
	for start > 0 && src[start - 1] != '\n' {
		start -= 1
	}
	if strings.trim_space(src[start:ret.pos.offset]) != "" {
		start = ret.pos.offset
	}
	// Take the trailing newline, so the whole line goes; leave it when a comment follows.
	end := ret.end.offset
	for end < len(src) && (src[end] == ' ' || src[end] == '\t' || src[end] == '\r') {
		end += 1
	}
	if end < len(src) && src[end] == '\n' {
		end += 1
	} else {
		end = ret.end.offset
	}
	append(out, Simplification{start, end, "trailing-return", "Remove trailing return", ""})
}
