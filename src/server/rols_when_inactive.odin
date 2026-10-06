package server

import "core:odin/ast"
import "core:strconv"

import "src:common"

// The value declarations of file in a `when` branch that the editor's target does not build. The conditions
// evaluate as the editor evaluates them: profile os, arch and defines, else the host, and the constants of the
// file. The evaluator reads a name it does not know as false, so a chain counts only up to its first condition
// with such a name, such as ODIN_DEBUG, ODIN_TEST or a constant of another file or package: that branch and the
// ones after it are not reported. Allocates in context.allocator.
inactive_when_decls :: proc(file: ^ast.File) -> map[^ast.Value_Decl]struct{} {
	inactive := make(map[^ast.Value_Decl]struct{})
	has_when := false
	for decl in file.decls {
		if _, is_when := decl.derived.(^ast.When_Stmt); is_when do has_when = true
	}
	if !has_when do return inactive

	ast_context := make_ast_context(file^, nil, file.pkg_name, "", file.fullpath, context.allocator)
	get_globals(file^, &ast_context)
	consts := make_when_expr_map()
	register_when_consts_from_globals(&consts, ast_context.globals)
	// The constants outside any `when`: one inside a branch may come from a branch that an unknown name chose.
	plain := make(map[string]^ast.Expr)
	for decl in file.decls {
		value_decl := decl.derived.(^ast.Value_Decl) or_continue
		if value_decl.is_mutable do continue
		for name, i in value_decl.names {
			ident := name.derived.(^ast.Ident) or_continue
			if i < len(value_decl.values) do plain[ident.name] = value_decl.values[i]
		}
	}
	for decl in file.decls {
		walk_when_decls(decl, &ast_context, consts, plain, &inactive)
	}
	return inactive
}

@(private = "file")
walk_when_decls :: proc(
	stmt: ^ast.Stmt,
	ast_context: ^AstContext,
	consts: map[string]When_Expr,
	plain: map[string]^ast.Expr,
	inactive: ^map[^ast.Value_Decl]struct{},
) {
	if stmt == nil do return
	#partial switch s in stmt.derived {
	case ^ast.Block_Stmt:
		for inner in s.stmts do walk_when_decls(inner, ast_context, consts, plain, inactive)
	case ^ast.Foreign_Block_Decl:
		walk_when_decls(s.body, ast_context, consts, plain, inactive)
	case ^ast.When_Stmt:
		// active_when_block reads an unknown name as false, so it decides only while every condition before
		// the active branch is known.
		active, _ := active_when_block(ast_context, s, consts)
		State :: enum {
			Searching,
			Unknown,
			Passed,
		}
		state := State.Searching
		for branch: ^ast.Stmt = s; branch != nil; {
			when_branch, is_when := branch.derived.(^ast.When_Stmt)
			body := when_branch.body if is_when else branch
			if state == .Searching && is_when && !when_known(when_branch.cond, plain, 0) {
				state = .Unknown
			}
			block, is_block := body.derived.(^ast.Block_Stmt)
			if state == .Unknown || state == .Searching && is_block && block == active {
				walk_when_decls(body, ast_context, consts, plain, inactive)
				if state == .Searching do state = .Passed
			} else {
				mark_when_decls(body, inactive)
			}
			branch = when_branch.else_stmt if is_when else nil
		}
	}
}

// Adds every value declaration under stmt to inactive.
@(private = "file")
mark_when_decls :: proc(stmt: ^ast.Stmt, inactive: ^map[^ast.Value_Decl]struct{}) {
	if stmt == nil do return
	#partial switch s in stmt.derived {
	case ^ast.Value_Decl:
		inactive[s] = {}
	case ^ast.Block_Stmt:
		for inner in s.stmts do mark_when_decls(inner, inactive)
	case ^ast.Foreign_Block_Decl:
		mark_when_decls(s.body, inactive)
	case ^ast.When_Stmt:
		mark_when_decls(s.body, inactive)
		mark_when_decls(s.else_stmt, inactive)
	}
}

// Whether the when evaluator knows every name in expr: ODIN_OS, ODIN_ARCH, the profile defines, literals,
// enum members and the constants of the file outside any `when` whose values it knows in turn. A selector such
// as pkg.FLAG counts as unknown.
@(private = "file")
when_known :: proc(expr: ^ast.Expr, plain: map[string]^ast.Expr, depth: int) -> bool {
	if expr == nil || depth > 8 do return false
	#partial switch e in expr.derived {
	case ^ast.Paren_Expr:
		return when_known(e.expr, plain, depth)
	case ^ast.Ident:
		switch e.name {
		case "ODIN_OS", "ODIN_ARCH", "true", "false":
			return true
		}
		if e.name in common.config.profile.defines do return true
		if _, is_int := strconv.parse_int(e.name); is_int do return true
		value, is_plain := plain[e.name]
		return is_plain && when_known(value, plain, depth + 1)
	case ^ast.Basic_Lit, ^ast.Implicit_Selector_Expr:
		return true
	case ^ast.Call_Expr:
		directive, is_directive := e.expr.derived.(^ast.Basic_Directive)
		if !is_directive || directive.name != "config" || len(e.args) != 2 do return false
		if name, is_ident := e.args[0].derived.(^ast.Ident); is_ident && name.name in common.config.profile.defines {
			return true
		}
		return when_known(e.args[1], plain, depth)
	case ^ast.Unary_Expr:
		return e.op.kind == .Not && when_known(e.expr, plain, depth)
	case ^ast.Binary_Expr:
		return when_known(e.left, plain, depth) && when_known(e.right, plain, depth)
	}
	return false
}
