#+private file

package server

import "core:odin/ast"
import "core:slice"
import "core:strings"

// A syntactic matcher of an Odin pattern tree against code. The use_stdlib lint and the modernize
// recipes share it. Parentheses never matter: both sides are unwrapped before every comparison.
@(private = "package")
Pattern_Matcher :: struct {
	src:                string, // code text
	vars:               []string, // metavariable names: each binds one code expression
	// Metavariables that may bind an expression containing a call. A rewrite may evaluate any
	// other binding a different number of times than the code does.
	call_vars:          []string,
	// When set, or_return, or_break and or_continue count as calls: they can leave the procedure
	// or loop, so a rewrite must not drop or repeat them either.
	guard_control_flow: bool,
	bound:              map[string]bool, // names the pattern declares; they match any code name
	// When set, a `return x` pattern also matches `<lhs> = x`, and every such return of one match
	// shares the lhs. form tells which of the two matched.
	return_as_assign:   bool,
	// When set, a `pkg.name` pattern with a plain pkg matches only a code selector whose left side
	// names one of imports with last path segment pkg, so aliased imports match too. The caller
	// checks that no local declaration shadows the import.
	match_imports:      bool,
	imports:            []^ast.Import_Decl, // the imports of the code file
	// Results of the last match. Clear them with pattern_reset before each attempt.
	binds:              map[string]^ast.Node, // metavariable -> code expression
	names:              map[string]string, // pattern-local name -> code name
	qualifiers:         map[string]string, // pattern package qualifier -> code import name
	form:               Pattern_Return_Form,
	target:             ^ast.Node, // assignment target shared by every `return` of the match
	// The first pattern node of a kind pattern_match has no case for. A pattern that matches
	// itself without setting it uses only supported kinds; the switch is the one list of them.
	unsupported:        ^ast.Node,
}

@(private = "package")
Pattern_Return_Form :: enum {
	None,
	Return,
	Assign,
}

// The maps live in allocator; the slices and src stay owned by the caller.
@(private = "package")
pattern_matcher_make :: proc(src: string, allocator := context.temp_allocator) -> Pattern_Matcher {
	return {
		src = src,
		binds = make(map[string]^ast.Node, allocator),
		names = make(map[string]string, allocator),
		qualifiers = make(map[string]string, allocator),
	}
}

@(private = "package")
pattern_reset :: proc(m: ^Pattern_Matcher) {
	clear(&m.binds)
	clear(&m.names)
	clear(&m.qualifiers)
	m.form = .None
	m.target = nil
	m.unsupported = nil
}

@(private = "package")
pattern_unparen :: proc(node: ^ast.Node) -> ^ast.Node {
	node := node
	for {
		paren, ok := node.derived.(^ast.Paren_Expr)
		if !ok do return node
		node = paren.expr
	}
}

// The pattern statements match code statement by statement; the lengths must agree.
@(private = "package")
pattern_match_stmts :: proc(m: ^Pattern_Matcher, pattern, code: []^ast.Stmt) -> bool {
	if len(pattern) != len(code) do return false
	for stmt, i in pattern {
		if !pattern_match(m, stmt, code[i]) do return false
	}
	return true
}

