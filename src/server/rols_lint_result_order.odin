package server

import "core:odin/ast"
import "core:slice"
import "core:strings"

import "src:common"

lint_result_order :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_result_order do return
	if node in ctx.skip do return

	#partial switch n in node.derived {
	case ^ast.Foreign_Block_Decl:
		// The foreign library dictates every signature in the block.
		skip_subtree(ctx, n.body)
	case ^ast.Proc_Type:
		if n.results == nil do return
		if len(n.results.list) < 2 do return

		error: ^ast.Expr
		for field in n.results.list {
			type := field.type
			if type == nil do continue
			if is_error_like(ctx, field) {
				if error == nil do error = type
				continue
			}
			if error != nil {
				append(
					diags,
					Diagnostic {
						range = common.get_token_range(error, ctx.src),
						severity = .Warning,
						code = "error-not-last",
						message = "error results go last so 'or_return' can be used",
					},
				)
				return
			}
		}
	}
}

@(private = "file")
is_error_like :: proc(ctx: ^LintContext, field: ^ast.Field) -> bool {
	type := field.type
	if _, is_union := type.derived.(^ast.Union_Type); is_union do return true

	name := final_name(type)
	// A named `bool` result is a plain value unless it is the `ok` of an `x, ok` pair.
	if name == "bool" do return bool_is_error(field)
	if strings.has_suffix(name, "Error") || strings.has_suffix(name, "Err") do return true

	resolved, found := lint_symbols(ctx)[uintptr(type)]
	if !found || resolved.is_unresolved || resolved.symbol == nil do return false
	#partial switch v in resolved.symbol.value {
	case SymbolUnionValue:
		return true
	case SymbolEnumValue:
		return slice.contains(v.names, "None")
	}
	return false
}

// The parser gives an unnamed result the name `_`.
@(private = "file")
bool_is_error :: proc(field: ^ast.Field) -> bool {
	for n in field.names {
		ident, is_ident := n.derived.(^ast.Ident)
		if !is_ident do continue
		if ident.name == "ok" || ident.name == "_" do return true
	}
	return false
}
