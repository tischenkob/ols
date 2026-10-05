package server

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"

import "src:common"

// What a rewritten range becomes: the switch binding `v`, its address `&v`, or nothing.
Bind_Form :: enum {
	Value,
	Ref,
	Delete,
}

Bind_Edit :: struct {
	start, end: int,
	form:       Bind_Form,
}

// A type switch whose single-type cases assert the subject to the case type again.
Bind_Match :: struct {
	tag:      ^ast.Assign_Stmt,
	subject:  string,
	name:     string, // the existing binding, "" when it is `_` or absent
	bare:     bool, // `switch in s`
	is_ref:   bool, // the binding is already `&name`
	need_ref: bool, // a rewritten site takes the address of the variant or writes through it
	sites:    [dynamic]^ast.Type_Assertion,
	edits:    [dynamic]Bind_Edit,
}

lint_redundant_type_assertion :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_redundant_type_assertion do return
	n, is_switch := node.derived.(^ast.Type_Switch_Stmt)
	if !is_switch do return
	m, ok := match_switch_binding(ctx.src, ctx.document.ast.decls[:], n)
	if !ok do return
	for site in m.sites {
		append(
			diags,
			Diagnostic {
				range = common.get_token_range(site, ctx.src),
				severity = .Hint,
				code = "redundant-type-assertion",
				message = fmt.tprintf(
					"`%s` is already `%s` in this case; bind it in the switch",
					m.subject,
					node_text(ctx.src, site.type),
				),
				tags = unnecessary_tags,
			},
		)
	}
}

// The subject must be a plain name, and a clause may name it only in the assertions. Any other use could
// redeclare it, write it, or pass a pointer subject on to code that changes the variant after the switch
// copied it, so such a clause is skipped.
match_switch_binding :: proc(src: string, decls: []^ast.Stmt, n: ^ast.Type_Switch_Stmt) -> (m: Bind_Match, ok: bool) {
	m.tag = n.tag.derived.(^ast.Assign_Stmt) or_return
	if len(m.tag.lhs) != 1 || len(m.tag.rhs) != 1 do return
	subject := m.tag.rhs[0].derived.(^ast.Ident) or_return
	m.subject = subject.name
	block := n.body.derived.(^ast.Block_Stmt) or_return

	// `switch in u` parses with a blank on the left that sits at the switch keyword.
	binding := m.tag.lhs[0]
	m.bare = binding.pos.offset == n.switch_pos.offset
	if unary, is_unary := binding.derived.(^ast.Unary_Expr); is_unary && unary.op.kind == .And {
		binding = unary.expr
		m.is_ref = true
	}
	name := binding.derived.(^ast.Ident) or_return
	if !m.bare && name.name != "_" do m.name = name.name
	if m.name == m.subject do return

	m.sites = make([dynamic]^ast.Type_Assertion, context.temp_allocator)
	m.edits = make([dynamic]Bind_Edit, context.temp_allocator)
	results := result_count(decls, n.pos.offset)
	for stmt in block.stmts {
		clause, is_clause := stmt.derived.(^ast.Case_Clause)
		if is_clause && len(clause.list) == 1 do match_clause(&m, src, clause, results)
	}
	return m, len(m.sites) > 0
}

// Results of the innermost procedure around offset.
@(private = "file")
result_count :: proc(decls: []^ast.Stmt, offset: int) -> int {
	top := top_level_stmt_at(decls, offset)
	if top == nil do return 0
	count := 0
	for at in nodes_at({top}, offset) {
		lit := at.node.derived.(^ast.Proc_Lit) or_continue
		count = 0
		if lit.type.results == nil do continue
		for field in lit.type.results.list do count += max(len(field.names), 1)
	}
	return count
}

@(private = "file")
Site :: struct {
	ta:   ^ast.Type_Assertion,
	node: ^ast.Expr, // the assertion, or the `&` around it
	form: Bind_Form,
	decl: ^ast.Value_Decl, // the clause statement `c := site`, else nil
}

