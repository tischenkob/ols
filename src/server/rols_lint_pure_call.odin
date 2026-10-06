package server

import "core:fmt"
import "core:odin/ast"
import "core:slice"
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
	"/slice",
	"/bytes",
}

// ponytail: name prefixes stand in for effect analysis; a per-package allow list if this misfires.
@(private = "file")
MUTATING_PREFIXES := []string {
	"builder_",
	"buffer_", // bytes.Buffer: buffer_write*, buffer_read*, buffer_truncate, buffer_grow, ...
	"reader_", // bytes.Reader, strings.Reader: reader_read*, reader_seek, ...
	"write_",
	"advance_", // slice.advance_slices: advances the inner slices in place
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

// Procedures under a mutating prefix, or with a pointer parameter, that only inspect their argument.
@(private = "file")
ACCESSOR_NAMES := []string {
	"buffer_to_bytes",
	"buffer_to_string",
	"buffer_is_empty",
	"buffer_length",
	"buffer_capacity",
	"reader_length",
	"reader_size",
	"buffer_to_stream",
	"reader_to_stream",
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

	name := resolved.symbol.name
	if !slice.contains(ACCESSOR_NAMES, name) {
		for prefix in MUTATING_PREFIXES {
			if strings.has_prefix(name, prefix) do return
		}
		// A procedure may write through a pointer parameter, such as `to_reader` or `split_iterator`.
		if has_pointer_param(value.arg_types) || has_pointer_param(value.orig_arg_types) do return
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

// `^T` or `[^]T`, written out or as the specialization of a polymorphic parameter.
@(private = "file")
has_pointer_param :: proc(params: []^ast.Field) -> bool {
	for param in params {
		type := param.type
		if type == nil do continue
		if poly, is_poly := type.derived.(^ast.Poly_Type); is_poly do type = poly.specialization
		if type == nil do continue
		#partial switch _ in unparen(type).derived {
		case ^ast.Pointer_Type, ^ast.Multi_Pointer_Type:
			return true
		}
	}
	return false
}
