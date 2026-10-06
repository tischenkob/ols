package server

import "core:fmt"
import "core:odin/ast"

import "src:common"

lint_dead_store :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_dead_store do return

	#partial switch n in node.derived {
	case ^ast.Block_Stmt:
		check_stmts(ctx, n.stmts, diags)
	case ^ast.Case_Clause:
		check_stmts(ctx, n.body, diags)
	case ^ast.Proc_Lit:
		// A parameter is a store the body can overwrite before reading.
		if n.body == nil || n.type == nil || n.type.params == nil do return
		body := n.body.derived.(^ast.Block_Stmt) or_else nil
		if body == nil do return
		for param in n.type.params.list {
			if .Using in param.flags do continue
			for name in param.names {
				if ident, is_ident := name.derived.(^ast.Ident); is_ident {
					dead_store(ctx, body.stmts, -1, ident, diags)
				}
			}
		}
	case ^ast.Range_Stmt:
		body := n.body.derived.(^ast.Block_Stmt) or_else nil
		if body == nil do return
		for val in n.vals {
			// `for &v in` iterates by pointer, so writes to v are not lost.
			if ident, is_ident := val.derived.(^ast.Ident); is_ident {
				copy_write(ctx, body.stmts, -1, ident, diags)
			}
		}
	}
}

@(private = "file")
check_stmts :: proc(ctx: ^LintContext, stmts: []^ast.Stmt, diags: ^[dynamic]Diagnostic) {
	for stmt, i in stmts {
		if name, _, ok := store(stmt); ok {
			dead_store(ctx, stmts, i, name, diags)
		}
		if name, ok := copy_decl(stmt); ok {
			copy_write(ctx, stmts, i, name, diags)
		}
	}
}

// `x := e` or `x = e`: one name, one plain assignment.
@(private = "file")
store :: proc(stmt: ^ast.Stmt) -> (name: ^ast.Ident, values: []^ast.Expr, ok: bool) {
	#partial switch s in stmt.derived {
	case ^ast.Value_Decl:
		if !s.is_mutable || len(s.names) != 1 || len(s.values) != 1 do return
		name = s.names[0].derived.(^ast.Ident) or_return
		return name, s.values, true
	case ^ast.Assign_Stmt:
		if s.op.kind != .Eq || len(s.lhs) != 1 do return
		name = s.lhs[0].derived.(^ast.Ident) or_return
		return name, s.rhs, true
	}
	return
}

// The store at index `from` (-1 for a parameter) is dead when a later statement of the same
// list overwrites the name and nothing in between mentions it.
@(private = "file")
dead_store :: proc(ctx: ^LintContext, stmts: []^ast.Stmt, from: int, name: ^ast.Ident, diags: ^[dynamic]Diagnostic) {
	if name.name == "_" do return

	// Only an assignment can store to a named result; a declaration or a parameter (from == -1) cannot.
	assigns := false
	if from >= 0 do _, assigns = stmts[from].derived.(^ast.Assign_Stmt)
	named := assigns && is_named_result(enclosing_proc(ctx, name), name.name)

	exits := false
	for j in from + 1 ..< len(stmts) {
		if next, values, ok := store(stmts[j]); ok && next.name == name.name {
			for value in values {
				if mentions(value, name.name) do return
			}
			if !is_local_store(ctx, next) || address_taken(ctx, name) || using_field(ctx, name) do return
			// A `defer` runs before the overwrite only through an exit between the two stores.
			if exits && deferred_mention(ctx.document, enclosing_proc(ctx, name), name) do return
			append(
				diags,
				Diagnostic {
					range = common.get_token_range(name, ctx.src),
					severity = .Warning,
					code = "dead-store",
					message = fmt.tprintf("value stored in '%s' is never read", name.name),
				},
			)
			return
		}
		if mentions(stmts[j], name.name) do return
		// A bare `return` reads the named results.
		if named do for ret in body_returns(stmts[j]) do if len(ret.results) == 0 do return
		exits = exits || has_exit(stmts[j])
	}
}