@(private = "file")
match_clause :: proc(m: ^Bind_Match, src: string, clause: ^ast.Case_Clause, results: int) {
	type_text := strip_space(node_text(src, clause.list[0]))

	uses := make([dynamic]IdentUse, context.temp_allocator)
	for stmt in clause.body {
		for use in collect_ident_uses(stmt) {
			if !in_proc_lit(use) && !is_field_name(use) do append(&uses, use)
		}
	}

	sites := make([dynamic]Site, context.temp_allocator)
	clause_ref := false
	for use in uses {
		if use.ident.name == m.name {
			if is_declaration(use) do return
			// A write through `&x` changes what a copy taken by the clause would read.
			if m.is_ref && is_write(use) do clause_ref = true
		}
		if use.ident.name != m.subject do continue
		ta, is_site := site_of(src, use, type_text, results)
		if !is_site do return

		// Ancestors of the assertion; parents[0] is the clause statement.
		parents := use.parents[:len(use.parents) - 1]
		site := Site {
			ta   = ta,
			node = ta,
		}
		top := len(parents) - 1
		if unary, is_unary := parents[top].derived.(^ast.Unary_Expr); is_unary && unary.op.kind == .And {
			site.node, site.form, clause_ref = unary, .Ref, true
			top -= 1
		} else if !points_at_data(type_text) && (writes_through(ta, parents) || needs_address(ta, parents[top])) {
			clause_ref = true
		}
		if top == 0 {
			if decl, is_decl := parents[0].derived.(^ast.Value_Decl); is_decl && is_alias(decl, site.node) {
				site.decl = decl
			}
		}
		append(&sites, site)
	}

	for site in sites {
		append(&m.sites, site.ta)
		// A copy stays a copy while the clause can write the variant through the binding.
		removable := site.decl != nil && (site.form == .Ref || !clause_ref)
		if removable && remove_alias(m, src, uses[:], site) do continue
		append(&m.edits, Bind_Edit{site.node.pos.offset, site.node.end.offset, site.form})
	}
	m.need_ref ||= clause_ref
}

// `s.(T)` with T the case type, used where one value is expected. `return s.(T)` in a procedure with two
// results returns the optional ok as well.
@(private = "file")
site_of :: proc(src: string, use: IdentUse, type_text: string, results: int) -> (^ast.Type_Assertion, bool) {
	n := len(use.parents)
	if n < 2 do return nil, false
	ta, is_ta := use.parents[n - 1].derived.(^ast.Type_Assertion)
	if !is_ta || ta.type == nil do return nil, false
	subject: ^ast.Expr = use.ident
	if ta.expr != subject || strip_space(node_text(src, ta.type)) != type_text do return nil, false

	#partial switch p in use.parents[n - 2].derived {
	case ^ast.Or_Else_Expr, ^ast.Or_Return_Expr, ^ast.Or_Branch_Expr:
		return nil, false
	case ^ast.Value_Decl:
		if len(p.values) == 1 && len(p.names) > 1 do return nil, false
	case ^ast.Assign_Stmt:
		if len(p.rhs) == 1 && len(p.lhs) > 1 do return nil, false
	case ^ast.Return_Stmt:
		if len(p.results) == 1 && results == 2 do return nil, false
	}
	return ta, true
}

// A variant that points at its data is written, sliced or called through a copy, so `switch v in s` serves
// and `&v` would refuse a subject that is not addressable. A named pointer type such as `P :: ^Foo` is not
// seen and still gets `&v`, which only fails on such a subject.
@(private = "file")
points_at_data :: proc(type_text: string) -> bool {
	for prefix in ([]string{"^", "[^]", "[]", "[dynamic]"}) {
		if strings.has_prefix(type_text, prefix) do return true
	}
	return false
}

// Slicing, a `->` call and a by-reference range loop take the address of their operand.
@(private = "file")
needs_address :: proc(node: ^ast.Expr, parent: ^ast.Node) -> bool {
	#partial switch p in parent.derived {
	case ^ast.Slice_Expr:
		return p.expr == node
	case ^ast.Selector_Expr:
		return p.expr == node && p.op.kind != .Period
	case ^ast.Range_Stmt:
		if p.expr != node do return false
		for val in p.vals {
			if unary, is_unary := val.derived.(^ast.Unary_Expr); is_unary && unary.op.kind == .And do return true
		}
	}
	return false
}

// `c := site` declaring one name.
@(private = "file")
is_alias :: proc(decl: ^ast.Value_Decl, value: ^ast.Expr) -> bool {
	if !decl.is_mutable || decl.type != nil || len(decl.names) != 1 || len(decl.values) != 1 do return false
	if decl.values[0] != value do return false
	name, is_ident := decl.names[0].derived.(^ast.Ident)
	return is_ident && name.name != "_"
}

