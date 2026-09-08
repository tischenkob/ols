package server

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:text/regex"

import "src:common"

@(private = "file")
ROUNDING :: []string{"ceil", "floor", "round", "trunc"}

lint_core_misuse :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_core_misuse do return
	call, is_call := node.derived.(^ast.Call_Expr)
	if !is_call do return
	pkg, name, ok := core_callee(ctx, call)
	if !ok do return

	switch {
	case strings.has_suffix(pkg, "/time") && name == "sleep":
		sleep_literal(ctx, call, diags)
	case strings.has_suffix(pkg, "/strings") && name == "replace":
		replace_count(ctx, call, diags)
	case strings.has_suffix(pkg, "/math") && slice.contains(ROUNDING, name):
		ceil_integer(ctx, call, diags)
	case strings.has_suffix(pkg, "/text/regex") && (name == "create" || name == "create_by_user"):
		regex_syntax(ctx, call, diags)
	}
}

@(private = "file")
core_callee :: proc(ctx: ^LintContext, call: ^ast.Call_Expr) -> (pkg, name: string, ok: bool) {
	if _, is_selector := call.expr.derived.(^ast.Selector_Expr); !is_selector do return
	resolved := lint_symbols(ctx)[uintptr(call.expr)] or_return
	if resolved.is_unresolved do return
	return resolved.symbol.pkg, resolved.symbol.name, true
}

// The value of an integer literal, optionally negated.
@(private = "file")
int_literal :: proc(expr: ^ast.Expr) -> (value: int, ok: bool) {
	expr, negative := expr, false
	if unary, is_unary := expr.derived.(^ast.Unary_Expr); is_unary {
		if unary.op.kind != .Sub do return
		expr, negative = unary.expr, true
	}
	lit := expr.derived.(^ast.Basic_Lit) or_return
	if lit.tok.kind != .Integer do return
	value = strconv.parse_int(lit.tok.text) or_return
	return negative ? -value : value, true
}

@(private = "file")
sleep_literal :: proc(ctx: ^LintContext, call: ^ast.Call_Expr, diags: ^[dynamic]Diagnostic) {
	if len(call.args) != 1 do return
	if _, is_literal := int_literal(call.args[0]); !is_literal do return

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(call, ctx.src),
			severity = .Warning,
			code = "sleep-literal",
			message = "time.sleep takes nanoseconds; multiply by a unit such as time.Millisecond",
		},
	)
}

@(private = "file")
replace_count :: proc(ctx: ^LintContext, call: ^ast.Call_Expr, diags: ^[dynamic]Diagnostic) {
	if len(call.args) < 4 do return
	n, is_literal := int_literal(call.args[3])
	if !is_literal do return

	switch n {
	case 0:
		append(
			diags,
			Diagnostic {
				range = common.get_token_range(call, ctx.src),
				severity = .Warning,
				code = "replace-count",
				message = "strings.replace with n = 0 does nothing",
			},
		)
	case -1:
		append(
			diags,
			Diagnostic {
				range = common.get_token_range(call, ctx.src),
				severity = .Hint,
				code = "replace-count",
				message = "use strings.replace_all",
				tags = {.Unnecessary},
			},
		)
		selector := call.expr.derived.(^ast.Selector_Expr)
		if selector.field == nil do return
		// The arguments after the fourth are left where they are.
		kept := ctx.src[call.args[0].pos.offset:call.args[2].end.offset]
		append(
			&ctx.fixes,
			Lint_Fix {
				selector.field.pos.offset,
				call.args[3].end.offset,
				"Use strings.replace_all",
				fmt.tprintf("replace_all(%s", kept),
			},
		)
	}
}

@(private = "file")
FLOATS :: []string{"f16", "f32", "f64"}

// The operand of a float conversion, written as a call or a `cast`.
@(private = "file")
float_conversion :: proc(expr: ^ast.Expr) -> (inner: ^ast.Expr, ok: bool) {
	is_float_type :: proc(type: ^ast.Expr) -> bool {
		ident, is_ident := type.derived.(^ast.Ident)
		return is_ident && slice.contains(FLOATS, ident.name)
	}

	#partial switch e in expr.derived {
	case ^ast.Call_Expr:
		if len(e.args) != 1 || !is_float_type(e.expr) do return
		return e.args[0], true
	case ^ast.Type_Cast:
		if e.tok.kind != .Cast || !is_float_type(e.type) do return
		return e.expr, true
	}
	return
}

@(private = "file")
is_integer_operand :: proc(ctx: ^LintContext, expr: ^ast.Expr) -> bool {
	#partial switch e in expr.derived {
	case ^ast.Basic_Lit:
		return e.tok.kind == .Integer
	case ^ast.Ident, ^ast.Selector_Expr:
		resolved := lint_symbols(ctx)[uintptr(expr)] or_return
		if resolved.is_unresolved do return false
		#partial switch v in resolved.symbol.value {
		case SymbolBasicValue:
			return slice.contains(untyped_map[.Integer], v.ident.name)
		case SymbolUntypedValue:
			return v.type == .Integer
		}
	}
	return false
}

@(private = "file")
ceil_integer :: proc(ctx: ^LintContext, call: ^ast.Call_Expr, diags: ^[dynamic]Diagnostic) {
	if len(call.args) != 1 do return
	inner, is_conversion := float_conversion(call.args[0])
	if !is_conversion || !is_integer_operand(ctx, inner) do return

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(call, ctx.src),
			severity = .Warning,
			code = "ceil-integer",
			message = fmt.tprintf("%s on a converted integer has no effect", node_text(ctx.src, call.expr)),
		},
	)
}

// The pattern is compiled here so the diagnostic carries the compiler's own error.
@(private = "file")
regex_syntax :: proc(ctx: ^LintContext, call: ^ast.Call_Expr, diags: ^[dynamic]Diagnostic) {
	if len(call.args) == 0 do return
	lit, is_literal := call.args[0].derived.(^ast.Basic_Lit)
	if !is_literal || lit.tok.kind != .String do return
	pattern, _, unquoted := strconv.unquote_string(lit.tok.text, context.temp_allocator)
	if !unquoted do return

	expression, err := regex.create(pattern, {}, context.temp_allocator, context.temp_allocator)
	if err == nil {
		regex.destroy(expression, context.temp_allocator)
		return
	}

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(lit, ctx.src),
			severity = .Warning,
			code = "regex-syntax",
			message = fmt.tprintf("invalid regular expression: %v", err),
		},
	)
}
