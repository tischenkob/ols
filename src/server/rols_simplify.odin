package server

import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:slice"
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
	simplify_or_break,
	simplify_or_continue,
	simplify_redundant_else,
	simplify_trailing_return,
}

// The code each entry of rules reports, in the same order; a test keeps the two in step and
// checks that modernize registers every code.
SIMPLIFY_CODES :: [?]string {
	"array-broadcast",
	"bool-return",
	"bool-compare",
	"double-negation",
	"bool-ternary",
	"redundant-parens",
	"full-slice",
	"for-true",
	"make-zero",
	"empty-else",
	"compound-assign",
	"nested-if",
	"range-loop",
	"or-else",
	"or-return",
	"or-break",
	"or-continue",
	"redundant-else",
	"trailing-return",
}

simplify_rule_count :: proc() -> int {
	return len(rules)
}

// Every rule is syntactic; none resolves a symbol, except that bool-compare is skipped on a non-bool
// operand and nested-if on a condition that calls a deferred procedure. Results are in walk order.
simplifications :: proc(document: ^Document) -> []Simplification {
	Walker :: struct {
		document: ^Document,
		src:      string,
		stack:    [dynamic]^ast.Node,
		out:      [dynamic]Simplification,
		types:    Lazy_Context,
	}
	w := Walker {
		document = document,
		src      = document.ast.src,
		stack    = make([dynamic]^ast.Node, context.temp_allocator),
		out      = make([dynamic]Simplification, context.temp_allocator),
	}
	w.types.document = document
	visitor := ast.Visitor {
		data = &w,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			w := (^Walker)(visitor.data)
			if node == nil {
				pop(&w.stack)
				return nil
			}
			for rule in rules {
				// rols: dropping `== true` must not change the type of the expression.
				if rule == simplify_bool_compare && compares_non_bool(&w.types, node, w.stack[:]) do continue
				// rols: merging would put a call with a deferred procedure inside `&&`.
				if rule == simplify_nested_if && merge_calls_deferred(w.document, node) do continue
				rule(w.src, node, w.stack[:], &w.out)
			}
			append(&w.stack, node)
			return visitor
		},
	}
	for decl in document.ast.decls {
		ast.walk(&visitor, decl)
	}
	// rols: a rewrite rebuilds its range from node text, so a comment inside would be lost.
	// redundant-else and nested-if copy their inner source, comments included, and refuse the
	// comments they would drop themselves.
	kept := make([dynamic]Simplification, 0, len(w.out), context.temp_allocator)
	for s in w.out {
		copies_source := s.code == "redundant-else" || s.code == "nested-if"
		if !copies_source && len(comments_overlapping(document.ast, s.start, s.end)) > 0 do continue
		append(&kept, s)
	}
	return kept[:]
}