// Deletes `c := &s.(T)` or `c := s.(T)` and writes the binding for each later use of c. A pointer
// alias keeps its pointer meaning: `c.x` and `c^` become `v.x` and `v`, any other use becomes `&v`.
@(private = "file")
remove_alias :: proc(m: ^Bind_Match, src: string, uses: []IdentUse, site: Site) -> bool {
	decl := site.decl
	alias := decl.names[0].derived.(^ast.Ident)
	start, end := whole_lines(src, decl.pos.offset, decl.end.offset)
	if (start > 0 && src[start - 1] != '\n') || (end < len(src) && src[end - 1] != '\n') do return false

	edits := make([dynamic]Bind_Edit, context.temp_allocator)
	for use in uses {
		if use.ident == alias || use.ident.name != alias.name || use.ident.pos.offset < decl.end.offset do continue
		if is_declaration(use) do return false
		target: ^ast.Expr = use.ident
		parent := use.parents[len(use.parents) - 1]
		value := Bind_Edit{use.ident.pos.offset, use.ident.end.offset, .Value}
		if site.form == .Value {
			if is_write(use) || needs_address(target, parent) do return false
			append(&edits, value)
			continue
		}
		#partial switch p in parent.derived {
		case ^ast.Selector_Expr:
			// `c->f()` passes the pointer itself.
			if p.expr == target && p.op.kind != .Period do return false
			if p.expr == target {
				append(&edits, value)
				continue
			}
		case ^ast.Index_Expr:
			if p.expr == target {
				append(&edits, value)
				continue
			}
		case ^ast.Slice_Expr:
			if p.expr == target {
				append(&edits, value)
				continue
			}
		case ^ast.Deref_Expr:
			append(&edits, Bind_Edit{p.pos.offset, p.end.offset, .Value})
			continue
		case ^ast.Unary_Expr:
			if p.op.kind == .And do return false
		case ^ast.Assign_Stmt:
			if slice.contains(p.lhs, target) do return false
		}
		append(&edits, Bind_Edit{use.ident.pos.offset, use.ident.end.offset, .Ref})
	}

	append(&m.edits, Bind_Edit{start, end, .Delete})
	append(&m.edits, ..edits[:])
	return true
}

// The use declares its name: a value declaration, a loop variable or a type switch binding.
@(private = "file")
is_declaration :: proc(use: IdentUse) -> bool {
	target: ^ast.Expr = use.ident
	i := len(use.parents) - 1
	if i >= 0 {
		if unary, is_unary := use.parents[i].derived.(^ast.Unary_Expr); is_unary && unary.op.kind == .And {
			target = unary
			i -= 1
		}
	}
	if i < 0 do return false
	#partial switch p in use.parents[i].derived {
	case ^ast.Value_Decl:
		return slice.contains(p.names, target)
	case ^ast.Range_Stmt:
		return slice.contains(p.vals, target)
	case ^ast.Inline_Range_Stmt:
		return p.val0 == target || p.val1 == target
	case ^ast.Assign_Stmt:
		return i > 0 && is_switch_tag(use.parents[i - 1], p) && slice.contains(p.lhs, target)
	}
	return false
}

@(private = "file")
is_switch_tag :: proc(node: ^ast.Node, assign: ^ast.Assign_Stmt) -> bool {
	ts, is_ts := node.derived.(^ast.Type_Switch_Stmt)
	return is_ts && rawptr(ts.tag) == rawptr(assign)
}

// A procedure literal cannot see the locals of the switch.
@(private = "file")
in_proc_lit :: proc(use: IdentUse) -> bool {
	for parent in use.parents {
		if _, is_lit := parent.derived.(^ast.Proc_Lit); is_lit do return true
	}
	return false
}

@(private = "file")
is_field_name :: proc(use: IdentUse) -> bool {
	if len(use.parents) == 0 do return false
	target: ^ast.Expr = use.ident
	#partial switch p in use.parents[len(use.parents) - 1].derived {
	case ^ast.Selector_Expr:
		return p.field == use.ident
	case ^ast.Implicit_Selector_Expr:
		return p.field == use.ident
	case ^ast.Field_Value:
		return p.field == target
	}
	return false
}
