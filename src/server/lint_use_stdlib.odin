package server

import "base:runtime"
import "core:log"
import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:slice"
import "core:strings"

// A rule is an Odin proc: value parameters are metavariables, the body is the pattern and the
// `@replace` doc comment names the core procedure the pattern is a hand-written copy of.
Stdlib_Rule :: struct {
	name:         string, // rule proc name
	target:       string, // "slice.contains" or "max"
	pkg:          string, // "slice", or "" for builtins; import path is "core:" + pkg
	params:       []string, // metavariables, in call order
	slice_params: []bool, // parallel to params: parameter type is a slice
	bound:        map[string]bool, // names declared inside the body
	stmts:        []^ast.Stmt,
	expr:         ^ast.Expr, // non-nil for expression patterns
	acc:          string, // accumulator local when the body ends in `return <name declared by stmts[0]>`
	src:          string, // text of the rule, doc comment included
}

Stdlib_Form :: enum {
	Return,
	Assign,
	Decl,
	Stmt,
	Expr,
}

Stdlib_Match :: struct {
	start, end: int, // byte range in document.ast.src
	rule:       ^Stdlib_Rule,
	args:       []string, // matched text per parameter, in parameter order
	form:       Stdlib_Form,
	target:     string, // lhs text for Assign and Decl
}

@(private = "file")
cached_rules: []Stdlib_Rule

@(private = "file")
cached_rules_parsed: bool

// Handlers run serially on the main thread and the CLI is single threaded, so a plain global is enough.
stdlib_rules :: proc() -> []Stdlib_Rule {
	if !cached_rules_parsed {
		cached_rules_parsed = true
		cached_rules = parse_stdlib_rules(STDLIB_RULES, runtime.heap_allocator())
	}
	return cached_rules
}

parse_stdlib_rules :: proc(src: string, allocator: mem.Allocator) -> []Stdlib_Rule {
	context.allocator = allocator

	full := strings.concatenate({"package rules\n", src}, allocator)

	p := parser.Parser {
		err   = parser.default_error_handler,
		warn  = parser.default_error_handler,
		flags = {.Optional_Semicolons},
	}
	file := new(ast.File, allocator)
	file.fullpath = "stdlib_rules.odin"
	file.src = full

	if !parse_file(&p, file, allocator) || file.syntax_error_count > 0 {
		log.error("failed to parse the stdlib lint rules")
		return nil
	}

	rules := make([dynamic]Stdlib_Rule, allocator)

	for decl in file.decls {
		value_decl, is_value := decl.derived.(^ast.Value_Decl)
		if !is_value || value_decl.docs == nil || len(value_decl.values) != 1 do continue

		lit, is_lit := value_decl.values[0].derived.(^ast.Proc_Lit)
		if !is_lit || lit.body == nil || lit.type == nil do continue

		docs := get_comment(value_decl.docs, allocator)
		if !strings.has_prefix(docs, "@replace ") do continue
		target := docs[len("@replace "):]
		if line_end := strings.index_byte(target, '\n'); line_end >= 0 {
			target = target[:line_end]
		}
		target = strings.trim_space(target)
		if target == "" do continue

		block, is_block := lit.body.derived.(^ast.Block_Stmt)
		if !is_block || len(block.stmts) == 0 do continue

		rule := Stdlib_Rule {
			name   = node_text(full, value_decl.names[0]),
			target = target,
			stmts  = block.stmts,
			bound  = make(map[string]bool, allocator),
			src    = full[value_decl.docs.pos.offset:value_decl.end.offset],
		}
		if dot := strings.index_byte(target, '.'); dot >= 0 {
			rule.pkg = target[:dot]
		}

		params := make([dynamic]string, allocator)
		slices := make([dynamic]bool, allocator)
		if lit.type.params != nil {
			for field in lit.type.params.list {
				array, is_array := field.type.derived.(^ast.Array_Type)
				for name in field.names {
					ident, is_ident := name.derived.(^ast.Ident)
					if !is_ident do continue
					append(&params, ident.name)
					append(&slices, is_array && array.len == nil)
				}
			}
		}
		rule.params = params[:]
		rule.slice_params = slices[:]

		collect_bound(&rule.bound, lit.body)

		if len(block.stmts) == 1 {
			if ret, is_ret := block.stmts[0].derived.(^ast.Return_Stmt); is_ret && len(ret.results) == 1 {
				rule.expr = ret.results[0]
			}
		} else if ret, is_ret := block.stmts[len(block.stmts) - 1].derived.(^ast.Return_Stmt);
		   is_ret && len(ret.results) == 1 {
			if ident, is_ident := ret.results[0].derived.(^ast.Ident); is_ident {
				decl, is_decl := block.stmts[0].derived.(^ast.Value_Decl)
				if is_decl && decl.is_mutable && len(decl.names) == 1 {
					if first, ok := decl.names[0].derived.(^ast.Ident); ok && first.name == ident.name {
						rule.acc = ident.name
					}
				}
			}
		}

		append(&rules, rule)
	}

	return rules[:]
}