@(private = "package")
pattern_match :: proc(m: ^Pattern_Matcher, pattern, code: ^ast.Node) -> bool {
	if pattern == nil || code == nil do return pattern == nil && code == nil

	pattern, code := pattern_unparen(pattern), pattern_unparen(code)

	#partial switch p in pattern.derived {
	case ^ast.Ident:
		if slice.contains(m.vars, p.name) {
			if bound, seen := m.binds[p.name]; seen {
				return same_node_text(m.src, bound, code)
			}
			if !slice.contains(m.call_vars, p.name) && pattern_has_effect(code, m.guard_control_flow) do return false
			m.binds[p.name] = code
			return true
		}
		c, is_ident := code.derived.(^ast.Ident)
		if !is_ident do return false
		if p.name in m.bound {
			if name, seen := m.names[p.name]; seen {
				return name == c.name
			}
			m.names[p.name] = c.name
			return true
		}
		return p.name == c.name

	case ^ast.Basic_Lit:
		c, ok := code.derived.(^ast.Basic_Lit)
		return ok && p.tok.text == c.tok.text

	case ^ast.Unary_Expr:
		c, ok := code.derived.(^ast.Unary_Expr)
		return ok && p.op.kind == c.op.kind && pattern_match(m, p.expr, c.expr)

	case ^ast.Binary_Expr:
		c, ok := code.derived.(^ast.Binary_Expr)
		return ok && p.op.kind == c.op.kind && pattern_match(m, p.left, c.left) && pattern_match(m, p.right, c.right)

	case ^ast.Selector_Expr:
		c, ok := code.derived.(^ast.Selector_Expr)
		if !ok || p.field == nil || c.field == nil || p.field.name != c.field.name do return false
		if matched, decided := match_qualifier(m, p.expr, c.expr); decided do return matched
		return pattern_match(m, p.expr, c.expr)

	case ^ast.Implicit:
		c, ok := code.derived.(^ast.Implicit)
		return ok && p.tok.kind == c.tok.kind

	case ^ast.Type_Assertion:
		c, ok := code.derived.(^ast.Type_Assertion)
		return ok && pattern_match(m, p.expr, c.expr) && pattern_match(m, p.type, c.type)

	case ^ast.Implicit_Selector_Expr:
		c, ok := code.derived.(^ast.Implicit_Selector_Expr)
		return ok && p.field != nil && c.field != nil && p.field.name == c.field.name

	case ^ast.Index_Expr:
		c, ok := code.derived.(^ast.Index_Expr)
		return ok && pattern_match(m, p.expr, c.expr) && pattern_match(m, p.index, c.index)

	case ^ast.Slice_Expr:
		c, ok := code.derived.(^ast.Slice_Expr)
		if !ok || (p.low == nil) != (c.low == nil) || (p.high == nil) != (c.high == nil) do return false
		return pattern_match(m, p.expr, c.expr) && pattern_match(m, p.low, c.low) && pattern_match(m, p.high, c.high)

	case ^ast.Call_Expr:
		c, ok := code.derived.(^ast.Call_Expr)
		if !ok || len(p.args) != len(c.args) || !pattern_match(m, p.expr, c.expr) do return false
		return match_exprs(m, p.args, c.args)

	case ^ast.Comp_Lit:
		c, ok := code.derived.(^ast.Comp_Lit)
		if !ok || (p.type == nil) != (c.type == nil) || p.tag != nil || c.tag != nil do return false
		return len(p.elems) == len(c.elems) && pattern_match(m, p.type, c.type) && match_exprs(m, p.elems, c.elems)

	case ^ast.Field_Value:
		c, ok := code.derived.(^ast.Field_Value)
		return ok && pattern_match(m, p.field, c.field) && pattern_match(m, p.value, c.value)

	case ^ast.Ternary_If_Expr:
		c, ok := code.derived.(^ast.Ternary_If_Expr)
		return ok && pattern_match(m, p.cond, c.cond) && pattern_match(m, p.x, c.x) && pattern_match(m, p.y, c.y)

	case ^ast.Ternary_When_Expr:
		c, ok := code.derived.(^ast.Ternary_When_Expr)
		return ok && pattern_match(m, p.cond, c.cond) && pattern_match(m, p.x, c.x) && pattern_match(m, p.y, c.y)

	case ^ast.Or_Else_Expr:
		c, ok := code.derived.(^ast.Or_Else_Expr)
		return ok && pattern_match(m, p.x, c.x) && pattern_match(m, p.y, c.y)

	case ^ast.Or_Return_Expr:
		c, ok := code.derived.(^ast.Or_Return_Expr)
		return ok && pattern_match(m, p.expr, c.expr)

	case ^ast.Deref_Expr:
		c, ok := code.derived.(^ast.Deref_Expr)
		return ok && pattern_match(m, p.expr, c.expr)

	case ^ast.Type_Cast:
		c, ok := code.derived.(^ast.Type_Cast)
		return ok && p.tok.kind == c.tok.kind && pattern_match(m, p.type, c.type) && pattern_match(m, p.expr, c.expr)

	case ^ast.Auto_Cast:
		c, ok := code.derived.(^ast.Auto_Cast)
		return ok && pattern_match(m, p.expr, c.expr)

	case ^ast.Array_Type:
		c, ok := code.derived.(^ast.Array_Type)
		if !ok || (p.len == nil) != (c.len == nil) || p.tag != nil || c.tag != nil do return false
		return pattern_match(m, p.len, c.len) && pattern_match(m, p.elem, c.elem)

	case ^ast.Dynamic_Array_Type:
		c, ok := code.derived.(^ast.Dynamic_Array_Type)
		return ok && p.tag == nil && c.tag == nil && pattern_match(m, p.elem, c.elem)

	case ^ast.Map_Type:
		c, ok := code.derived.(^ast.Map_Type)
		return ok && pattern_match(m, p.key, c.key) && pattern_match(m, p.value, c.value)

	case ^ast.Pointer_Type:
		c, ok := code.derived.(^ast.Pointer_Type)
		return ok && p.tag == nil && c.tag == nil && pattern_match(m, p.elem, c.elem)

	case ^ast.Expr_Stmt:
		c, ok := code.derived.(^ast.Expr_Stmt)
		return ok && pattern_match(m, p.expr, c.expr)

	case ^ast.Assign_Stmt:
		c, ok := code.derived.(^ast.Assign_Stmt)
		if !ok || p.op.kind != c.op.kind do return false
		if len(p.lhs) != len(c.lhs) || len(p.rhs) != len(c.rhs) do return false
		return match_exprs(m, p.lhs, c.lhs) && match_exprs(m, p.rhs, c.rhs)

	case ^ast.Value_Decl:
		c, ok := code.derived.(^ast.Value_Decl)
		if !ok || p.is_mutable != c.is_mutable || p.type != nil || c.type != nil do return false
		if len(p.names) != len(c.names) || len(p.values) != len(c.values) do return false
		return match_exprs(m, p.names, c.names) && match_exprs(m, p.values, c.values)

	case ^ast.Block_Stmt:
		c, ok := code.derived.(^ast.Block_Stmt)
		return ok && pattern_match_stmts(m, p.stmts, c.stmts)

	case ^ast.If_Stmt:
		c, ok := code.derived.(^ast.If_Stmt)
		if !ok || (p.init == nil) != (c.init == nil) || (p.else_stmt == nil) != (c.else_stmt == nil) do return false
		return(
			pattern_match(m, p.init, c.init) &&
			pattern_match(m, p.cond, c.cond) &&
			pattern_match(m, p.body, c.body) &&
			pattern_match(m, p.else_stmt, c.else_stmt) \
		)

	case ^ast.For_Stmt:
		c, ok := code.derived.(^ast.For_Stmt)
		if !ok do return false
		if (p.init == nil) != (c.init == nil) || (p.cond == nil) != (c.cond == nil) do return false
		if (p.post == nil) != (c.post == nil) do return false
		return(
			pattern_match(m, p.init, c.init) &&
			pattern_match(m, p.cond, c.cond) &&
			pattern_match(m, p.post, c.post) &&
			pattern_match(m, p.body, c.body) \
		)

	case ^ast.Range_Stmt:
		c, ok := code.derived.(^ast.Range_Stmt)
		if !ok || p.reverse != c.reverse || len(p.vals) != len(c.vals) do return false
		return match_exprs(m, p.vals, c.vals) && pattern_match(m, p.expr, c.expr) && pattern_match(m, p.body, c.body)

	case ^ast.Return_Stmt:
		if m.return_as_assign && len(p.results) == 1 {
			if c, ok := code.derived.(^ast.Assign_Stmt); ok {
				if c.op.kind != .Eq || len(c.lhs) != 1 || len(c.rhs) != 1 do return false
				if !set_form(m, .Assign) do return false
				if m.target == nil {
					m.target = c.lhs[0]
				} else if !same_node_text(m.src, m.target, c.lhs[0]) {
					return false
				}
				return pattern_match(m, p.results[0], c.rhs[0])
			}
		}
		c, ok := code.derived.(^ast.Return_Stmt)
		if !ok || len(p.results) != len(c.results) do return false
		if m.return_as_assign && !set_form(m, .Return) do return false
		return match_exprs(m, p.results, c.results)
	}

	if m.unsupported == nil do m.unsupported = pattern
	return false
}

