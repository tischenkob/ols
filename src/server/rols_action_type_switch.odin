#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:strings"

MAX_TYPE_SWITCH_CASES :: 8

// A type switch and the `if v, ok := u.(T); ok` chain of the same subject, `#partial`, and a default case.
@(private = "package")
add_type_switch_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_type_switch {
		return
	}
	if top := chain_at(ctx); top != nil {
		add_to_switch(ctx, top)
	}
	if n := switch_at(ctx); n != nil {
		add_switch_forms(ctx, n)
	}
}

// One `if v, ok := u.(T); ok {…}` of a chain.
Link :: struct {
	binding: string,
	flag:    string,
	subject: ^ast.Expr,
	type:    ^ast.Expr,
	body:    ^ast.Block_Stmt,
}

// The first `if` of the chain whose header holds the cursor. A cursor in a body means the code of that body.
chain_at :: proc(ctx: ^ActionContext) -> ^ast.If_Stmt {
	nodes := nodes_at(ctx.document.ast.decls[:], ctx.range.start)
	#reverse for at in nodes {
		#partial switch n in at.node.derived {
		case ^ast.Block_Stmt, ^ast.Proc_Lit:
			return nil
		case ^ast.If_Stmt:
			top := n
			parent := at.parent
			for parent != nil {
				above := parent.derived.(^ast.If_Stmt) or_break
				if above.else_stmt != top {
					break
				}
				top = above
				parent = parent_of_node(nodes, parent)
			}
			return top
		}
	}
	return nil
}

parse_link :: proc(cur: ^ast.If_Stmt) -> (link: Link, ok: bool) {
	if cur.label != nil || cur.init == nil || cur.cond == nil {
		return
	}
	body := cur.body.derived.(^ast.Block_Stmt) or_return
	if body.uses_do || breaks_enclosing(body) {
		return
	}
	decl := cur.init.derived.(^ast.Value_Decl) or_return
	if len(decl.names) != 2 || len(decl.values) != 1 || decl.type != nil || !decl.is_mutable {
		return
	}
	assertion := decl.values[0].derived.(^ast.Type_Assertion) or_return
	if assertion.type == nil {
		return
	}
	// `u.?` has a unary type.
	if _, inferred := assertion.type.derived.(^ast.Unary_Expr); inferred {
		return
	}
	binding := decl.names[0].derived.(^ast.Ident) or_return
	flag := decl.names[1].derived.(^ast.Ident) or_return
	cond := cur.cond.derived.(^ast.Ident) or_return
	if flag.name == "_" || cond.name != flag.name {
		return
	}
	return {binding.name, flag.name, assertion.expr, assertion.type, body}, true
}

add_to_switch :: proc(ctx: ^ActionContext, top: ^ast.If_Stmt) {
	src := ctx.document.ast.src
	links := make([dynamic]Link, context.temp_allocator)
	else_body: ^ast.Block_Stmt
	end := top.end.offset
	for cur := top; cur != nil; {
		link, link_ok := parse_link(cur)
		if !link_ok {
			return
		}
		append(&links, link)
		end = cur.end.offset
		if cur.else_stmt == nil {
			break
		}
		// A comment between the branches would have no place in the switch.
		body_end := link.body.end.offset
		if strings.trim_space(src[body_end:cur.else_pos.offset]) != "" ||
		   strings.trim_space(src[cur.else_pos.offset + len("else"):cur.else_stmt.pos.offset]) != "" {
			return
		}
		#partial switch e in cur.else_stmt.derived {
		case ^ast.If_Stmt:
			cur = e
			continue
		case ^ast.Block_Stmt:
			if breaks_enclosing(e) {
				return
			}
			else_body = e
			end = e.end.offset
		case:
			return
		}
		break
	}
	name, subject, ok := chain_names(src, links[:])
	if !ok || (len(links) > 1 && has_side_effect(subject)) || !bodies_fit_switch(links[:], else_body, name) {
		return
	}

	gather_locals_at(ctx, top.pos.offset)
	defer restore_locals(ctx)
	covered := make(map[string]struct{}, context.temp_allocator)
	for link in links {
		if type_name, named := get_used_switch_name(link.type); named {
			covered[type_name] = {}
		}
	}
	variants, _, resolved := subject_variants(ctx, subject)
	if !resolved {
		return
	}

	ind := get_line_indentation(src, top.pos.offset)
	sb := strings.builder_make(context.temp_allocator)
	if !covers_variants(variants, covered, len(links)) {
		strings.write_string(&sb, "#partial ")
	}
	fmt.sbprintf(&sb, "switch %s in %s {{", name, node_text(src, subject))
	for link in links {
		fmt.sbprintf(&sb, "\n%scase %s:", ind, node_text(src, link.type))
		write_case_body(&sb, src, link.body, ind)
	}
	if else_body != nil {
		fmt.sbprintf(&sb, "\n%scase:", ind)
		write_case_body(&sb, src, else_body, ind)
	}
	fmt.sbprintf(&sb, "\n%s}}", ind)
	append_replace_range(ctx, top.pos.offset, end, "Convert to type switch", strings.to_string(sb))
}

