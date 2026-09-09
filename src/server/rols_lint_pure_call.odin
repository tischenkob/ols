package server

import "core:fmt"
import "core:odin/ast"
import "core:strings"

import "src:common"

// Packages whose procedures return a new value instead of mutating their arguments.
@(private = "file")
PURE_PACKAGES := []string {
	"/strings",
	"/strconv",
	"/math",
	"/unicode",
	"/unicode/utf8",
	"/path",
	"/path/filepath",
	"/slices",
	"/bytes",
}

// ponytail: name prefixes stand in for effect analysis; a per-package allow list if this misfires.
@(private = "file")
MUTATING_PREFIXES := []string {
	"builder_",
	"write_",
	"sort",
	"reverse",
	"swap",
	"fill",
	"rotate",
	"shuffle",
	"zero",
	"destroy",
	"delete",
	"free",
	"init",
	"reset",
	"pop",
	"push",
	"unordered_remove",
	"ordered_remove",
	"remove",
	"insert",
}

lint_pure_call :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_pure_call do return
	stmt, is_stmt := node.derived.(^ast.Expr_Stmt)
	if !is_stmt do return
	call, is_call := stmt.expr.derived.(^ast.Call_Expr)
	if !is_call do return
	selector, is_selector := call.expr.derived.(^ast.Selector_Expr)
	if !is_selector || selector.field == nil do return

	resolved, is_resolved := lint_symbols(ctx)[uintptr(call.expr)]
	if !is_resolved || resolved.is_unresolved || resolved.symbol == nil do return
	if resolved.symbol.type != .Function do return

	is_pure_pkg := false
	for suffix in PURE_PACKAGES {
		if strings.has_suffix(resolved.symbol.pkg, suffix) {
			is_pure_pkg = true
			break
		}
	}
	if !is_pure_pkg do return

	value, is_proc := resolved.symbol.value.(SymbolProcedureValue)
	if !is_proc || len(value.return_types) == 0 do return

	for prefix in MUTATING_PREFIXES {
		if strings.has_prefix(resolved.symbol.name, prefix) do return
	}

	// A pointer argument is the procedure's output.
	for arg in call.args {
		unary, is_unary := arg.derived.(^ast.Unary_Expr)
		if is_unary && unary.op.kind == .And do return
	}

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(call, ctx.src),
			severity = .Warning,
			code = "pure-call-unused",
			message = fmt.tprintf(
				"result of '%s.%s' is discarded",
				node_text(ctx.src, selector.expr),
				selector.field.name,
			),
		},
	)
}
