package server

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"

import "src:common"

@(private = "file")
LOCKS :: []string{"mutex_lock", "rw_mutex_lock", "rw_mutex_shared_lock", "recursive_mutex_lock", "lock", "shared_lock"}

@(private = "file")
UNLOCKS :: []string {
	"mutex_unlock",
	"rw_mutex_unlock",
	"rw_mutex_shared_unlock",
	"recursive_mutex_unlock",
	"unlock",
	"shared_unlock",
}

@(private = "file")
ATOMICS :: []string{"atomic_add", "atomic_sub", "atomic_and", "atomic_or", "atomic_xor", "atomic_exchange"}

@(private = "file")
LOCK_TYPES :: []string {
	"Mutex",
	"RW_Mutex",
	"Recursive_Mutex",
	"Sema",
	"Cond",
	"Wait_Group",
	"Once",
	"Ticket_Mutex",
	"Benaphore",
	"Recursive_Benaphore",
}

lint_sync :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_sync do return

	#partial switch n in node.derived {
	case ^ast.Block_Stmt:
		check_stmts(ctx, n.stmts, diags)
	case ^ast.Case_Clause:
		check_stmts(ctx, n.body, diags)
	case ^ast.Defer_Stmt:
		defer_lock(ctx, n, diags)
	case ^ast.Assign_Stmt:
		atomic_self_assign(ctx, n, diags)
	case ^ast.Proc_Lit:
		lock_params(ctx, n, diags)
	case ^ast.Value_Decl:
		lock_copy(ctx, n, diags)
	}
}

@(private = "file")
check_stmts :: proc(ctx: ^LintContext, stmts: []^ast.Stmt, diags: ^[dynamic]Diagnostic) {
	for stmt, i in stmts {
		if i + 1 < len(stmts) do empty_critical_section(ctx, stmt, stmts[i + 1], diags)
		if i + 2 < len(stmts) do defer_before_check(ctx, stmts[i:i + 3], diags)
	}
}

// The `sync` procedure this call names, if it is one.
@(private = "file")
sync_callee :: proc(ctx: ^LintContext, call: ^ast.Call_Expr) -> (name: string, ok: bool) {
	if call == nil do return
	if _, is_selector := call.expr.derived.(^ast.Selector_Expr); !is_selector do return
	resolved := lint_symbols(ctx)[uintptr(call.expr)] or_return
	if resolved.is_unresolved || !strings.has_suffix(resolved.symbol.pkg, "/sync") do return
	return resolved.symbol.name, true
}

@(private = "file")
sync_call :: proc(ctx: ^LintContext, expr: ^ast.Expr, names: []string) -> (call: ^ast.Call_Expr, ok: bool) {
	call = expr.derived.(^ast.Call_Expr) or_else nil
	if call == nil do return nil, false
	name := sync_callee(ctx, call) or_return
	return call, slice.contains(names, name)
}

@(private = "file")
call_stmt :: proc(stmt: ^ast.Stmt) -> ^ast.Expr {
	expr_stmt := stmt.derived.(^ast.Expr_Stmt) or_else nil
	if expr_stmt == nil do return nil
	return expr_stmt.expr
}

@(private = "file")
first_arg_text :: proc(ctx: ^LintContext, call: ^ast.Call_Expr) -> (string, bool) {
	if len(call.args) == 0 do return "", false
	return strip_space(node_text(ctx.src, call.args[0])), true
}

@(private = "file")
empty_critical_section :: proc(ctx: ^LintContext, stmt, next: ^ast.Stmt, diags: ^[dynamic]Diagnostic) {
	lock_expr, unlock_expr := call_stmt(stmt), call_stmt(next)
	if lock_expr == nil || unlock_expr == nil do return

	lock, is_lock := sync_call(ctx, lock_expr, LOCKS)
	unlock, is_unlock := sync_call(ctx, unlock_expr, UNLOCKS)
	if !is_lock || !is_unlock do return

	locked, has_locked := first_arg_text(ctx, lock)
	unlocked, has_unlocked := first_arg_text(ctx, unlock)
	if !has_locked || !has_unlocked || locked != unlocked do return

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(lock, ctx.src),
			severity = .Warning,
			code = "empty-critical-section",
			message = "lock is released immediately; did you mean 'defer'?",
		},
	)
}

@(private = "file")
defer_lock :: proc(ctx: ^LintContext, deferred: ^ast.Defer_Stmt, diags: ^[dynamic]Diagnostic) {
	expr := call_stmt(deferred.stmt)
	if expr == nil do return
	call, is_lock := sync_call(ctx, expr, LOCKS)
	if !is_lock do return

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(call, ctx.src),
			severity = .Warning,
			code = "defer-lock",
			message = "deferred lock; did you mean unlock?",
		},
	)
}