// The binding that the switch declares and its subject, when every link asserts on one subject, a different type, and
// binds that name or `_`. A subject that names a binding or a flag means something else in a later `else if`.
chain_names :: proc(src: string, links: []Link) -> (name: string, subject: ^ast.Expr, ok: bool) {
	name = "_"
	subject = links[0].subject
	want := strip_space(node_text(src, subject))
	types := make(map[string]struct{}, context.temp_allocator)
	for link in links {
		if strip_space(node_text(src, link.subject)) != want {
			return
		}
		if link.binding != "_" {
			if name != "_" && name != link.binding {
				return
			}
			name = link.binding
		}
		type := strip_space(node_text(src, link.type))
		if type in types {
			return
		}
		types[type] = {}
	}
	for use in collect_ident_uses(subject) {
		for link in links {
			if use.ident.name == link.flag || use.ident.name == link.binding {
				return
			}
		}
	}
	return name, subject, true
}

// The flag has no place in a switch, its binding cannot change, and a `case:` has no value of a single type.
bodies_fit_switch :: proc(links: []Link, else_body: ^ast.Block_Stmt, name: string) -> bool {
	flags := make(map[string]struct{}, context.temp_allocator)
	for link in links {
		flags[link.flag] = {}
	}
	for link in links {
		for use in collect_ident_uses(link.body) {
			if is_member_name(use) {
				continue
			}
			if use.ident.name in flags {
				return false
			}
			if use.ident.name == name && name != "_" && (link.binding == "_" || changes_binding(use, link.type)) {
				return false
			}
		}
	}
	if else_body != nil {
		for use in collect_ident_uses(else_body) {
			if is_member_name(use) {
				continue
			}
			if use.ident.name in flags || (use.ident.name == name && name != "_") {
				return false
			}
		}
	}
	return true
}

// What `odin check` rejects on the immutable binding of a type switch: a write, `&v`, `v->f()`, `v[:]` of an array and
// `for &e in v`.
changes_binding :: proc(use: IdentUse, type: ^ast.Expr) -> bool {
	if is_write(use) {
		return true
	}
	target: ^ast.Node = use.ident
	#reverse for parent in use.parents {
		#partial switch p in parent.derived {
		case ^ast.Selector_Expr:
			if p.expr != target {
				return false
			}
			if p.op.kind == .Arrow_Right {
				return true
			}
		case ^ast.Index_Expr:
			if p.expr != target {
				return false
			}
		case ^ast.Paren_Expr:
		case ^ast.Slice_Expr:
			return p.expr == target && !slices_when_immutable(type)
		case ^ast.Range_Stmt:
			if p.expr != target {
				return false
			}
			for val in p.vals {
				if unary, is_unary := val.derived.(^ast.Unary_Expr); is_unary && unary.op.kind == .And {
					return true
				}
			}
			return false
		case:
			return false
		}
		target = parent
	}
	return false
}

slices_when_immutable :: proc(type: ^ast.Expr) -> bool {
	#partial switch t in type.derived {
	case ^ast.Ident:
		return t.name == "string"
	case ^ast.Array_Type:
		return t.len == nil
	}
	return false
}

// The variants of a subject that is a union, with is_union false for an `any`. Anything else does not resolve: a
// pointer to a union binds a pointer in a switch and not in an assertion.
subject_variants :: proc(
	ctx: ^ActionContext,
	subject: ^ast.Expr,
) -> (
	variants: []^ast.Expr,
	is_union, resolved: bool,
) {
	reset_ast_context(ctx.ast_context)
	symbol, ok := resolve_type_expression(ctx.ast_context, subject)
	if !ok || symbol.pointers > 0 {
		return
	}
	#partial switch v in symbol.value {
	case SymbolUnionValue:
		return v.types, true, true
	case SymbolBasicValue:
		return nil, false, v.ident != nil && v.ident.name == "any"
	}
	return
}

// Whether the cases name each variant. A pointer and its element share a name, so the count of cases also has to reach
// the count of variants.
covers_variants :: proc(variants: []^ast.Expr, covered: map[string]struct{}, cases: int) -> bool {
	if cases < len(variants) {
		return false
	}
	for variant in variants {
		name, named := get_used_switch_name(variant)
		if !named || name not_in covered {
			return false
		}
	}
	return true
}