match_exprs :: proc(m: ^Pattern_Matcher, pattern, code: []^ast.Expr) -> bool {
	for p, i in pattern {
		if !pattern_match(m, p, code[i]) do return false
	}
	return true
}

same_node_text :: proc(src: string, a, b: ^ast.Node) -> bool {
	return strip_space(node_text(src, a)) == strip_space(node_text(src, b))
}

set_form :: proc(m: ^Pattern_Matcher, form: Pattern_Return_Form) -> bool {
	if m.form != .None do return m.form == form
	m.form = form
	return true
}

// decided is false when the pattern side is not a package qualifier, so it compares as any other
// expression. A pattern qualifier binds to one code import name per match.
match_qualifier :: proc(m: ^Pattern_Matcher, pattern, code: ^ast.Expr) -> (matched, decided: bool) {
	if !m.match_imports do return
	p, p_ident := pattern.derived.(^ast.Ident)
	if !p_ident || slice.contains(m.vars, p.name) || p.name in m.bound do return
	c, c_ident := code.derived.(^ast.Ident)
	if !c_ident do return false, true
	for imp in m.imports {
		if pattern_import_name(imp) != c.name do continue
		if import_path_name(imp.fullpath) != p.name do return false, true
		if name, seen := m.qualifiers[p.name]; seen do return name == c.name, true
		m.qualifiers[p.name] = c.name
		return true, true
	}
	return false, true
}

// A call in node, or with control_flow also an or_return, or_break or or_continue.
@(private = "package")
pattern_has_effect :: proc(node: ^ast.Node, control_flow: bool) -> bool {
	if contains_call(node) do return true
	if !control_flow do return false
	found: bool
	visitor := ast.Visitor {
		data = &found,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			#partial switch _ in node.derived {
			case ^ast.Or_Return_Expr, ^ast.Or_Branch_Expr:
				(^bool)(visitor.data)^ = true
				return nil
			}
			return visitor
		},
	}
	ast.walk(&visitor, node)
	return found
}

// The name an import brings into scope: its alias, else the last segment of its path.
@(private = "package")
pattern_import_name :: proc(imp: ^ast.Import_Decl) -> string {
	if imp.name.text != "" do return imp.name.text
	return import_path_name(imp.fullpath)
}

// The last segment of an import path, quoted or not: "core:container/queue" gives queue.
@(private = "package")
import_path_name :: proc(path: string) -> string {
	path := strings.trim(path, "\"")
	if i := strings.last_index_any(path, ":/"); i >= 0 do path = path[i + 1:]
	return path
}
