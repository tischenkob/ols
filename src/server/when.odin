#+feature dynamic-literals
package server

import "core:fmt"
import "core:odin/ast"
import "core:strconv"

import "src:common"

When_Expr :: union {
	int, //Integers types
	bool, //Boolean types
	string, //Enum types - those are the hardcoded options from i.e. ODIN_OS
	^ast.Expr,
}

//Because we use configuration with os names that match the files instead of the enum, i.e. my_file_windows.odin, we have to convert back and fourth.
@(private = "file")
convert_os_string: map[string]string = {
	"windows"      = "Windows",
	"darwin"       = "Darwin",
	"linux"        = "Linux",
	"freebsd"      = "FreeBSD",
	"wasi"         = "WASI",
	"js"           = "JS",
	"freestanding" = "Freestanding",
	"openbsd"      = "OpenBSD",
	"netbsd"       = "NetBSD",
	"orca"         = "Orca",
}

// rols: get_globals sets this while it collects a document's globals, so that a condition like `!pkg.FLAG` can read
// the constant from an imported package. It is nil otherwise and only valid during that call.
@(private = "file", thread_local)
when_ast_context: ^AstContext

// Profile defines seed for when-condition evaluation.
make_when_expr_map :: proc() -> map[string]When_Expr {
	when_expr_map := make(map[string]When_Expr, context.temp_allocator)

	for key, value in common.config.profile.defines {
		when_expr_map[key] = resolve_when_ident(when_expr_map, value) or_continue
	}

	return when_expr_map
}

/*
Limited static fold of a package-level constant into the when map.
Only immutable consts whose RHS resolves to bool/int/string under the
existing when evaluator are registered (defines, literals, !, &&, ||,
parens, string compares). Unknown idents still default to false bool.
Profile defines win over package names.
*/
register_when_const :: proc(when_expr_map: ^map[string]When_Expr, name: string, value: ^ast.Expr) {
	if name == "" || value == nil {
		return
	}
	if name in when_expr_map^ {
		return
	}

	resolved, ok := resolve_when_expr(when_expr_map^, value)
	if !ok {
		return
	}

	// Only scalars are useful as when-condition bindings.
	#partial switch v in resolved {
	case bool:
		when_expr_map^[name] = v
	case int:
		when_expr_map^[name] = v
	case string:
		when_expr_map^[name] = v
	}
}

// Register foldable consts from a value declaration (immutable only).
register_when_consts_from_value_decl :: proc(
	when_expr_map: ^map[string]When_Expr,
	file: ast.File,
	value_decl: ^ast.Value_Decl,
) {
	if value_decl == nil || value_decl.is_mutable {
		return
	}

	for name, i in value_decl.names {
		if len(value_decl.values) <= i {
			continue
		}
		name_str := get_ast_node_string(name, file.src)
		register_when_const(when_expr_map, name_str, value_decl.values[i])
	}
}

// rols: folds package globals in dependency order (`fold_when_globals` in rols_when_fold.odin).
register_when_consts_from_globals :: proc(
	when_expr_map: ^map[string]When_Expr,
	globals: map[string]GlobalExpr,
) {
	// rols: fold in dependency order, so a constant never reads one that is not folded yet as false.
	fold_when_globals(when_expr_map, globals)
}

resolve_when_ident :: proc(when_expr_map: map[string]When_Expr, ident: string) -> (When_Expr, bool) {
	// rols: the CLI evaluates ODIN_OS and ODIN_ARCH for the -target: of checker_args (set_when_target).
	if value, ok := when_target_ident(ident); ok do return value, true
	switch ident {
	case "ODIN_OS":
		if common.config.profile.os != "" {
			os, ok := convert_os_string[common.config.profile.os]
			if ok {
				return os, true
			} else {
				return fmt.tprint(ODIN_OS), true
			}
		} else {
			return fmt.tprint(ODIN_OS), true
		}
	case "ODIN_ARCH":
		if common.config.profile.arch != "" {
			return common.config.profile.arch, true
		} else {
			return fmt.tprint(ODIN_ARCH), true
		}
	}

	if ident in when_expr_map {
		value := when_expr_map[ident]
		// Fully resolve stored AST fragments (if any) so conditions see scalars.
		#partial switch v in value {
		case ^ast.Expr:
			return resolve_when_expr(when_expr_map, v)
		}
		return value, true
	}

	if v, ok := strconv.parse_int(ident); ok {
		return v, true
	} else if v, ok := strconv.parse_bool(ident); ok {
		return v, true
	}

	//If nothing is found we return it as false boolean
	return false, true
}

