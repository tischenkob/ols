package server

import "core:odin/ast"

// rols: folds the constants of `globals` into `consts` in dependency order. A mutable or fallback global, or a
// global without a value, reads as unknown.
fold_when_globals :: proc(consts: ^map[string]When_Expr, globals: map[string]GlobalExpr) {
	values := make(map[string]^ast.Expr, len(globals), context.temp_allocator)
	for name, global in globals {
		foldable := global.flags & {.Mutable, .Fallback} == {}
		values[name] = global.value_expr if foldable else nil
	}
	fold_when_values(consts, values)
}

// rols: folds the constants that `file` declares outside any `when`, foreign blocks included, into `consts` in
// dependency order, so that a constant may name one that the file declares further down. A variable reads as
// unknown.
fold_when_file_consts :: proc(consts: ^map[string]When_Expr, file: ast.File) {
	values := make(map[string]^ast.Expr, context.temp_allocator)
	add :: proc(values: ^map[string]^ast.Expr, file: ast.File, stmt: ^ast.Stmt) {
		value_decl, is_value_decl := stmt.derived.(^ast.Value_Decl)
		if !is_value_decl do return
		for name, i in value_decl.names {
			name_str := get_ast_node_string(name, file.src)
			if name_str == "" || name_str in values do continue
			values[name_str] = nil if value_decl.is_mutable || i >= len(value_decl.values) else value_decl.values[i]
		}
	}
	for decl in file.decls {
		foreign_decl, is_foreign := decl.derived.(^ast.Foreign_Block_Decl)
		if !is_foreign {
			add(&values, file, decl)
			continue
		}
		if foreign_decl.body == nil do continue
		block := foreign_decl.body.derived.(^ast.Block_Stmt) or_continue
		for stmt in block.stmts do add(&values, file, stmt)
	}
	fold_when_values(consts, values)
}

// The value of a declared name whose fold is unknown. It has no derived node, so `resolve_when_expr` reads it as
// unknown. A name holds it while it folds, so a cycle of constants reads as unknown and ends. Nothing writes to it.
@(private = "file")
when_fold_unknown: ast.Expr

// Folds every name of `values` into `consts`. A nil value marks a declared name that does not fold.
@(private = "file")
fold_when_values :: proc(consts: ^map[string]When_Expr, values: map[string]^ast.Expr) {
	for name in values do fold_when_name(consts, values, name)
}

// Folds `name` after the names its value reads. A name that `consts` holds already, such as a profile define,
// keeps its value. A name that `values` lacks stays unset and reads as false.
@(private = "file")
fold_when_name :: proc(consts: ^map[string]When_Expr, values: map[string]^ast.Expr, name: string) {
	if name in consts^ do return
	value, declared := values[name]
	if !declared do return
	consts[name] = &when_fold_unknown
	if value == nil do return
	fold_when_refs(consts, values, value)
	delete_key(consts, name)
	register_when_const(consts, name, value)
	if name not_in consts^ do consts[name] = &when_fold_unknown
}

// Folds the names that `resolve_when_expr` reads in `expr`. A selector reads another package, so it is skipped.
@(private = "file")
fold_when_refs :: proc(consts: ^map[string]When_Expr, values: map[string]^ast.Expr, expr: ^ast.Expr) {
	if expr == nil do return
	#partial switch e in expr.derived {
	case ^ast.Ident:
		fold_when_name(consts, values, e.name)
	case ^ast.Paren_Expr:
		fold_when_refs(consts, values, e.expr)
	case ^ast.Unary_Expr:
		fold_when_refs(consts, values, e.expr)
	case ^ast.Binary_Expr:
		fold_when_refs(consts, values, e.left)
		fold_when_refs(consts, values, e.right)
	case ^ast.Call_Expr:
		// `#config(NAME, default)` reads the default when NAME is not a define.
		if _, is_directive := e.expr.derived.(^ast.Basic_Directive); is_directive && len(e.args) == 2 {
			fold_when_refs(consts, values, e.args[1])
		}
	}
}