@(private = "file")
collect_bound :: proc(bound: ^map[string]bool, body: ^ast.Stmt) {
	visitor := ast.Visitor {
		data = bound,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			bound := (^map[string]bool)(visitor.data)
			#partial switch n in node.derived {
			case ^ast.Range_Stmt:
				for val in n.vals {
					val := unparen(val)
					if unary, ok := val.derived.(^ast.Unary_Expr); ok {
						val = unary.expr
					}
					if ident, ok := val.derived.(^ast.Ident); ok {
						bound[ident.name] = true
					}
				}
			case ^ast.Value_Decl:
				for name in n.names {
					if ident, ok := name.derived.(^ast.Ident); ok {
						bound[ident.name] = true
					}
				}
			}
			return visitor
		},
	}
	ast.walk(&visitor, body)
}

@(private = "file")
Matcher :: struct {
	rule:     ^Stdlib_Rule,
	src:      string,
	binds:    map[string]^ast.Node, // metavariable -> code expression
	names:    map[string]string, // pattern-local name -> code name
	form:     Stdlib_Form,
	has_form: bool,
	target:   ^ast.Node, // assignment target shared by every `return` of the match
}

@(private = "file")
unparen :: proc(node: ^ast.Node) -> ^ast.Node {
	node := node
	for {
		paren, ok := node.derived.(^ast.Paren_Expr)
		if !ok do return node
		node = paren.expr
	}
}

@(private = "file")
same_node_text :: proc(src: string, a, b: ^ast.Node) -> bool {
	return strip_space(node_text(src, a)) == strip_space(node_text(src, b))
}

@(private = "file")
set_form :: proc(m: ^Matcher, form: Stdlib_Form) -> bool {
	if m.has_form do return m.form == form
	m.form = form
	m.has_form = true
	return true
}

