package server

import "core:fmt"
import "core:mem"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:strings"

import "src:common"

// The files of a package directory, whose constants inactive_when_decls reads besides those of the evaluated file.
// The table is built on first use, in allocator, from the files that the evaluated target builds and that share
// the `package` clause of the first file that needs it.
When_Package :: struct {
	files:     []string,
	allocator: mem.Allocator,
	built:     bool,
	pkg_name:  string,
	// The constants outside any `when` of those files, by name.
	plain:     map[string]^ast.Expr,
}

// The value declarations of file in a `when` branch that the editor's target does not build. The conditions
// evaluate as the editor evaluates them, with the target of set_when_target first: profile os, arch and defines,
// else the host, and the constants of the file, or of every file of pkg when given. Only `!`, comparisons, `&&` and `||` fold; other operators count as
// unknown. The evaluator reads a name it does not know as false, so a chain counts only up to its first condition
// with such a name, such as ODIN_DEBUG, ODIN_TEST or a constant of another package: that branch and the ones after
// it are not reported. Allocates in context.allocator.
inactive_when_decls :: proc(file: ^ast.File, pkg: ^When_Package = nil) -> map[^ast.Value_Decl]struct{} {
	inactive := make(map[^ast.Value_Decl]struct{})
	// The walk below reaches `when` statements at file scope and in foreign blocks.
	has_when := false
	for decl in file.decls {
		#partial switch d in decl.derived {
		case ^ast.When_Stmt:
			has_when = true
		case ^ast.Foreign_Block_Decl:
			body := d.body.derived.(^ast.Block_Stmt) or_continue
			for stmt in body.stmts {
				if _, is_when := stmt.derived.(^ast.When_Stmt); is_when do has_when = true
			}
		}
	}
	if !has_when do return inactive

	ast_context := make_ast_context(file^, nil, file.pkg_name, "", file.fullpath, context.allocator)
	consts := make_when_expr_map()
	// The constants outside any `when`: one inside a branch may come from a branch that an unknown name chose.
	plain := make(map[string]^ast.Expr)
	add_plain_consts(&plain, file)
	// The package table costs a parse of the directory, so only a condition that another file can decide reads it.
	if pkg != nil && needs_package(file.decls[:], plain) {
		if !pkg.built do build_when_package(pkg, file.pkg_name)
		if pkg.pkg_name == file.pkg_name {
			for name, value in pkg.plain do if name not_in plain do plain[name] = value
		}
	}
	fold_plain_consts(&consts, plain)
	get_globals(file^, &ast_context)
	register_when_consts_from_globals(&consts, ast_context.globals)
	for decl in file.decls {
		walk_when_decls(decl, &ast_context, consts, plain, &inactive)
	}
	return inactive
}

// The target that set_when_target chose for the `when` evaluation of this thread, which resolve_when_ident and
// host_target read before the profile. Thread-local, so a CLI query in a test does not move other tests' targets.
@(thread_local)
when_target: Maybe(parser.Build_Target)

// Points the `when` evaluation of this thread at the `-target:` of checker_args when it has one. It returns the
// previous target, which the caller puts back.
set_when_target :: proc(checker_args: string) -> (saved: Maybe(parser.Build_Target)) {
	saved = when_target
	if strings.contains(checker_args, "-target:") do when_target = base_target(checker_args)
	return
}

// The value of ODIN_OS or ODIN_ARCH under the target of set_when_target, spelled as resolve_when_ident spells it.
when_target_ident :: proc(ident: string) -> (value: When_Expr, ok: bool) {
	target := when_target.? or_return
	switch ident {
	case "ODIN_OS":
		return fmt.tprint(target.os), true
	case "ODIN_ARCH":
		return fmt.tprint(target.arch), true
	}
	return nil, false
}

// Fills the table of pkg from its files that the evaluated target builds and whose `package` clause is pkg_name.
@(private = "file")
build_when_package :: proc(pkg: ^When_Package, pkg_name: string) {
	context.allocator = pkg.allocator
	pkg.built = true
	pkg.pkg_name = strings.clone(pkg_name)
	pkg.plain = make(map[string]^ast.Expr)
	target := host_target()
	for path in pkg.files {
		data, err := os.read_entire_file(path, context.allocator)
		if err != nil || !builds_on(path, string(data), target) do continue
		file, ok := parse_syntax(path, string(data))
		if ok && file.pkg_name == pkg_name do add_plain_consts(&pkg.plain, &file)
	}
}