// A `return`, `break`, `continue` or other branch inside stmt, which runs pending defers.
@(private = "file")
has_exit :: proc(stmt: ^ast.Stmt) -> bool {
	found := false
	visitor := ast.Visitor {
		data = &found,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			found := (^bool)(visitor.data)
			if node == nil || found^ do return nil
			#partial switch _ in node.derived {
			case ^ast.Proc_Lit:
				return nil
			case ^ast.Return_Stmt, ^ast.Branch_Stmt:
				found^ = true
				return nil
			}
			return visitor
		},
	}
	ast.walk(&visitor, stmt)
	return found
}

// The innermost procedure literal around the name.
@(private = "file")
enclosing_proc :: proc(ctx: ^LintContext, name: ^ast.Ident) -> ^ast.Proc_Lit {
	top := top_level_stmt_at(ctx.document.ast.decls[:], name.pos.offset)
	if top == nil do return nil
	lit: ^ast.Proc_Lit
	for at in nodes_at({top}, name.pos.offset) {
		if inner, ok := at.node.derived.(^ast.Proc_Lit); ok do lit = inner
	}
	return lit
}

@(private = "file")
is_named_result :: proc(lit: ^ast.Proc_Lit, name: string) -> bool {
	if lit == nil || lit.type == nil || lit.type.results == nil do return false
	for field in lit.type.results.list {
		for result in field.names {
			if ident, ok := result.derived.(^ast.Ident); ok && ident.name == name do return true
		}
	}
	return false
}

// A `defer` registered before the store runs at a later exit and can read it. One written after
// the store is not pending when the store runs, and neither is one in a block that closed before
// it; a `when` body is no block. A defer whose name a declaration between it and the store shadows
// reads another variable. An unknown procedure counts as read.
@(private = "file")
deferred_mention :: proc(document: ^Document, lit: ^ast.Proc_Lit, name: ^ast.Ident) -> bool {
	if lit == nil || lit.body == nil do return true
	Data :: struct {
		document: ^Document,
		body:     ^ast.Node,
		name:     ^ast.Ident,
		found:    bool,
	}
	data := Data {
		document = document,
		body     = lit.body,
		name     = name,
	}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil || data.found || node.pos.offset >= data.name.pos.offset do return nil
			#partial switch n in node.derived {
			case ^ast.Proc_Lit:
				return nil
			case ^ast.When_Stmt:
				walk_when_body(visitor, n)
				return nil
			case ^ast.Defer_Stmt:
				if !mentions(n.stmt, data.name.name) do return nil
				// The store names a declaration made after the defer, so the defer reads another variable.
				visible := visible_declaration(data.document, data.body, data.name.name, data.name.pos.offset)
				data.found = visible.ident == nil || visible.ident.pos.offset < n.pos.offset
				return nil
			}
			// A defer in a block that ended before the store already ran.
			if !scope_open(node, data.name.pos.offset) do return nil
			return visitor
		},
	}
	ast.walk(&visitor, lit.body)
	return data.found
}

// A field that `using` brings into scope belongs to a value that outlives the store. The resolver
// gives such a field the .Local flag, so is_local_store does not see it.
@(private = "file")
using_field :: proc(ctx: ^LintContext, name: ^ast.Ident) -> bool {
	lit := enclosing_proc(ctx, name)
	return lit != nil && visible_declaration(ctx.document, lit, name.name, name.pos.offset).through_using
}

// Only a local can hold a dead store: a global is readable from any procedure. An identifier
// that does not resolve is assumed to be a local, as before.
@(private = "file")
is_local_store :: proc(ctx: ^LintContext, ident: ^ast.Ident) -> bool {
	resolved, ok := lint_symbols(ctx)[uintptr(ident)]
	return !ok || resolved.is_unresolved || .Local in resolved.symbol.flags
}