// The type switch whose header or `case` line holds the cursor. The cursor can also be on `#partial`, which sits before
// the node of the statement.
switch_at :: proc(ctx: ^ActionContext) -> ^ast.Type_Switch_Stmt {
	src := ctx.document.ast.src
	start := ctx.range.start
	line := start - (strings.last_index_byte(src[:start], '\n') + 1)
	word := strings.last_index(src[start - line:min(start + len("#partial"), len(src))], "#partial")
	if word >= 0 && word <= line && line <= word + len("#partial") {
		start = start - line + word + len("#partial")
		for start < len(src) && (src[start] == ' ' || src[start] == '\t') {
			start += 1
		}
	}
	#reverse for at in nodes_at(ctx.document.ast.decls[:], start) {
		#partial switch n in at.node.derived {
		case ^ast.Proc_Lit:
			return nil
		case ^ast.Case_Clause:
			if start > n.terminator.pos.offset {
				return nil
			}
		case ^ast.Type_Switch_Stmt:
			return n
		}
	}
	return nil
}

add_switch_forms :: proc(ctx: ^ActionContext, n: ^ast.Type_Switch_Stmt) {
	tag, is_assign := n.tag.derived.(^ast.Assign_Stmt)
	block, is_block := n.body.derived.(^ast.Block_Stmt)
	if !is_assign || !is_block || len(tag.rhs) != 1 {
		return
	}
	subject := tag.rhs[0]
	gather_locals_at(ctx, n.pos.offset)
	defer restore_locals(ctx)
	variants, is_union, resolved := subject_variants(ctx, subject)

	add_default_case(ctx, n, block)
	if is_union {
		add_partial_form(ctx, n, block, variants)
	}
	if resolved {
		add_to_chain(ctx, n, tag, block, subject)
	}
}

add_default_case :: proc(ctx: ^ActionContext, n: ^ast.Type_Switch_Stmt, block: ^ast.Block_Stmt) {
	src := ctx.document.ast.src
	ind := get_line_indentation(src, n.pos.offset)
	for stmt in block.stmts {
		clause := stmt.derived.(^ast.Case_Clause) or_continue
		if len(clause.list) == 0 {
			return
		}
		ind = get_line_indentation(src, clause.pos.offset)
	}
	line_start, line_end := before_on_line(src, block.end.offset - 1)
	if line_end != line_start {
		return
	}
	append_insert(ctx, line_start, "Add default case", "refactor.rewrite", fmt.tprintf("%scase:\n", ind))
}

add_partial_form :: proc(
	ctx: ^ActionContext,
	n: ^ast.Type_Switch_Stmt,
	block: ^ast.Block_Stmt,
	variants: []^ast.Expr,
) {
	if !n.partial {
		offset := n.switch_pos.offset
		append_insert(ctx, offset, "Add #partial", "refactor.rewrite", "#partial ")
		return
	}
	start, written := partial_start(ctx.document.ast.src, n.pos.offset)
	if !written {
		return
	}
	covered := make(map[string]struct{}, context.temp_allocator)
	cases := 0
	for stmt in block.stmts {
		clause := stmt.derived.(^ast.Case_Clause) or_continue
		for type in clause.list {
			if name, named := get_used_switch_name(type); named && name != "nil" {
				covered[name] = {}
				cases += 1
			}
		}
	}
	if covers_variants(variants, covered, cases) {
		append_replace_range(ctx, start, n.pos.offset, "Remove #partial", "")
	}
}