simplification_message :: proc(s: Simplification) -> string {
	text := s.text
	if i := strings.index_byte(text, '\n'); i >= 0 {
		text = text[:i]
	}
	text = strings.trim_space(text)
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
		// A @(rodata) variable needs a constant initializer, and a broadcast scalar is not one.
		if len(n.names) != 1 || len(n.values) != 1 || has_attribute(n.attributes[:], "rodata") {
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

// A context without locals for the document, built when a rule first resolves a type.
@(private = "file")
Lazy_Context :: struct {
	document:    ^Document,
	ast_context: AstContext,
	built:       bool,
}

@(private = "file")
lazy_context :: proc(l: ^Lazy_Context) -> ^AstContext {
	if !l.built {
		d := l.document
		l.ast_context = package_ast_context(d.ast, d.imports, d.package_name, d.uri.uri, d.fullpath, d.package_name)
		l.built = true
	}
	return &l.ast_context
}

// `x == true` where x has a boolean type other than bool: without the comparison the result
// is a b32 or a distinct bool, which a bool context rejects. A condition accepts any boolean type.
// An index or a dereference whose operand does not resolve is treated as non-bool.
@(private = "file")
compares_non_bool :: proc(types: ^Lazy_Context, node: ^ast.Node, parents: []^ast.Node) -> bool {
	document := types.document
	bin := node.derived.(^ast.Binary_Expr) or_return
	if bin.op.kind != .Cmp_Eq && bin.op.kind != .Not_Eq do return false
	if len(parents) > 0 {
		#partial switch p in parents[len(parents) - 1].derived {
		case ^ast.If_Stmt:
			if rawptr(p.cond) == rawptr(node) do return false
		case ^ast.For_Stmt:
			if rawptr(p.cond) == rawptr(node) do return false
		case ^ast.Ternary_If_Expr:
			if rawptr(p.cond) == rawptr(node) do return false
		}
	}
	other := bin.right
	if _, is_bool := bool_lit(bin.left); !is_bool {
		other = bin.left
		if _, is_bool = bool_lit(bin.right); !is_bool do return false
	}
	other = ast.unparen_expr(other)

	symbol: Symbol
	#partial switch e in other.derived {
	case ^ast.Ident, ^ast.Selector_Expr:
		resolved := resolve_entire_file(document)[uintptr(other)] or_return
		if resolved.is_unresolved do return false
		symbol = resolved.symbol^
	case ^ast.Call_Expr:
		resolved := resolve_entire_file(document)[uintptr(e.expr)] or_return
		if resolved.is_unresolved do return false
		callee := resolved.symbol.value.(SymbolProcedureValue) or_return
		// The instantiated result is what the call site sees.
		if len(callee.return_types) != 1 || len(callee.return_types[0].names) > 1 do return false
		symbol = resolve_type_with(lazy_context(types), resolved.symbol.pkg, callee.return_types[0].type) or_return
	case ^ast.Index_Expr:
		base, found := resolve_entire_file(document)[uintptr(ast.unparen_expr(e.expr))]
		if !found || base.is_unresolved do return true
		elem: ^ast.Expr
		#partial switch v in base.symbol.value {
		case SymbolSliceValue:
			elem = v.expr
		case SymbolDynamicArrayValue:
			elem = v.expr
		case SymbolFixedArrayValue:
			elem = v.expr
		case SymbolMultiPointerValue:
			elem = v.expr
		case SymbolMapValue:
			elem = v.value
		}
		if elem == nil || .Soa in base.symbol.flags do return true
		found_elem: bool
		symbol, found_elem = resolve_type_with(lazy_context(types), base.symbol.pkg, elem)
		if !found_elem do return true
	case ^ast.Deref_Expr:
		operand, found := resolve_entire_file(document)[uintptr(ast.unparen_expr(e.expr))]
		if !found || operand.is_unresolved || operand.symbol.pointers < 1 do return true
		symbol = operand.symbol^
		symbol.pointers -= 1
	case:
		return false
	}

	if symbol.pointers > 0 do return false
	basic, is_basic := symbol.value.(SymbolBasicValue)
	if !is_basic || basic.ident == nil || !slice.contains(untyped_map[.Bool], basic.ident.name) do return false
	return basic.ident.name != "bool" || .Distinct in symbol.flags
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
		// rols: parentheses that span lines hold the layout of a wrapped condition; removing them
		// leaves a brace or a blank line out of place.
		if strings.contains_any(node_text(src, paren), "\r\n") {
			continue
		}
		// `return(x)` and `if(x)do` need a space once the parenthesis goes.
		text := node_text(src, paren.expr)
		if start := paren.pos.offset; start > 0 && is_word_byte(src[start - 1]) {
			text = strings.concatenate({" ", text}, context.temp_allocator)
		}
		if end := paren.end.offset; end < len(src) && is_word_byte(src[end]) {
			text = strings.concatenate({text, " "}, context.temp_allocator)
		}
		append(
			out,
			Simplification {
				paren.pos.offset,
				paren.end.offset,
				"redundant-parens",
				"Remove redundant parentheses",
				text,
			},
		)
	}
}

