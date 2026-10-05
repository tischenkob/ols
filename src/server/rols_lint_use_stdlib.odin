package server

import "base:runtime"
import "core:log"
import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:slice"
import "core:strings"
import "core:sync"

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
	name:       string, // what the rewrite uses: the rule target, or "array assignment" for a broadcast
	pkg:        string, // package the rewrite needs, "" for none
	broadcast:  bool, // a fill of a fixed array, rewritten as `args[0] = args[1]`
}

@(private = "file")
cached_rules: []Stdlib_Rule

@(private = "file")
cached_rules_once: sync.Once

// The test runner lints from several threads, so the first parse is guarded.
stdlib_rules :: proc() -> []Stdlib_Rule {
	sync.once_do(&cached_rules_once, proc() {
		cached_rules = parse_stdlib_rules(STDLIB_RULES, runtime.heap_allocator())
	})
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
					val := pattern_unparen(val)
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

// ponytail: syntactic; only the slice parameters of a rule are type checked, and only against strings.
@(private = "file")
is_string_expr :: proc(document: ^Document, node: ^ast.Node) -> bool {
	resolved, ok := resolve_entire_file(document)[uintptr(node)]
	if !ok || resolved.is_unresolved || resolved.symbol == nil do return false
	basic, is_basic := resolved.symbol.value.(SymbolBasicValue)
	if !is_basic || basic.ident == nil do return false
	return basic.ident.name == "string" || basic.ident.name == "cstring"
}

// rols: the text to pass where the core procedure takes a slice. A fixed array needs `[:]`, which
// an enumerated array, an interval or a value that is not addressable cannot have.
@(private = "file")
slice_arg_text :: proc(w: ^Stdlib_Walker, bound: ^ast.Node) -> (string, bool) {
	text := node_text(w.matcher.src, bound)
	expr := pattern_unparen(bound)
	if bin, is_bin := expr.derived.(^ast.Binary_Expr); is_bin {
		if bin.op.kind == .Range_Half || bin.op.kind == .Range_Full do return "", false
	}
	resolved, ok := resolve_entire_file(w.document)[uintptr(bound)]
	if !ok || resolved.is_unresolved || resolved.symbol == nil do return text, true
	array, is_array := resolved.symbol.value.(SymbolFixedArrayValue)
	if !is_array do return text, true
	if len_symbol, len_ok := resolve_type_in_package(w.document, resolved.symbol.pkg, array.len); len_ok {
		if _, is_enum := len_symbol.value.(SymbolEnumValue); is_enum do return "", false
	}
	// Odin slices only an addressable array: a variable, or a field or element of one. Constants,
	// by-value parameters, range values and call results are not.
	root := access_root(expr)
	if _, is_ident := root.derived.(^ast.Ident); !is_ident do return "", false
	root_symbol, root_ok := resolve_entire_file(w.document)[uintptr(root)]
	if !root_ok || root_symbol.symbol == nil do return "", false
	flags := root_symbol.symbol.flags
	if .Mutable not_in flags || .Parameter in flags do return "", false
	if is_range_value(w.document, root.derived.(^ast.Ident)) do return "", false
	return strings.concatenate({text, "[:]"}, w.allocator), true
}

// The expression that a chain of fields, indexes and parentheses starts from: `a` in `a.b[i].c`.
@(private = "file")
access_root :: proc(node: ^ast.Node) -> ^ast.Node {
	root := node
	for {
		#partial switch e in root.derived {
		case ^ast.Selector_Expr:
			root = e.expr
		case ^ast.Index_Expr:
			root = e.expr
		case ^ast.Paren_Expr:
			root = e.expr
		case:
			return root
		}
	}
}