// Folds the constants of plain into consts, each one after the constants its value names, since the evaluator
// reads a name it has not folded yet as false. A value that when_known rejects stays out, and so does a name that
// consts already holds, such as a profile define.
@(private = "file")
fold_plain_consts :: proc(consts: ^map[string]When_Expr, plain: map[string]^ast.Expr) {
	folded := make(map[string]^ast.Expr, context.temp_allocator)
	// Only a value that when_known accepts with every constant in view can fold at all.
	candidates := make([dynamic]string, context.temp_allocator)
	for name, value in plain {
		if name in consts^ {
			folded[name] = value
		} else if when_known(value, plain, 0) {
			append(&candidates, name)
		}
	}
	for added := true; added; {
		added = false
		for name in candidates {
			value := plain[name]
			if name in folded || !when_known(value, folded, 0) do continue
			register_when_const(consts, name, value)
			folded[name] = value
			added = true
		}
	}
}

// Whether a condition of the `when` statements among stmts, nested ones included, is unknown and names a constant
// that another file of the package may declare.
@(private = "file")
needs_package :: proc(stmts: []^ast.Stmt, plain: map[string]^ast.Expr) -> bool {
	for stmt in stmts {
		if stmt == nil do continue
		#partial switch s in stmt.derived {
		case ^ast.Block_Stmt:
			if needs_package(s.stmts[:], plain) do return true
		case ^ast.Foreign_Block_Decl:
			if needs_package({s.body}, plain) do return true
		case ^ast.When_Stmt:
			if !when_known(s.cond, plain, 0) && names_missing_const(s.cond, plain, 0) do return true
			if needs_package({s.body, s.else_stmt}, plain) do return true
		}
	}
	return false
}

// Whether expr, or a constant of plain that it names, names a bare identifier that is neither in plain nor an
// ODIN_* builtin or profile define. A selector such as pkg.FLAG reads another package, so it does not count.
@(private = "file")
names_missing_const :: proc(expr: ^ast.Expr, plain: map[string]^ast.Expr, depth: int) -> bool {
	if expr == nil || depth > 8 do return false
	#partial switch e in expr.derived {
	case ^ast.Paren_Expr:
		return names_missing_const(e.expr, plain, depth)
	case ^ast.Ident:
		if strings.has_prefix(e.name, "ODIN_") || e.name == "true" || e.name == "false" do return false
		if e.name in common.config.profile.defines do return false
		value, is_plain := plain[e.name]
		return !is_plain || names_missing_const(value, plain, depth + 1)
	case ^ast.Call_Expr:
		return len(e.args) == 2 && names_missing_const(e.args[1], plain, depth)
	case ^ast.Unary_Expr:
		return names_missing_const(e.expr, plain, depth)
	case ^ast.Binary_Expr:
		return names_missing_const(e.left, plain, depth) || names_missing_const(e.right, plain, depth)
	}
	return false
}

// Adds the constants of file outside any `when` to plain, by name.
@(private = "file")
add_plain_consts :: proc(plain: ^map[string]^ast.Expr, file: ^ast.File) {
	for decl in file.decls {
		value_decl := decl.derived.(^ast.Value_Decl) or_continue
		if value_decl.is_mutable do continue
		for name, i in value_decl.names {
			ident := name.derived.(^ast.Ident) or_continue
			if i < len(value_decl.values) do plain[ident.name] = value_decl.values[i]
		}
	}
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
// enum members and the constants of the file or package outside any `when` whose values it knows in turn. A
// selector such as pkg.FLAG counts as unknown.
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
		value, is_plain := plain[e.name]
		return is_plain && when_known(value, plain, depth + 1)
	case ^ast.Basic_Lit:
		// A float, rune or imaginary literal reads as false.
		return e.tok.kind == .Integer || e.tok.kind == .String
	case ^ast.Implicit_Selector_Expr:
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
		// The evaluator folds only comparisons and && or ||; arithmetic reads as false.
		#partial switch e.op.kind {
		case .Cmp_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq, .Cmp_And, .Cmp_Or:
			return when_known(e.left, plain, depth) && when_known(e.right, plain, depth)
		}
		return false
	}
	return false
}
