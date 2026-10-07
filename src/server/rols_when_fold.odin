package server

import "core:odin/ast"

// rols: folds the constants of `globals` into `consts` in dependency order. A mutable or fallback global, or a
// global without a value, reads as unknown. A procedure or a type stays out and reads as false.
fold_when_globals :: proc(consts: ^map[string]When_Expr, globals: map[string]GlobalExpr) {
	values := make(map[string]^ast.Expr, context.temp_allocator)
	for name, global in globals {
		if global.flags & {.Mutable, .Fallback} != {} || global.value_expr == nil {
			values[name] = nil
		} else if when_fold_form(global.value_expr) {
			values[name] = global.value_expr
		}
	}
	fold_when_consts(consts, values)
}

// rols: folds `values`, the declared constants by name, into `consts` in dependency order. A nil value marks a
// declared name that does not fold, and a name that `values` lacks reads as false.
fold_when_consts :: proc(consts: ^map[string]When_Expr, values: map[string]^ast.Expr) {
	fold := When_Fold {
		consts   = consts,
		values   = values,
		deferred = make(map[string]struct{}, context.temp_allocator),
	}
	fold_when_values(&fold)
}

// rols: folds the constants that `file` declares outside any `when` into `consts` in dependency order, so that a
// constant may name one that the file declares further down. A variable reads as unknown. A constant that reads a
// name declared in a `when` branch stays out, so that the declaration-order walk of `collect_globals` folds it
// after that branch.
fold_when_file_consts :: proc(consts: ^map[string]When_Expr, file: ast.File) {
	fold := When_Fold {
		consts   = consts,
		values   = make(map[string]^ast.Expr, context.temp_allocator),
		deferred = make(map[string]struct{}, context.temp_allocator),
	}
	for decl in file.decls {
		#partial switch d in decl.derived {
		case ^ast.Value_Decl:
			for name, i in d.names {
				name_str := get_ast_node_string(name, file.src)
				if name_str == "" || name_str in fold.values do continue
				value := nil if d.is_mutable || i >= len(d.values) else d.values[i]
				if value == nil || when_fold_form(value) do fold.values[name_str] = value
			}
		case ^ast.When_Stmt:
			defer_when_names(&fold.deferred, file, d)
		}
	}
	fold_when_values(&fold)
}

@(private = "file")
When_Fold :: struct {
	consts:   ^map[string]When_Expr,
	// The declared names by value. A nil value marks a declared name that does not fold.
	values:   map[string]^ast.Expr,
	// The names whose value the walk of `collect_globals` settles: those declared in a `when` branch, and the
	// constants that read one of them.
	deferred: map[string]struct{},
}

// The value of a declared name whose fold is unknown. It has no derived node, so `resolve_when_expr` reads it as
// unknown. A name holds it while it folds, so a cycle of constants reads as unknown and ends. Nothing writes to it.
@(private = "file")
when_fold_unknown: ast.Expr

// Whether `expr` has a form that `resolve_when_expr` can fold, so that a procedure or a type stays out.
@(private = "file")
when_fold_form :: proc(expr: ^ast.Expr) -> bool {
	#partial switch e in expr.derived {
	case ^ast.Ident,
	     ^ast.Paren_Expr,
	     ^ast.Unary_Expr,
	     ^ast.Binary_Expr,
	     ^ast.Basic_Lit,
	     ^ast.Selector_Expr,
	     ^ast.Implicit_Selector_Expr:
		return true
	case ^ast.Call_Expr:
		_, is_directive := e.expr.derived.(^ast.Basic_Directive)
		return is_directive
	}
	return false
}

// Adds the names that the value declarations under `stmt`, a `when` statement or one of its blocks, declare.
@(private = "file")
defer_when_names :: proc(deferred: ^map[string]struct{}, file: ast.File, stmt: ^ast.Stmt) {
	if stmt == nil do return
	#partial switch s in stmt.derived {
	case ^ast.When_Stmt:
		defer_when_names(deferred, file, s.body)
		defer_when_names(deferred, file, s.else_stmt)
	case ^ast.Block_Stmt:
		for inner in s.stmts do defer_when_names(deferred, file, inner)
	case ^ast.Value_Decl:
		for name in s.names do deferred[get_ast_node_string(name, file.src)] = {}
	}
}

@(private = "file")
fold_when_values :: proc(fold: ^When_Fold) {
	for name in fold.values do fold_when_name(fold, name)
}

// Folds `name` after the names its value reads, and reports whether its reading is settled. A name that `consts`
// holds already, such as a profile define, keeps its value. A name that `values` lacks stays unset and reads as
// false. A constant that reads a deferred name stays unset and becomes deferred too.
@(private = "file")
fold_when_name :: proc(fold: ^When_Fold, name: string) -> bool {
	if name in fold.consts^ do return true
	if name in fold.deferred do return false
	value, declared := fold.values[name]
	if !declared do return true
	fold.consts[name] = &when_fold_unknown
	if value == nil do return true
	settled := fold_when_refs(fold, value)
	delete_key(fold.consts, name)
	if !settled {
		fold.deferred[name] = {}
		return false
	}
	register_when_const(fold.consts, name, value)
	if name not_in fold.consts^ do fold.consts[name] = &when_fold_unknown
	return true
}

// Folds the names that `resolve_when_expr` reads in `expr`, and reports whether all of them are settled. A selector
// reads another package, so it is skipped.
@(private = "file")
fold_when_refs :: proc(fold: ^When_Fold, expr: ^ast.Expr) -> bool {
	if expr == nil do return true
	#partial switch e in expr.derived {
	case ^ast.Ident:
		return fold_when_name(fold, e.name)
	case ^ast.Paren_Expr:
		return fold_when_refs(fold, e.expr)
	case ^ast.Unary_Expr:
		return fold_when_refs(fold, e.expr)
	case ^ast.Binary_Expr:
		left := fold_when_refs(fold, e.left)
		return fold_when_refs(fold, e.right) && left
	case ^ast.Call_Expr:
		// `#config(NAME, default)` reads the default when NAME is not a define.
		if _, is_directive := e.expr.derived.(^ast.Basic_Directive); is_directive && len(e.args) == 2 {
			return fold_when_refs(fold, e.args[1])
		}
	}
	return true
}