@(private = "file")
atomic_self_assign :: proc(ctx: ^LintContext, assign: ^ast.Assign_Stmt, diags: ^[dynamic]Diagnostic) {
	if assign.op.kind != .Eq || len(assign.lhs) != 1 || len(assign.rhs) != 1 do return
	call, is_atomic := sync_call(ctx, assign.rhs[0], ATOMICS)
	if !is_atomic do return
	target, has_target := first_arg_text(ctx, call)
	if !has_target do return
	if strip_space(node_text(ctx.src, assign.lhs[0])) != strings.trim_prefix(target, "&") do return

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(assign, ctx.src),
			severity = .Warning,
			code = "atomic-self-assign",
			message = "atomic result assigned back to its own target is not atomic",
		},
	)
}

@(private = "file")
is_lock_type :: proc(sym: ^Symbol) -> bool {
	if sym == nil || sym.pointers != 0 || !strings.has_suffix(sym.pkg, "/sync") do return false
	return slice.contains(LOCK_TYPES, sym.name) || strings.has_prefix(sym.name, "Atomic_")
}

@(private = "file")
lock_type_of :: proc(ctx: ^LintContext, expr: ^ast.Expr) -> bool {
	if expr == nil do return false
	resolved, found := lint_symbols(ctx)[uintptr(expr)]
	if !found || resolved.is_unresolved do return false
	return is_lock_type(resolved.symbol)
}

@(private = "file")
copied_lock :: proc(ctx: ^LintContext, name: ^ast.Expr, diags: ^[dynamic]Diagnostic) {
	ident := name.derived.(^ast.Ident) or_else nil
	if ident == nil do return

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(ident, ctx.src),
			severity = .Warning,
			code = "lock-by-value",
			message = fmt.tprintf("'%s' is copied; locks must be passed by pointer", ident.name),
		},
	)
}

@(private = "file")
lock_params :: proc(ctx: ^LintContext, lit: ^ast.Proc_Lit, diags: ^[dynamic]Diagnostic) {
	if lit.type == nil || lit.type.params == nil do return
	for param in lit.type.params.list {
		if !lock_type_of(ctx, param.type) do continue
		for name in param.names {
			copied_lock(ctx, name, diags)
		}
	}
}

// `m := s.mutex` copies the lock; an indexed element resolves through the declared name because
// the symbol map holds no index nodes.
@(private = "file")
lock_copy :: proc(ctx: ^LintContext, decl: ^ast.Value_Decl, diags: ^[dynamic]Diagnostic) {
	if !decl.is_mutable || len(decl.names) != 1 || len(decl.values) != 1 || decl.type != nil do return

	#partial switch _ in decl.values[0].derived {
	case ^ast.Selector_Expr, ^ast.Index_Expr:
	case:
		return
	}
	if !lock_type_of(ctx, decl.values[0]) && !lock_type_of(ctx, decl.names[0]) do return

	copied_lock(ctx, decl.names[0], diags)
}

@(private = "file")
is_check_result :: proc(ctx: ^LintContext, name: ^ast.Expr) -> bool {
	resolved, found := lint_symbols(ctx)[uintptr(name)]
	if !found || resolved.is_unresolved do return false
	sym := resolved.symbol
	if sym.type == .Union || sym.type == .Enum do return true
	#partial switch v in sym.value {
	case SymbolBasicValue:
		return slice.contains(untyped_map[.Bool], v.ident.name)
	case SymbolUntypedValue:
		return v.type == .Bool
	}
	return false
}

@(private = "file")
mentions :: proc(root: ^ast.Node, name: string) -> bool {
	for use in collect_ident_uses(root) {
		if use.ident.name == name do return true
	}
	return false
}

// `x, err := f()` then `defer g(x)` then `if err != nil`: the cleanup runs even when the call failed.
@(private = "file")
defer_before_check :: proc(ctx: ^LintContext, stmts: []^ast.Stmt, diags: ^[dynamic]Diagnostic) {
	decl := stmts[0].derived.(^ast.Value_Decl) or_else nil
	if decl == nil || !decl.is_mutable || len(decl.names) != 2 || len(decl.values) != 1 do return
	if _, is_call := decl.values[0].derived.(^ast.Call_Expr); !is_call do return

	value := decl.names[0].derived.(^ast.Ident) or_else nil
	result := decl.names[1].derived.(^ast.Ident) or_else nil
	if value == nil || result == nil || value.name == "_" do return
	if !is_check_result(ctx, decl.names[1]) do return

	deferred := stmts[1].derived.(^ast.Defer_Stmt) or_else nil
	if deferred == nil do return
	expr := call_stmt(deferred.stmt)
	if expr == nil do return
	call := expr.derived.(^ast.Call_Expr) or_else nil
	if call == nil do return

	used := false
	for arg in call.args {
		if mentions(arg, value.name) do used = true
	}
	if !used do return

	branch := stmts[2].derived.(^ast.If_Stmt) or_else nil
	if branch == nil || branch.cond == nil || !mentions(branch.cond, result.name) do return

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(deferred, ctx.src),
			severity = .Warning,
			code = "defer-before-check",
			message = fmt.tprintf("'%s' is deferred before '%s' is checked", value.name, result.name),
		},
	)
}