@(private = "file")
is_word_byte :: proc(c: u8) -> bool {
	return tokenizer.is_letter(rune(c)) || tokenizer.is_digit(rune(c))
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
simplify_range_loop :: proc(src: string, node: ^ast.Node, parents: []^ast.Node, out: ^[dynamic]Simplification) {
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
	// A range reads its bound once. A call in the body may change a bound that calls or reads
	// anything but the procedure's own locals, such as len(queue) while the body appends.
	if contains_call(loop.body) && !local_expr(cond.right, enclosing_proc(parents), loop) {
		return
	}
	// The C-style loop reads its variable in the condition; a range loop whose body never reads it
	// names it `_`, or `odin check -vet-unused-variables` rejects it. A literal field named like the
	// variable may be a map key that reads it, so neither name is safe.
	reads, unsure := reads_name(loop.body, name.name)
	if !reads && unsure {
		return
	}
	// Spaced, as odinfmt prints a range.
	op := cond.op.kind == .Lt ? "..<" : "..="
	text := fmt.tprintf(
		"for %s in %s %s %s %s",
		reads ? name.name : "_",
		node_text(src, decl.values[0]),
		op,
		node_text(src, cond.right),
		do_keyword(loop.body),
	)
	append(out, Simplification{loop.for_pos.offset, loop.body.pos.offset, "range-loop", "Use range loop", text})
}

// Any identifier named name in root outside nested procedure literals, which cannot see the
// locals around them. A declaration of the name counts too, which is conservative. unsure reports
// a compound literal field named name, which reads it only when the literal is a map.
@(private = "file")
reads_name :: proc(root: ^ast.Node, name: string) -> (found, unsure: bool) {
	Search :: struct {
		name:          string,
		found, unsure: bool,
	}
	search := Search{name, false, false}
	visitor := ast.Visitor {
		data = &search,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			search := (^Search)(visitor.data)
			#partial switch n in node.derived {
			case ^ast.Proc_Lit, ^ast.Implicit_Selector_Expr:
				return nil
			case ^ast.Ident:
				if n.name == search.name do search.found = true
			case ^ast.Selector_Expr:
				// The field after the dot names a member, not a variable.
				ast.walk(visitor, n.expr)
				return nil
			case ^ast.Comp_Lit:
				// A struct field name is not a read, but a map key is. Only a written map type
				// shows which one a field is; a named or inferred type leaves it unsure.
				if n.type != nil {
					if _, is_map := n.type.derived.(^ast.Map_Type); is_map do break
				}
				ast.walk(visitor, n.type)
				for elem in n.elems {
					field, is_field := elem.derived.(^ast.Field_Value)
					if !is_field {
						ast.walk(visitor, elem)
						continue
					}
					if ident_named(field.field, search.name) do search.unsure = true
					if _, is_ident := field.field.derived.(^ast.Ident); !is_ident do ast.walk(visitor, field.field)
					ast.walk(visitor, field.value)
				}
				return nil
			}
			return visitor
		},
	}
	ast.walk(&visitor, root)
	return search.found, search.unsure
}

// Names an `if`'s init declares live only inside the statement, so text that mentions
// them cannot be lifted out of it.
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

// mentions_any without field names after a selector and enum members after a dot, which a
// declaration cannot shadow. A field name in a literal still counts, since it may be a map key.
@(private = "file")
mentions_variable :: proc(node: ^ast.Node, names: []string) -> bool {
	for use in collect_ident_uses(node) {
		if len(use.parents) > 0 {
			#partial switch p in use.parents[len(use.parents) - 1].derived {
			case ^ast.Selector_Expr:
				if p.field == use.ident do continue
			case ^ast.Implicit_Selector_Expr:
				continue
			}
		}
		for name in names {
			if use.ident.name == name do return true
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

// A write of name that can run before at: earlier in the text, or in a loop around at.
@(private = "file")
written_before :: proc(writes: []IdentUse, name: string, at: ^ast.Node) -> bool {
	for use in writes {
		if use.ident.name != name do continue
		if use.ident.pos.offset < at.pos.offset do return true
		for parent in use.parents {
			#partial switch _ in parent.derived {
			case ^ast.For_Stmt, ^ast.Range_Stmt, ^ast.Inline_Range_Stmt:
				if parent.pos.offset <= at.pos.offset && at.end.offset <= parent.end.offset do return true
			}
		}
	}
	return false
}

// Built only from literals, private locals and len of a private local array, which a call in
// the loop body cannot change.
@(private = "file")
local_expr :: proc(expr: ^ast.Expr, lit: ^ast.Proc_Lit, loop: ^ast.Node) -> bool {
	if lit == nil do return false
	#partial switch e in expr.derived {
	case ^ast.Basic_Lit:
		return true
	case ^ast.Ident:
		_, _, ok := private_local(lit, e.name, loop)
		return ok
	case ^ast.Call_Expr:
		if !ident_named(e.expr, "len") || len(e.args) != 1 do return false
		arg := e.args[0].derived.(^ast.Ident) or_return
		type, value := private_local(lit, arg.name, loop) or_return
		return is_array_value(type, value)
	case ^ast.Paren_Expr:
		return local_expr(e.expr, lit, loop)
	case ^ast.Unary_Expr:
		return local_expr(e.expr, lit, loop)
	case ^ast.Binary_Expr:
		return local_expr(e.left, lit, loop) && local_expr(e.right, lit, loop)
	}
	return false
}