@(private = "file")
match :: proc(m: ^Matcher, pattern, code: ^ast.Node) -> bool {
	if pattern == nil || code == nil do return pattern == nil && code == nil

	pattern, code := unparen(pattern), unparen(code)

	#partial switch p in pattern.derived {
	case ^ast.Ident:
		if slice.contains(m.rule.params, p.name) {
			if bound, seen := m.binds[p.name]; seen {
				return same_node_text(m.src, bound, code)
			}
			m.binds[p.name] = code
			return true
		}
		c, is_ident := code.derived.(^ast.Ident)
		if !is_ident do return false
		if p.name in m.rule.bound {
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
		return ok && p.op.kind == c.op.kind && match(m, p.expr, c.expr)

	case ^ast.Binary_Expr:
		c, ok := code.derived.(^ast.Binary_Expr)
		return ok && p.op.kind == c.op.kind && match(m, p.left, c.left) && match(m, p.right, c.right)

	case ^ast.Selector_Expr:
		c, ok := code.derived.(^ast.Selector_Expr)
		if !ok || p.field == nil || c.field == nil || p.field.name != c.field.name do return false
		return match(m, p.expr, c.expr)

	case ^ast.Index_Expr:
		c, ok := code.derived.(^ast.Index_Expr)
		return ok && match(m, p.expr, c.expr) && match(m, p.index, c.index)

	case ^ast.Slice_Expr:
		c, ok := code.derived.(^ast.Slice_Expr)
		if !ok || (p.low == nil) != (c.low == nil) || (p.high == nil) != (c.high == nil) do return false
		return match(m, p.expr, c.expr) && match(m, p.low, c.low) && match(m, p.high, c.high)

	case ^ast.Call_Expr:
		c, ok := code.derived.(^ast.Call_Expr)
		if !ok || len(p.args) != len(c.args) || !match(m, p.expr, c.expr) do return false
		for arg, i in p.args {
			if !match(m, arg, c.args[i]) do return false
		}
		return true

	case ^ast.Expr_Stmt:
		c, ok := code.derived.(^ast.Expr_Stmt)
		return ok && match(m, p.expr, c.expr)

	case ^ast.Assign_Stmt:
		c, ok := code.derived.(^ast.Assign_Stmt)
		if !ok || p.op.kind != c.op.kind do return false
		if len(p.lhs) != len(c.lhs) || len(p.rhs) != len(c.rhs) do return false
		for lhs, i in p.lhs {
			if !match(m, lhs, c.lhs[i]) do return false
		}
		for rhs, i in p.rhs {
			if !match(m, rhs, c.rhs[i]) do return false
		}
		return true

	case ^ast.Value_Decl:
		c, ok := code.derived.(^ast.Value_Decl)
		if !ok || p.is_mutable != c.is_mutable || p.type != nil || c.type != nil do return false
		if len(p.names) != len(c.names) || len(p.values) != len(c.values) do return false
		for name, i in p.names {
			if !match(m, name, c.names[i]) do return false
		}
		for value, i in p.values {
			if !match(m, value, c.values[i]) do return false
		}
		return true

	case ^ast.Block_Stmt:
		c, ok := code.derived.(^ast.Block_Stmt)
		if !ok || len(p.stmts) != len(c.stmts) do return false
		for stmt, i in p.stmts {
			if !match(m, stmt, c.stmts[i]) do return false
		}
		return true

	case ^ast.If_Stmt:
		c, ok := code.derived.(^ast.If_Stmt)
		if !ok || (p.init == nil) != (c.init == nil) || (p.else_stmt == nil) != (c.else_stmt == nil) do return false
		return(
			match(m, p.init, c.init) &&
			match(m, p.cond, c.cond) &&
			match(m, p.body, c.body) &&
			match(m, p.else_stmt, c.else_stmt) \
		)

	case ^ast.For_Stmt:
		c, ok := code.derived.(^ast.For_Stmt)
		if !ok do return false
		if (p.init == nil) != (c.init == nil) || (p.cond == nil) != (c.cond == nil) do return false
		if (p.post == nil) != (c.post == nil) do return false
		return(
			match(m, p.init, c.init) &&
			match(m, p.cond, c.cond) &&
			match(m, p.post, c.post) &&
			match(m, p.body, c.body) \
		)

	case ^ast.Range_Stmt:
		c, ok := code.derived.(^ast.Range_Stmt)
		if !ok || p.reverse != c.reverse || len(p.vals) != len(c.vals) do return false
		for val, i in p.vals {
			if !match(m, val, c.vals[i]) do return false
		}
		return match(m, p.expr, c.expr) && match(m, p.body, c.body)

	case ^ast.Return_Stmt:
		if len(p.results) == 1 {
			if c, ok := code.derived.(^ast.Assign_Stmt); ok {
				if c.op.kind != .Eq || len(c.lhs) != 1 || len(c.rhs) != 1 do return false
				if !set_form(m, .Assign) do return false
				if m.target == nil {
					m.target = c.lhs[0]
				} else if !same_node_text(m.src, m.target, c.lhs[0]) {
					return false
				}
				return match(m, p.results[0], c.rhs[0])
			}
		}
		c, ok := code.derived.(^ast.Return_Stmt)
		if !ok || len(p.results) != len(c.results) do return false
		if !set_form(m, .Return) do return false
		for result, i in p.results {
			if !match(m, result, c.results[i]) do return false
		}
		return true
	}

	return false
}

// ponytail: syntactic; only the slice parameters of a rule are type checked, and only against strings.
@(private = "file")
is_string_expr :: proc(document: ^Document, node: ^ast.Node) -> bool {
	resolved, ok := resolve_entire_file(document)[uintptr(node)]
	if !ok || resolved.is_unresolved || resolved.symbol == nil do return false
	basic, is_basic := resolved.symbol.value.(SymbolBasicValue)
	if !is_basic || basic.ident == nil do return false
	return basic.ident.name == "string" || basic.ident.name == "cstring"
}

@(private = "file")
Stdlib_Walker :: struct {
	document:  ^Document,
	src:       string,
	rules:     []Stdlib_Rule,
	matcher:   Matcher,
	out:       [dynamic]Stdlib_Match,
	allocator: mem.Allocator,
}

