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

	for j in from + 1 ..< len(stmts) {
		if next, values, ok := store(stmts[j]); ok && next.name == name.name {
			for value in values {
				if mentions(value, name.name) do return
			}
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
	}
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