// len dereferences one pointer level, so only a declaration that shows an array, not a pointer
// or a named type, keeps its length away from a call.
@(private = "file")
is_array_value :: proc(type, value: ^ast.Expr) -> bool {
	if type != nil {
		#partial switch _ in type.derived {
		case ^ast.Array_Type, ^ast.Dynamic_Array_Type:
			return true
		}
		return false
	}
	if value == nil do return false
	#partial switch v in value.derived {
	case ^ast.Comp_Lit, ^ast.Slice_Expr:
		return true
	case ^ast.Call_Expr:
		return ident_named(v.expr, "make")
	}
	return false
}

// The type and value of name when exactly one declaration of lit is in scope at loop: a parameter
// or result, or a body declaration before loop whose scope contains loop, outside nested
// procedures. lit must never take its address.
@(private = "file")
private_local :: proc(lit: ^ast.Proc_Lit, name: string, loop: ^ast.Node) -> (type, value: ^ast.Expr, ok: bool) {
	if lit.body == nil do return
	count := 0
	if lit.type != nil {
		for list in ([]^ast.Field_List{lit.type.params, lit.type.results}) {
			if list == nil do continue
			for field in list.list {
				for n in field.names {
					if !ident_named(n, name) do continue
					count += 1
					type = field.type
				}
			}
		}
	}

	Search :: struct {
		name:  string,
		loop:  ^ast.Node,
		stack: [dynamic]^ast.Node,
		count: int,
		decl:  ^ast.Value_Decl,
		index: int,
	}
	search := Search {
		name  = name,
		loop  = loop,
		stack = make([dynamic]^ast.Node, context.temp_allocator),
	}
	visitor := ast.Visitor {
		data = &search,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			search := (^Search)(visitor.data)
			if node == nil {
				pop(&search.stack)
				return nil
			}
			// Range, #unroll and type switch variables are never arrays by declaration, so
			// counting them is enough to refuse the bound when they shadow.
			encloses_loop := node.pos.offset <= search.loop.pos.offset && search.loop.end.offset <= node.end.offset
			#partial switch n in node.derived {
			case ^ast.Proc_Lit:
				return nil
			case ^ast.Value_Decl:
				// A `when` body opens no scope: its declarations belong to the enclosing one.
				at := len(search.stack) - 1
				for at > 0 {
					_, is_when := search.stack[at].derived.(^ast.When_Stmt)
					_, parent_when := search.stack[at - 1].derived.(^ast.When_Stmt)
					if !is_when && !parent_when do break
					at -= 1
				}
				scope := search.stack[at]
				in_scope :=
					n.end.offset <= search.loop.pos.offset &&
					scope.pos.offset <= search.loop.pos.offset &&
					search.loop.end.offset <= scope.end.offset
				for name, i in n.names {
					if !in_scope || !ident_named(name, search.name) do continue
					search.count += 1
					search.decl, search.index = n, i
				}
			case ^ast.Range_Stmt:
				if encloses_loop do for v in n.vals do if ident_named(v, search.name) do search.count += 1
			case ^ast.Inline_Range_Stmt:
				if encloses_loop do for v in ([]^ast.Expr{n.val0, n.val1}) do if v != nil && ident_named(v, search.name) do search.count += 1
			case ^ast.Type_Switch_Stmt:
				if tag, is_assign := n.tag.derived.(^ast.Assign_Stmt); is_assign && encloses_loop {
					for v in tag.lhs do if ident_named(v, search.name) do search.count += 1
				}
			}
			append(&search.stack, node)
			return visitor
		},
	}
	append(&search.stack, lit.body)
	ast.walk(&visitor, lit.body)

	count += search.count
	if count != 1 do return nil, nil, false
	if decl := search.decl; decl != nil {
		type = decl.type
		if len(decl.values) == len(decl.names) do value = decl.values[search.index]
	}
	for use in collect_ident_uses(lit.body) {
		if use.ident.name == name && is_write(use) && address_taken(use) do return nil, nil, false
	}
	return type, value, true
}

