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
	// A named `bool` result is a plain value unless it is the `ok` of an `x, ok` pair.
	if final_name(field.type) == "bool" do return bool_is_error(field)
	return is_error_type(ctx, field.type)
}

// A union is an error when it is `#shared_nil` or lists an error variant; `union { int, f32 }` is a value.
@(private = "file")
is_error_type :: proc(ctx: ^LintContext, type: ^ast.Expr) -> bool {
	if union_type, is_union := type.derived.(^ast.Union_Type); is_union {
		if union_type.kind == .shared_nil do return true
		for variant in union_type.variants do if is_error_type(ctx, variant) do return true
		return false
	}

	name := final_name(type)
	if strings.has_suffix(name, "Error") || strings.has_suffix(name, "Err") do return true

	resolved, found := lint_symbols(ctx)[uintptr(type)]
	if !found || resolved.is_unresolved || resolved.symbol == nil do return false
	#partial switch v in resolved.symbol.value {
	case SymbolUnionValue:
		if v.kind == .shared_nil do return true
		for variant in v.types do if is_error_type(ctx, variant) do return true
		return false
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
