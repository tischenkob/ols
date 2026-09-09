package server

import "core:fmt"
import "core:odin/ast"

import "src:common"

lint_recursion :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_recursion do return

	decl, is_decl := node.derived.(^ast.Value_Decl)
	if !is_decl || len(decl.names) != 1 || len(decl.values) != 1 do return
	name, is_ident := decl.names[0].derived.(^ast.Ident)
	if !is_ident do return
	proc_lit, is_proc := decl.values[0].derived.(^ast.Proc_Lit)
	if !is_proc || proc_lit.body == nil do return
	body, is_block := proc_lit.body.derived.(^ast.Block_Stmt)
	if !is_block do return

	for stmt in body.stmts {
		stmt := stmt
		// A defer runs when the body ends, so its statement is as unconditional as the defer.
		if defer_stmt, is_defer := stmt.derived.(^ast.Defer_Stmt); is_defer do stmt = defer_stmt.stmt

		if contains_or_expr(stmt) do return

		#partial switch _ in stmt.derived {
		case ^ast.If_Stmt,
		     ^ast.Switch_Stmt,
		     ^ast.Type_Switch_Stmt,
		     ^ast.When_Stmt,
		     ^ast.For_Stmt,
		     ^ast.Range_Stmt,
		     ^ast.Branch_Stmt:
			return
		case ^ast.Expr_Stmt, ^ast.Return_Stmt, ^ast.Value_Decl, ^ast.Assign_Stmt:
			if call := unconditional_self_call(stmt, name.name); call != nil {
				append(
					diags,
					Diagnostic {
						range = common.get_token_range(call, ctx.src),
						severity = .Warning,
						code = "infinite-recursion",
						message = fmt.tprintf("'%s' calls itself unconditionally", name.name),
					},
				)
				return
			}
			if _, is_return := stmt.derived.(^ast.Return_Stmt); is_return do return
		}
	}
}

@(private = "file")
contains_or_expr :: proc(stmt: ^ast.Stmt) -> (found: bool) {
	visitor := ast.Visitor {
		data = &found,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			#partial switch _ in node.derived {
			case ^ast.Or_Else_Expr, ^ast.Or_Return_Expr, ^ast.Or_Branch_Expr:
				(^bool)(visitor.data)^ = true
				return nil
			}
			return visitor
		},
	}
	ast.walk(&visitor, stmt)
	return
}

// A call to `name` the statement always reaches: not deferred to a proc literal, not on a
// branch of a ternary, an `or_else` fallback or the right side of `&&` / `||`.
@(private = "file")
unconditional_self_call :: proc(stmt: ^ast.Stmt, name: string) -> ^ast.Call_Expr {
	uses: for use in collect_ident_uses(stmt) {
		if use.ident.name != name || len(use.parents) == 0 do continue
		call, is_call := use.parents[len(use.parents) - 1].derived.(^ast.Call_Expr)
		if !is_call || call.expr != cast(^ast.Expr)use.ident do continue

		for parent, i in use.parents {
			child: ^ast.Node = use.ident if i == len(use.parents) - 1 else use.parents[i + 1]
			#partial switch p in parent.derived {
			case ^ast.Proc_Lit:
				continue uses
			case ^ast.Ternary_If_Expr:
				if child == p.x || child == p.y do continue uses
			case ^ast.Ternary_When_Expr:
				if child == p.x || child == p.y do continue uses
			case ^ast.Or_Else_Expr:
				if child == p.y do continue uses
			case ^ast.Binary_Expr:
				if (p.op.kind == .Cmp_And || p.op.kind == .Cmp_Or) && child == p.right do continue uses
			}
		}
		return call
	}
	return nil
}