// or_return returns the current value of a named result, so a zero literal stands for it only
// while the procedure never writes it.
@(private = "file")
is_zero_result :: proc(expr: ^ast.Expr, named: string, writes: []IdentUse, at: ^ast.Node) -> bool {
	if named != "" && (ident_named(expr, named) || written_before(writes, named, at)) {
		return ident_named(expr, named)
	}
	#partial switch e in expr.derived {
	case ^ast.Comp_Lit:
		return e.type == nil && len(e.elems) == 0
	case ^ast.Basic_Lit:
		return e.tok.text == "0" || e.tok.text == `""`
	case ^ast.Ident:
		return e.name == "nil" || e.name == "false"
	}
	return false
}

// The statements of a block or a switch case.
@(private = "file")
block_stmts :: proc(node: ^ast.Node) -> []^ast.Stmt {
	#partial switch n in node.derived {
	case ^ast.Block_Stmt:
		return n.stmts
	case ^ast.Case_Clause:
		return n.body
	}
	return nil
}

// stmts[i] declares the results of a call, and stmts[i + 1] is an `if` with no init, else or
// label that tests the last name as `!ok` or `err != nil`. bool_test is true for `!ok`.
@(private = "file")
checked_call :: proc(
	stmts: []^ast.Stmt,
	i: int,
) -> (
	decl: ^ast.Value_Decl,
	check: ^ast.Ident,
	if_stmt: ^ast.If_Stmt,
	bool_test: bool,
	ok: bool,
) {
	decl = stmts[i].derived.(^ast.Value_Decl) or_return
	if !decl.is_mutable || len(decl.names) == 0 || len(decl.values) != 1 {
		return
	}
	_ = decl.values[0].derived.(^ast.Call_Expr) or_return
	check = decl.names[len(decl.names) - 1].derived.(^ast.Ident) or_return
	if_stmt = stmts[i + 1].derived.(^ast.If_Stmt) or_return
	if if_stmt.init != nil || if_stmt.else_stmt != nil || if_stmt.label != nil {
		return
	}
	#partial switch c in if_stmt.cond.derived {
	case ^ast.Binary_Expr:
		if c.op.kind != .Not_Eq || !ident_named(c.left, check.name) || !ident_named(c.right, "nil") {
			return
		}
	case ^ast.Unary_Expr:
		if c.op.kind != .Not || c.expr == nil || !ident_named(c.expr, check.name) {
			return
		}
		bool_test = true
	case:
		return
	}
	return decl, check, if_stmt, bool_test, true
}

@(private = "file")
mentioned_in :: proc(stmts: []^ast.Stmt, name: string) -> bool {
	for stmt in stmts {
		if mentions_any(stmt, name) do return true
	}
	return false
}

// decl without its last name, its value followed by suffix: `a, b := f() or_return`. Odin rejects
// `_ := …` as declaring nothing, so names that are all `_` assign instead.
@(private = "file")
or_text :: proc(src: string, decl: ^ast.Value_Decl, suffix: string) -> string {
	sb := strings.builder_make(context.temp_allocator)
	all_blank := true
	for name, j in decl.names[:len(decl.names) - 1] {
		strings.write_string(&sb, j > 0 ? ", " : "")
		strings.write_string(&sb, node_text(src, name))
		all_blank &&= ident_named(name, "_")
	}
	if len(decl.names) > 1 && all_blank {
		strings.write_string(&sb, " = ")
	} else if len(decl.names) > 1 {
		strings.write_string(&sb, decl.type == nil ? " := " : fmt.tprintf(": %s = ", node_text(src, decl.type)))
	}
	strings.write_string(&sb, node_text(src, decl.values[0]))
	strings.write_string(&sb, " ")
	strings.write_string(&sb, suffix)
	return strings.to_string(sb)
}

