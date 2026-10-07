package server

import "core:fmt"
import "core:odin/ast"

import "src:common"

lint_calls :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_call_arity do return
	call, is_call := node.derived.(^ast.Call_Expr)
	if !is_call do return

	callee := ast.unparen_expr(call.expr)
	extra := 0
	written: string
	#partial switch e in callee.derived {
	case ^ast.Ident:
		written = e.name
	case ^ast.Selector_Expr:
		// x->f(a) passes x as the first argument.
		if e.op.kind == .Arrow_Right do extra = 1
		if e.field != nil do written = e.field.name
	case:
		return
	}

	resolved, found := lint_symbols(ctx)[uintptr(callee)]
	if !found || resolved.is_unresolved || resolved.symbol == nil do return
	symbol := resolved.symbol
	if symbol.type != .Function || .PolyType in symbol.flags do return
	value, is_proc := symbol.value.(SymbolProcedureValue)
	if !is_proc || value.generic do return

	// ponytail: a spread or a named argument bails the whole call; match names to parameters if it matters.
	if call.ellipsis.kind == .Ellipsis do return
	for arg in call.args {
		if _, is_named := arg.derived.(^ast.Field_Value); is_named do return
	}

	required, total := 0, 0
	for field in value.arg_types {
		if field == nil do return
		if field.flags & {.Ellipsis, .Using, .C_Vararg} != {} do return
		if field.type != nil {
			#partial switch _ in field.type.derived {
			case ^ast.Ellipsis, ^ast.Poly_Type, ^ast.Typeid_Type:
				return
			}
		}
		count := max(len(field.names), 1)
		total += count
		if field.default_value == nil do required += count
	}

	given, exact := expanded_arg_count(ctx, call.args)
	if !exact do return
	given += extra
	if given >= required && given <= total do return
	// The whole-file resolve drops a group member that needs more arguments than the call passes, unless an
	// argument passes a count it does not know (`call_arg_counts_known`). Then a group call can resolve to such a
	// member, which has another name than the call.
	if given < required && written != symbol.name && !arg_counts_known_to_resolver(call.args) do return

	message: string
	if required == total {
		plural := required == 1 ? "" : "s"
		message = fmt.tprintf("'%s' takes %d argument%s, got %d", symbol.name, required, plural, given)
	} else {
		message = fmt.tprintf("'%s' takes %d to %d arguments, got %d", symbol.name, required, total, given)
	}

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(call, ctx.src),
			severity = .Error,
			code = "argument-count",
			message = message,
		},
	)
}

// Whether the resolver knows the value count of every argument, as `call_arg_counts_known` judges it.
@(private = "file")
arg_counts_known_to_resolver :: proc(args: []^ast.Expr) -> bool {
	for arg in args {
		#partial switch _ in arg.derived {
		case ^ast.Selector_Call_Expr, ^ast.Bad_Expr:
			return false
		}
	}
	return true
}