// `&x`, `&x.f` or `&x[i]` in the declaration that holds `name`: the pointer can read x at any later
// point. A local is only visible inside its top-level declaration, and the match is by name.
@(private = "file")
address_taken :: proc(ctx: ^LintContext, name: ^ast.Ident) -> bool {
	for decl in ctx.document.ast.decls {
		if name.pos.offset < decl.pos.offset || name.pos.offset >= decl.end.offset do continue
		for use in collect_ident_uses(decl) {
			if use.ident.name != name.name do continue
			child: ^ast.Node = use.ident
			#reverse for parent in use.parents {
				#partial switch p in parent.derived {
				case ^ast.Selector_Expr:
					if cast(^ast.Node)p.expr != child do break
					child = parent
					continue
				case ^ast.Index_Expr:
					if cast(^ast.Node)p.expr != child do break
					child = parent
					continue
				case ^ast.Paren_Expr:
					child = parent
					continue
				case ^ast.Unary_Expr:
					if p.op.kind == .And do return true
				}
				break
			}
		}
	}
	return false
}

// `x := arr[i]` or `x := arr[i].field`: a copy of an element, not a pointer into it.
@(private = "file")
copy_decl :: proc(stmt: ^ast.Stmt) -> (name: ^ast.Ident, ok: bool) {
	decl := stmt.derived.(^ast.Value_Decl) or_return
	if !decl.is_mutable || len(decl.names) != 1 || len(decl.values) != 1 do return
	name = decl.names[0].derived.(^ast.Ident) or_return
	return name, indexes(decl.values[0])
}

@(private = "file")
indexes :: proc(expr: ^ast.Expr) -> bool {
	#partial switch e in unparen(expr).derived {
	case ^ast.Index_Expr:
		return true
	case ^ast.Selector_Expr:
		return indexes(e.expr)
	}
	return false
}

// `x.field = …` on a copy declared at index `from` (-1 for a range value), with nothing
// reading x after the last such write.
@(private = "file")
copy_write :: proc(ctx: ^LintContext, stmts: []^ast.Stmt, from: int, name: ^ast.Ident, diags: ^[dynamic]Diagnostic) {
	if name.name == "_" do return

	first, last: ^ast.Ident
	last_index := -1
	for j in from + 1 ..< len(stmts) {
		root, ok := field_write_root(stmts[j])
		if !ok || root.name != name.name do continue
		if first == nil do first = root
		last, last_index = root, j
	}
	if first == nil do return

	for j in last_index + 1 ..< len(stmts) {
		if mentions(stmts[j], name.name) do return
	}

	// `p := &arr[i]` writes through, so a pointer is never a lost copy.
	if resolved, ok := lint_symbols(ctx)[uintptr(last)];
	   ok && !resolved.is_unresolved && resolved.symbol.pointers > 0 {
		return
	}

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(first, ctx.src),
			severity = .Warning,
			code = "unused-copy-write",
			message = fmt.tprintf("'%s' is a copy; writes to it are lost", name.name),
		},
	)
}

// The root identifier of a plain selector assignment. An index or dereference in the chain
// writes through a pointer, so those are not roots.
@(private = "file")
field_write_root :: proc(stmt: ^ast.Stmt) -> (root: ^ast.Ident, ok: bool) {
	assign := stmt.derived.(^ast.Assign_Stmt) or_return
	if len(assign.lhs) != 1 do return
	sel := unparen(assign.lhs[0]).derived.(^ast.Selector_Expr) or_return

	expr := unparen(sel.expr)
	for {
		#partial switch e in expr.derived {
		case ^ast.Ident:
			return e, true
		case ^ast.Selector_Expr:
			expr = unparen(e.expr)
		case:
			return
		}
	}
}

@(private = "file")
mentions :: proc(node: ^ast.Node, name: string) -> bool {
	for use in collect_ident_uses(node) {
		if use.ident.name == name do return true
	}
	return false
}