@(private = "file")
simplify_or_return :: proc(src: string, node: ^ast.Node, parents: []^ast.Node, out: ^[dynamic]Simplification) {
	stmts := block_stmts(node)
	if len(stmts) < 2 {
		return
	}
	lit := enclosing_proc(parents)
	results, results_ok := or_return_results(lit)
	if !results_ok {
		return
	}
	writes := make([dynamic]IdentUse, context.temp_allocator)
	for use in collect_ident_uses(lit.body) {
		if is_write(use) do append(&writes, use)
	}
	for i in 0 ..< len(stmts) - 1 {
		decl, err, if_stmt, bool_test := checked_call(stmts, i) or_continue
		last := bool_test ? "false" : err.name
		then := single_stmt(src, if_stmt.body) or_continue
		ret, is_return := then.derived.(^ast.Return_Stmt)
		if !is_return || len(ret.results) != len(results) || !ident_named(ret.results[len(results) - 1], last) {
			continue
		}
		zero := true
		for result, j in ret.results[:len(results) - 1] {
			zero &&= is_zero_result(result, results[j], writes[:], if_stmt)
		}
		if !zero || mentioned_in(stmts[i + 2:], err.name) {
			continue
		}
		append(
			out,
			Simplification {
				decl.pos.offset,
				if_stmt.end.offset,
				"or-return",
				"Use or_return",
				or_text(src, decl, "or_return"),
			},
		)
	}
}

// Without a label, break leaves the innermost loop or switch and continue the innermost loop.
// or_break and or_continue bind the same way but are invalid in an #unroll loop.
@(private = "file")
binds_like_branch :: proc(parents: []^ast.Node, kind: tokenizer.Token_Kind) -> bool {
	#reverse for parent in parents {
		#partial switch _ in parent.derived {
		case ^ast.Proc_Lit, ^ast.Inline_Range_Stmt:
			return false
		case ^ast.For_Stmt, ^ast.Range_Stmt:
			return true
		case ^ast.Switch_Stmt, ^ast.Type_Switch_Stmt:
			if kind == .Break do return true
		}
	}
	return false
}

// `v, ok := f()` then `if !ok { break }` is `v := f() or_break`; continue and a label carry over.
// The checked name disappears, so nothing after the `if` may mention it.
@(private = "file")
or_branch :: proc(
	src: string,
	node: ^ast.Node,
	parents: []^ast.Node,
	out: ^[dynamic]Simplification,
	kind: tokenizer.Token_Kind,
	code, title, keyword: string,
) {
	stmts := block_stmts(node)
	for i in 0 ..< max(len(stmts) - 1, 0) {
		decl, check, if_stmt, _ := checked_call(stmts, i) or_continue
		then := single_stmt(src, if_stmt.body) or_continue
		branch, is_branch := then.derived.(^ast.Branch_Stmt)
		if !is_branch || branch.tok.kind != kind || mentioned_in(stmts[i + 2:], check.name) {
			continue
		}
		suffix := keyword
		if branch.label != nil {
			suffix = fmt.tprintf("%s %s", keyword, branch.label.name)
		} else if !binds_like_branch(parents, kind) {
			continue
		}
		append(out, Simplification{decl.pos.offset, if_stmt.end.offset, code, title, or_text(src, decl, suffix)})
	}
}

@(private = "file")
simplify_or_break :: proc(src: string, node: ^ast.Node, parents: []^ast.Node, out: ^[dynamic]Simplification) {
	or_branch(src, node, parents, out, .Break, "or-break", "Use or_break", "or_break")
}

@(private = "file")
simplify_or_continue :: proc(src: string, node: ^ast.Node, parents: []^ast.Node, out: ^[dynamic]Simplification) {
	or_branch(src, node, parents, out, .Continue, "or-continue", "Use or_continue", "or_continue")
}

append_decl_names :: proc(names: ^[dynamic]string, stmt: ^ast.Stmt) {
	if stmt == nil do return
	decl, is_decl := stmt.derived.(^ast.Value_Decl)
	if !is_decl do return
	for name in decl.names {
		if ident, is_ident := name.derived.(^ast.Ident); is_ident {
			append(names, ident.name)
		}
	}
}