// True when an enclosing loop of the identifier declares its name as a value without `&`. Such a
// value is a copy and cannot be sliced. A same-named local inside the loop refuses too, which is safe.
@(private = "file")
is_range_value :: proc(document: ^Document, ident: ^ast.Ident) -> bool {
	Search :: struct {
		ident: ^ast.Ident,
		found: bool,
	}
	search := Search{ident, false}
	visitor := ast.Visitor {
		data = &search,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			search := (^Search)(visitor.data)
			if loop, is_loop := node.derived.(^ast.Range_Stmt); is_loop && loop.body != nil {
				if loop.body.pos.offset <= search.ident.pos.offset && search.ident.pos.offset < loop.body.end.offset {
					for val in loop.vals {
						if name, is_name := val.derived.(^ast.Ident); is_name && name.name == search.ident.name {
							search.found = true
						}
					}
				}
			}
			return visitor
		},
	}
	for decl in document.ast.decls do ast.walk(&visitor, decl)
	return search.found
}

@(private = "file")
Stdlib_Walker :: struct {
	document:  ^Document,
	src:       string,
	rules:     []Stdlib_Rule,
	rule:      ^Stdlib_Rule, // the rule of the current attempt
	matcher:   Pattern_Matcher,
	out:       [dynamic]Stdlib_Match,
	allocator: mem.Allocator,
}

@(private = "file")
finish :: proc(w: ^Stdlib_Walker, start, end: int, form: Stdlib_Form) -> (result: Stdlib_Match, ok: bool) {
	m := &w.matcher
	args := make([]string, len(w.rule.params), w.allocator)
	for param, i in w.rule.params {
		bound, bound_ok := m.binds[param]
		if !bound_ok do return
		// rols: a loop variable of the code must not reach the call, which runs outside the loop.
		for use in collect_ident_uses(bound) {
			for _, code_name in m.names do if use.ident.name == code_name do return
		}
		args[i] = node_text(m.src, bound)
		if w.rule.slice_params[i] {
			if is_string_expr(w.document, bound) do return
			args[i] = slice_arg_text(w, bound) or_return
		}
	}
	result = Stdlib_Match {
		start = start,
		end   = end,
		rule  = w.rule,
		args  = args,
		form  = form,
		name  = w.rule.target,
		pkg   = w.rule.pkg,
	}
	if w.rule.target == "slice.fill" {
		fill_args(w, &result, m.binds[w.rule.params[0]], m.binds[w.rule.params[1]]) or_return
	}
	switch m.form {
	case .None:
	case .Return:
		result.form = .Return
	case .Assign:
		result.form = .Assign
	}
	if m.target != nil {
		result.target = node_text(m.src, m.target)
	}
	return result, true
}

// rols: slice.fill takes the value as the element type, so an untyped compound literal or implicit
// selector must name that type, or the fill is not offered. A fixed array takes the value by
// broadcast assignment instead, which needs no import.
@(private = "file")
fill_args :: proc(w: ^Stdlib_Walker, m: ^Stdlib_Match, s, v: ^ast.Node) -> bool {
	// The loop writes each element before it reads the value again, so a value that reads the
	// array, like `arr[0] * 2`, changes as the loop runs. The rewrite reads it once.
	if root, is_ident := access_root(s).derived.(^ast.Ident); is_ident {
		for use in collect_ident_uses(v) do if use.ident.name == root.name do return false
	}

	elem: Symbol
	elem_ok, fixed := false, false
	if resolved, ok := resolve_entire_file(w.document)[uintptr(s)];
	   ok && !resolved.is_unresolved && resolved.symbol != nil {
		// Neither slice.fill nor a broadcast takes a #soa array.
		if .Soa in resolved.symbol.flags do return false
		elem_expr: ^ast.Expr
		#partial switch a in resolved.symbol.value {
		case SymbolFixedArrayValue:
			// A pointer to an array takes slice.fill through `p[:]`, but not a broadcast.
			elem_expr, fixed = a.expr, resolved.symbol.pointers == 0
		case SymbolSliceValue:
			elem_expr = a.expr
		case SymbolDynamicArrayValue:
			elem_expr = a.expr
		}
		if elem_expr != nil {
			elem, elem_ok = resolve_type_in_package(w.document, resolved.symbol.pkg, elem_expr)
		}
	}

	value := pattern_unparen(v)
	untyped := false
	#partial switch e in value.derived {
	case ^ast.Comp_Lit:
		untyped = e.type == nil
		if untyped && !(elem_ok && elem.pointers == 0 && takes_comp_lit(elem)) do return false
	case ^ast.Implicit_Selector_Expr:
		untyped = true
		if !elem_ok || elem.pointers != 0 do return false
		if _, is_enum := elem.value.(SymbolEnumValue); !is_enum do return false
	}
	if untyped {
		// An anonymous aggregate carries the keyword as its name, which symbol_type_text would write.
		if .Anonymous in elem.flags do return false
		ast_context := make_ast_context(
			w.document.ast,
			w.document.imports,
			w.document.package_name,
			w.document.uri.uri,
			w.document.fullpath,
			context.temp_allocator,
		)
		type_text := symbol_type_text(&ast_context, elem, "", require_import = true) or_return
		m.args[1] = strings.concatenate({type_text, node_text(w.src, value)}, w.allocator)
	}

	is_nil := false
	if ident, is_ident := value.derived.(^ast.Ident); is_ident do is_nil = ident.name == "nil"
	if fixed && elem_ok && broadcasts(w.document, elem, is_nil) {
		m.broadcast = true
		m.args[0] = node_text(w.src, s)
		m.name = "array assignment"
		m.pkg = ""
	}
	return true
}