@(private = "file")
finish :: proc(w: ^Stdlib_Walker, start, end: int, form: Stdlib_Form) -> (result: Stdlib_Match, ok: bool) {
	m := &w.matcher
	args := make([]string, len(m.rule.params), w.allocator)
	for param, i in m.rule.params {
		bound, bound_ok := m.binds[param]
		if !bound_ok do return
		if m.rule.slice_params[i] && is_string_expr(w.document, bound) do return
		args[i] = node_text(m.src, bound)
	}
	result = Stdlib_Match {
		start = start,
		end   = end,
		rule  = m.rule,
		args  = args,
		form  = m.has_form ? m.form : form,
	}
	if m.target != nil {
		result.target = node_text(m.src, m.target)
	}
	return result, true
}

@(private = "file")
try_stmts :: proc(w: ^Stdlib_Walker, rule: ^Stdlib_Rule, pattern, code: []^ast.Stmt) -> (Stdlib_Match, bool) {
	w.matcher.rule = rule
	clear(&w.matcher.binds)
	clear(&w.matcher.names)
	w.matcher.has_form = false
	w.matcher.target = nil

	for stmt, i in pattern {
		if !match(&w.matcher, stmt, code[i]) do return {}, false
	}
	return finish(w, code[0].pos.offset, code[len(code) - 1].end.offset, .Stmt)
}

@(private = "file")
stmts_match :: proc(
	w: ^Stdlib_Walker,
	rule: ^Stdlib_Rule,
	stmts: []^ast.Stmt,
	i: int,
) -> (
	m: Stdlib_Match,
	n: int,
	ok: bool,
) {
	available := len(stmts) - i
	if len(rule.stmts) <= available {
		if m, ok = try_stmts(w, rule, rule.stmts, stmts[i:][:len(rule.stmts)]); ok {
			return m, len(rule.stmts), true
		}
	}
	if rule.acc == "" do return {}, 0, false

	// The final `return acc` is optional: the code may keep using the accumulator afterwards.
	n = len(rule.stmts) - 1
	if n > available do return {}, 0, false
	if m, ok = try_stmts(w, rule, rule.stmts[:n], stmts[i:][:n]); !ok do return {}, 0, false

	decl, is_decl := stmts[i].derived.(^ast.Value_Decl)
	if !is_decl || len(decl.names) != 1 do return {}, 0, false
	m.form = .Decl
	m.target = node_text(w.src, decl.names[0])
	return m, n, true
}

@(private = "file")
scan_stmts :: proc(w: ^Stdlib_Walker, stmts: []^ast.Stmt) {
	i := 0
	for i < len(stmts) {
		step := 1
		for &rule in w.rules {
			if rule.expr != nil do continue
			m, n, ok := stmts_match(w, &rule, stmts, i)
			if !ok do continue
			append(&w.out, m)
			step = n
			break
		}
		i += step
	}
}

stdlib_matches :: proc(document: ^Document, allocator := context.temp_allocator) -> []Stdlib_Match {
	rules := stdlib_rules()
	if len(rules) == 0 do return nil

	w := Stdlib_Walker {
		document  = document,
		src       = document.ast.src,
		rules     = rules,
		out       = make([dynamic]Stdlib_Match, context.temp_allocator),
		allocator = allocator,
	}
	w.matcher.src = w.src
	w.matcher.binds = make(map[string]^ast.Node, context.temp_allocator)
	w.matcher.names = make(map[string]string, context.temp_allocator)

	visitor := ast.Visitor {
		data = &w,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			w := (^Stdlib_Walker)(visitor.data)
			#partial switch n in node.derived {
			case ^ast.Block_Stmt:
				scan_stmts(w, n.stmts)
			case ^ast.Case_Clause:
				scan_stmts(w, n.body)
			case ^ast.Paren_Expr:
			// The inner expression is visited on its own.
			case:
				for &rule in w.rules {
					if rule.expr == nil do continue
					if m, ok := try_expr(w, &rule, node); ok {
						append(&w.out, m)
						break
					}
				}
			}
			return visitor
		},
	}
	for decl in document.ast.decls {
		ast.walk(&visitor, decl)
	}

	slice.sort_by(w.out[:], proc(a, b: Stdlib_Match) -> bool {
		if a.start != b.start do return a.start < b.start
		return a.end > b.end
	})

	out := make([dynamic]Stdlib_Match, allocator)
	outer: for m in w.out {
		for kept in out {
			if kept.start <= m.start && m.end <= kept.end do continue outer
		}
		append(&out, m)
	}
	return out[:]
}