@(private = "file")
simplify_redundant_else :: proc(src: string, node: ^ast.Node, parents: []^ast.Node, out: ^[dynamic]Simplification) {
	if_stmt, ok := node.derived.(^ast.If_Stmt)
	if !ok do return
	if s, found := redundant_else(src, if_stmt, parents); found {
		append(out, s)
	}
}

// The rewrite that drops the else of if_stmt, shared by the rule and the "Remove redundant else"
// action so the two cannot drift. parents run from the outermost node down to the if's parent.
redundant_else :: proc(src: string, if_stmt: ^ast.If_Stmt, parents: []^ast.Node) -> (s: Simplification, ok: bool) {
	node := (^ast.Node)(if_stmt)
	if if_stmt.else_stmt == nil || if_stmt.body == nil || if_stmt.label != nil || len(parents) == 0 {
		return
	}
	// The unwrapped else lands right after the if, so the if must be a statement of a plain
	// block: not the else of an outer if and not a `do` body. A `when` body opens no scope, so
	// its declarations and defers would leak into the outer block.
	siblings: []^ast.Stmt
	#partial switch parent in parents[len(parents) - 1].derived {
	case ^ast.Block_Stmt:
		in_when := false
		if len(parents) >= 2 {
			_, in_when = parents[len(parents) - 2].derived.(^ast.When_Stmt)
		}
		if !parent.uses_do && !in_when do siblings = parent.stmts
	case ^ast.Case_Clause:
		siblings = parent.body
	}
	at := -1
	for sibling, i in siblings {
		if sibling == node do at = i
	}
	if at < 0 {
		return
	}
	body, is_block := if_stmt.body.derived.(^ast.Block_Stmt)
	if !is_block || body.uses_do || len(body.stmts) == 0 {
		return
	}
	#partial switch last in body.stmts[len(body.stmts) - 1].derived {
	case ^ast.Return_Stmt:
	case ^ast.Branch_Stmt:
		if last.tok.kind != .Break && last.tok.kind != .Continue {
			return
		}
	case:
		return
	}
	else_block, else_is_block := if_stmt.else_stmt.derived.(^ast.Block_Stmt)
	if !else_is_block || else_block.uses_do || len(else_block.stmts) == 0 {
		return
	}
	// rols: the replaced range starts at the end of the then block, so a comment before `else` goes too.
	if strings.trim_space(src[if_stmt.body.end.offset:else_block.pos.offset]) != "else" {
		return
	}
	declared := make([dynamic]string, context.temp_allocator)
	append_decl_names(&declared, if_stmt.init)
	if mentions_any(if_stmt.else_stmt, ..declared[:]) {
		return
	}
	// The else's declarations move into the enclosing block, where another statement may
	// declare or use the name, or a using statement may bring it in. Its defers would run at the
	// end of that block, so after the statements that follow the if.
	followed := at < len(siblings) - 1
	// An else that ends the flow leaves the statements after the if unreachable already.
	// Unwrapping it would put them right after its terminator, which `odin check` rejects.
	if followed && terminates(else_block.stmts[len(else_block.stmts) - 1]) {
		return
	}
	clear(&declared)
	for stmt in else_block.stmts {
		// Declarations in a when body or brought in by using land in the else's scope too.
		#partial switch _ in stmt.derived {
		case ^ast.When_Stmt, ^ast.Using_Stmt:
			return
		case ^ast.Defer_Stmt:
			if followed do return
		}
		append_decl_names(&declared, stmt)
	}
	if len(declared) > 0 {
		for stmt, i in siblings {
			if i == at do continue
			_, is_using := stmt.derived.(^ast.Using_Stmt)
			if is_using || mentions_variable(stmt, declared[:]) {
				return
			}
		}
	}
	from := get_line_indentation(src, else_block.stmts[0].pos.offset)
	to := get_line_indentation(src, if_stmt.pos.offset)
	text := fmt.tprintf("\n%s", reindent(block_inner_text(src, else_block), from, to))
	s = Simplification{if_stmt.body.end.offset, else_block.end.offset, "redundant-else", "Remove redundant else", text}
	return s, true
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