resolve_when_expr :: proc(
	when_expr_map: map[string]When_Expr,
	when_expr: When_Expr,
) -> (
	_when_expr: When_Expr,
	ok: bool,
) {

	switch expr in when_expr {
	case int:
		return expr, true
	case bool:
		return expr, true
	case string:
		return expr, true
	case ^ast.Expr:
		#partial switch odin_expr in expr.derived {
		case ^ast.Paren_Expr:
			return resolve_when_expr(when_expr_map, odin_expr.expr)
		case ^ast.Ident:
			return resolve_when_ident(when_expr_map, odin_expr.name)
		case ^ast.Basic_Lit:
			// rols: a string literal compares by its text, not by its quotes.
			if odin_expr.tok.kind == .String {
				text, _, _ := strconv.unquote_string(odin_expr.tok.text, context.temp_allocator)
				return text, true
			}
			return resolve_when_ident(when_expr_map, odin_expr.tok.text)
		case ^ast.Call_Expr:
			// rols: only `#config` calls fold.
			return resolve_config_directive(when_expr_map, odin_expr, common.config.profile.defines)
		case ^ast.Selector_Expr:
			// rols: `pkg.NAME` reads an immutable, active constant of an imported package, or a value a fold stored.
			ctx := when_ast_context
			pkg_ident, is_ident := odin_expr.expr.derived.(^ast.Ident)
			if !is_ident do return {}, false
			if ctx == nil {
				value := when_expr_map[when_selector_key(pkg_ident.name, odin_expr.field.name)] or_return
				return resolve_when_expr(when_expr_map, value)
			}
			for imp in ctx.imports {
				if imp.base != pkg_ident.name do continue
				symbol, found := lookup(odin_expr.field.name, imp.name, ctx.fullpath)
				if !found || .Mutable in symbol.flags || .Fallback in symbol.flags do return {}, false
				when_ast_context = nil
				defer when_ast_context = ctx
				return fold_package_when_const(symbol, imp.name)
			}
		case ^ast.Implicit_Selector_Expr:
			return odin_expr.field.name, true
		case ^ast.Unary_Expr:
			if odin_expr.op.kind == .Not {
				expr := resolve_when_expr(when_expr_map, odin_expr.expr) or_return
				b := expr.(bool) or_return
				return !b, true
			}
		case ^ast.Binary_Expr:
			lhs := resolve_when_expr(when_expr_map, odin_expr.left) or_return
			rhs := resolve_when_expr(when_expr_map, odin_expr.right) or_return

			lhs_bool, lhs_is_bool := lhs.(bool)
			rhs_bool, rhs_is_bool := rhs.(bool)

			lhs_int, lhs_is_int := lhs.(int)
			rhs_int, rhs_is_int := rhs.(int)

			lhs_string, lhs_is_string := lhs.(string)
			rhs_string, rhs_is_string := rhs.(string)

			if lhs_is_int && rhs_is_int {
				// rols: integer comparisons, like `when LEVEL >= 2`.
				#partial switch odin_expr.op.kind {
				case .Cmp_Eq:
					return lhs_int == rhs_int, true
				case .Not_Eq:
					return lhs_int != rhs_int, true
				case .Lt:
					return lhs_int < rhs_int, true
				case .Lt_Eq:
					return lhs_int <= rhs_int, true
				case .Gt:
					return lhs_int > rhs_int, true
				case .Gt_Eq:
					return lhs_int >= rhs_int, true
				}
			} else if lhs_is_string && rhs_is_string {
				#partial switch odin_expr.op.kind {
				case .Cmp_Eq:
					return lhs_string == rhs_string, true
				case .Not_Eq:
					return lhs_string != rhs_string, true
				}
			} else if lhs_is_bool && rhs_is_bool {
				#partial switch odin_expr.op.kind {
				case .Cmp_And:
					return lhs_bool && rhs_bool, true
				case .Cmp_Or:
					return lhs_bool || rhs_bool, true
				// rols: `when FLAG == false`.
				case .Cmp_Eq:
					return lhs_bool == rhs_bool, true
				case .Not_Eq:
					return lhs_bool != rhs_bool, true
				}
			}

			return {}, false
		}
	}


	return {}, false
}


resolve_when_condition :: proc(condition: ^ast.Expr, when_expr_map: map[string]When_Expr) -> bool {
	if condition == nil {
		return false
	}

	if when_expr, ok := resolve_when_expr(when_expr_map, condition); ok {
		b, is_bool := when_expr.(bool)
		return is_bool && b
	}

	return false
}

// rols: collects a document's globals with imported-package constants visible to `when` conditions.
collect_document_globals :: proc(ast_context: ^AstContext, file: ast.File) -> []GlobalExpr {
	saved_eval_target := use_file_when_target(ast_context)
	defer when_eval_target = saved_eval_target
	when_ast_context = ast_context
	defer when_ast_context = nil
	return collect_globals(file, open_file = true)
}

// rols: the block of a `when` statement that the target building the file takes, with imported constants visible to
// the condition.
active_when_block :: proc(
	ast_context: ^AstContext,
	stmt: ^ast.When_Stmt,
	consts: map[string]When_Expr,
) -> (
	^ast.Block_Stmt,
	bool,
) {
	saved_eval_target := use_file_when_target(ast_context)
	defer when_eval_target = saved_eval_target
	when_ast_context = ast_context
	defer when_ast_context = nil
	return get_when_block_stmt(stmt, consts)
}

// rols: `#config(NAME, default)` reads the define NAME, then the default. A `-define:` of checker_args in a CLI
// query (set_when_target) wins over `defines`.
resolve_config_directive :: proc(
	when_expr_map: map[string]When_Expr,
	call: ^ast.Call_Expr,
	defines: map[string]string,
) -> (
	When_Expr,
	bool,
) {
	directive, is_directive := call.expr.derived.(^ast.Basic_Directive)
	if !is_directive || directive.name != "config" || len(call.args) != 2 do return {}, false
	if name, is_ident := call.args[0].derived.(^ast.Ident); is_ident {
		value, defined := when_defines[name.name]
		if !defined do value, defined = defines[name.name]
		if defined {
			return resolve_when_ident(when_expr_map, value)
		}
	}
	return resolve_when_expr(when_expr_map, call.args[1])
}