@(private = "file")
try_expr :: proc(w: ^Stdlib_Walker, rule: ^Stdlib_Rule, node: ^ast.Node) -> (Stdlib_Match, bool) {
	w.matcher.rule = rule
	clear(&w.matcher.binds)
	clear(&w.matcher.names)
	w.matcher.has_form = false
	w.matcher.target = nil

	if !match(&w.matcher, rule.expr, node) do return {}, false
	return finish(w, node.pos.offset, node.end.offset, .Expr)
}

// `alias` replaces the rule package when the file imports it under another name.
stdlib_rewrite :: proc(document: ^Document, m: Stdlib_Match, alias: string) -> string {
	name := m.rule.target
	if m.rule.pkg != "" {
		qualifier := alias if alias != "" else m.rule.pkg
		name = strings.concatenate({qualifier, m.rule.target[len(m.rule.pkg):]}, context.temp_allocator)
	}
	call := strings.concatenate(
		{name, "(", strings.join(m.args, ", ", context.temp_allocator), ")"},
		context.temp_allocator,
	)
	switch m.form {
	case .Return:
		return strings.concatenate({"return ", call}, context.temp_allocator)
	case .Assign:
		return strings.concatenate({m.target, " = ", call}, context.temp_allocator)
	case .Decl:
		return strings.concatenate({m.target, " := ", call}, context.temp_allocator)
	case .Stmt, .Expr:
	}
	return call
}

@(private = "file")
STDLIB_RULES :: `
// @replace slice.contains
contains :: proc(s: []$T, x: T) -> bool {
	for e in s {
		if e == x {
			return true
		}
	}
	return false
}

// @replace slice.contains
contains_indexed :: proc(s: []$T, x: T) -> bool {
	for i in 0 ..< len(s) {
		if s[i] == x {
			return true
		}
	}
	return false
}

// @replace slice.linear_search
linear_search :: proc(s: []$T, x: T) -> (int, bool) {
	for e, i in s {
		if e == x {
			return i, true
		}
	}
	return -1, false
}

// @replace slice.linear_search
linear_search_indexed :: proc(s: []$T, x: T) -> (int, bool) {
	for i in 0 ..< len(s) {
		if s[i] == x {
			return i, true
		}
	}
	return -1, false
}

// @replace strings.contains
contains_substring :: proc(s, sub: string) -> bool {
	return strings.index(s, sub) >= 0
}

// @replace strings.contains
contains_substring_ne :: proc(s, sub: string) -> bool {
	return strings.index(s, sub) != -1
}

// @replace strings.has_prefix
has_prefix :: proc(s, p: string) -> bool {
	return len(s) >= len(p) && s[:len(p)] == p
}

// @replace strings.has_suffix
has_suffix :: proc(s, p: string) -> bool {
	return len(s) >= len(p) && s[len(s) - len(p):] == p
}

// @replace max
max_lt :: proc(a, b: $T) -> T {
	if a < b {
		return b
	}
	return a
}

// @replace max
max_gt :: proc(a, b: $T) -> T {
	if a > b {
		return a
	}
	return b
}

// @replace max
max_else :: proc(a, b: $T) -> T {
	if a > b {
		return a
	} else {
		return b
	}
}

// @replace min
min_lt :: proc(a, b: $T) -> T {
	if a < b {
		return a
	}
	return b
}

// @replace min
min_gt :: proc(a, b: $T) -> T {
	if a > b {
		return b
	}
	return a
}

// @replace min
min_else :: proc(a, b: $T) -> T {
	if a < b {
		return a
	} else {
		return b
	}
}

// @replace abs
abs_lt :: proc(x: $T) -> T {
	if x < 0 {
		return -x
	}
	return x
}

// @replace clamp
clamp_if :: proc(x, lo, hi: $T) -> T {
	if x < lo {
		return lo
	}
	if x > hi {
		return hi
	}
	return x
}

// @replace copy
copy_loop :: proc(dst, src: []$T) {
	for i in 0 ..< len(src) {
		dst[i] = src[i]
	}
}

// @replace slice.fill
fill_indexed :: proc(s: []$T, v: T) {
	for i in 0 ..< len(s) {
		s[i] = v
	}
}

// @replace slice.fill
fill_ref :: proc(s: []$T, v: T) {
	for &e in s {
		e = v
	}
}

// @replace math.sum
sum :: proc(s: []$T) -> T {
	total := 0
	for x in s {
		total += x
	}
	return total
}
`