add_to_chain :: proc(
	ctx: ^ActionContext,
	n: ^ast.Type_Switch_Stmt,
	tag: ^ast.Assign_Stmt,
	block: ^ast.Block_Stmt,
	subject: ^ast.Expr,
) {
	if n.label != nil || len(tag.lhs) != 1 || len(block.stmts) == 0 || len(block.stmts) > MAX_TYPE_SWITCH_CASES {
		return
	}
	binding, named := tag.lhs[0].derived.(^ast.Ident)
	if !named || !takes_assertion(subject) {
		return
	}
	src := ctx.document.ast.src
	start := n.pos.offset
	if n.partial {
		written: bool
		start, written = partial_start(src, n.pos.offset)
		if !written {
			return
		}
	}

	used := make(map[string]struct{}, context.temp_allocator)
	for use in collect_ident_uses(subject) {
		if use.ident.name == binding.name {
			return
		}
		used[use.ident.name] = {}
	}
	clauses := make([]^ast.Case_Clause, len(block.stmts), context.temp_allocator)
	for stmt, i in block.stmts {
		clause, is_clause := stmt.derived.(^ast.Case_Clause)
		if !is_clause {
			return
		}
		clauses[i] = clause
		is_default := len(clause.list) == 0
		if (is_default && i != len(block.stmts) - 1) ||
		   len(clause.list) > 1 ||
		   breaks_enclosing(clause) ||
		   has_fallthrough(clause) {
			return
		}
		if !is_default {
			if type, is_ident := clause.list[0].derived.(^ast.Ident); is_ident && type.name == "nil" {
				return
			}
		}
		for inner in clause.body {
			for use in collect_ident_uses(inner) {
				if is_member_name(use) {
					continue
				}
				if is_default && use.ident.name == binding.name {
					return
				}
				used[use.ident.name] = {}
			}
		}
	}
	branches := len(clauses)
	if len(clauses[branches - 1].list) == 0 {
		branches -= 1
	}
	if branches == 0 || (branches > 1 && has_side_effect(subject)) {
		return
	}

	probe := position_ident(n, "ok")
	for i := 2; (probe.name in used) || is_taken(ctx, probe^); i += 1 {
		probe.name = fmt.tprintf("ok%d", i)
	}
	ind := get_line_indentation(src, n.pos.offset)
	unit := indent_unit(src, ind, nil)
	sb := strings.builder_make(context.temp_allocator)
	for clause, i in clauses {
		switch {
		case len(clause.list) == 0:
			strings.write_string(&sb, " else {")
		case:
			if i > 0 {
				strings.write_string(&sb, " else ")
			}
			name := binds_in(clause, binding.name) ? binding.name : "_"
			fmt.sbprintf(
				&sb,
				"if %s, %s := %s.(%s); %s {{",
				name,
				probe.name,
				node_text(src, subject),
				node_text(src, clause.list[0]),
				probe.name,
			)
		}
		next := i + 1 < len(clauses) ? clauses[i + 1].pos.offset : block.end.offset - 1
		lines, lines_ok := clause_lines(src, clause, next, ind, unit)
		if !lines_ok {
			return
		}
		if lines != "" {
			fmt.sbprintf(&sb, "\n%s", lines)
		}
		fmt.sbprintf(&sb, "\n%s}}", ind)
	}
	append_replace_range(ctx, start, n.end.offset, "Convert to if chain", strings.to_string(sb))
}

// A chained assertion puts the subject before a `.(T)`.
takes_assertion :: proc(subject: ^ast.Expr) -> bool {
	#partial switch _ in subject.derived {
	case ^ast.Ident, ^ast.Selector_Expr, ^ast.Index_Expr, ^ast.Deref_Expr, ^ast.Call_Expr, ^ast.Paren_Expr:
		return true
	}
	return false
}

binds_in :: proc(clause: ^ast.Case_Clause, name: string) -> bool {
	if name == "_" {
		return false
	}
	for inner in clause.body {
		for use in collect_ident_uses(inner) {
			if use.ident.name == name && !is_member_name(use) {
				return true
			}
		}
	}
	return false
}

has_fallthrough :: proc(clause: ^ast.Case_Clause) -> bool {
	found := false
	visitor := ast.Visitor {
		data = &found,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			#partial switch n in node.derived {
			case ^ast.Proc_Lit, ^ast.Switch_Stmt, ^ast.Type_Switch_Stmt:
				return nil
			case ^ast.Branch_Stmt:
				if n.tok.kind == .Fallthrough {
					(^bool)(visitor.data)^ = true
				}
			}
			return visitor
		},
	}
	ast.walk(&visitor, clause)
	return found
}

// The lines of a case body, one level below ind. The text runs to the line of the next case, so a comment stays.
clause_lines :: proc(
	src: string,
	clause: ^ast.Case_Clause,
	next: int,
	ind, unit: string,
) -> (
	lines: string,
	ok: bool,
) {
	next_line, _ := before_on_line(src, next)
	from := clause.terminator.pos.offset + 1
	if next_line < from {
		return "", false
	}
	inner := trim_block_text(src[from:next_line])
	want := strings.concatenate({ind, unit}, context.temp_allocator)
	if inner == "" {
		return "", true
	}
	if !strings.contains_any(inner, "\r\n") && !strings.has_prefix(inner, want) {
		return strings.concatenate({want, inner}, context.temp_allocator), true
	}
	if len(clause.body) == 0 {
		return inner, true
	}
	deeper := get_line_indentation(src, clause.body[0].pos.offset)
	if deeper == want {
		return inner, true
	}
	if has_multiline_string(inner) {
		return "", false
	}
	return reindent(inner, deeper, want), true
}