// Types that a compound literal can build. A pointer or procedure type before `{` would parse as
// something else.
@(private = "file")
takes_comp_lit :: proc(symbol: Symbol) -> bool {
	#partial switch _ in symbol.value {
	case SymbolStructValue,
	     SymbolUnionValue,
	     SymbolEnumValue,
	     SymbolBitSetValue,
	     SymbolBitFieldValue,
	     SymbolFixedArrayValue,
	     SymbolSliceValue,
	     SymbolDynamicArrayValue,
	     SymbolMapValue,
	     SymbolMatrixValue,
	     SymbolBasicValue:
		return true
	}
	return false
}

// rols: whether Odin assigns a value of the element type to every element of a fixed array. It
// does, also through nested arrays, except an untyped constant into a matrix or an enumerated array,
// and nil into a union. The value may be untyped, so those element types never broadcast.
@(private = "file")
broadcasts :: proc(document: ^Document, elem: Symbol, is_nil: bool) -> bool {
	#partial switch e in elem.value {
	case SymbolMatrixValue:
		return false
	case SymbolUnionValue:
		return !is_nil || elem.pointers != 0
	case SymbolFixedArrayValue:
		if elem.pointers != 0 do return true
		if len_symbol, ok := resolve_type_in_package(document, elem.pkg, e.len); ok {
			if _, is_enum := len_symbol.value.(SymbolEnumValue); is_enum do return false
		}
		inner, inner_ok := resolve_type_in_package(document, elem.pkg, e.expr)
		return inner_ok && broadcasts(document, inner, is_nil)
	}
	return true
}

@(private = "file")
try_stmts :: proc(w: ^Stdlib_Walker, rule: ^Stdlib_Rule, pattern, code: []^ast.Stmt) -> (Stdlib_Match, bool) {
	start_attempt(w, rule)
	if !pattern_match_stmts(&w.matcher, pattern, code) do return {}, false
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
	w.matcher = pattern_matcher_make(w.src)
	w.matcher.return_as_assign = true

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
start_attempt :: proc(w: ^Stdlib_Walker, rule: ^Stdlib_Rule) {
	w.rule = rule
	w.matcher.vars = rule.params
	w.matcher.bound = rule.bound
	pattern_reset(&w.matcher)
}

@(private = "file")
try_expr :: proc(w: ^Stdlib_Walker, rule: ^Stdlib_Rule, node: ^ast.Node) -> (Stdlib_Match, bool) {
	start_attempt(w, rule)
	if !pattern_match(&w.matcher, rule.expr, node) do return {}, false
	return finish(w, node.pos.offset, node.end.offset, .Expr)
}

// `alias` replaces the rule package when the file imports it under another name.
stdlib_rewrite :: proc(m: Stdlib_Match, alias: string) -> string {
	if m.broadcast {
		return strings.concatenate({m.args[0], " = ", m.args[1]}, context.temp_allocator)
	}
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
