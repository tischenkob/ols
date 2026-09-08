package server

import "core:fmt"
import "core:odin/ast"

import "src:common"

// The `@(deprecated="...")` message is dropped by the collector, so only the name is reported.
lint_deprecated :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_deprecated do return

	field: ^ast.Ident
	#partial switch n in node.derived {
	case ^ast.Ident:
		field = n
	case ^ast.Selector_Expr:
		field = n.field
	case:
		return
	}
	if field == nil || is_declaration_name(ctx, field) do return

	resolved, found := lint_symbols(ctx)[uintptr(node)]
	if !found || resolved.is_unresolved || .Deprecated not_in resolved.symbol.flags do return

	// A selector and its own field ident both resolve to the same symbol; the selector comes first.
	range := common.get_token_range(field, ctx.src)
	for d in diags {
		if d.code == "deprecated" && d.range == range do return
	}

	append(
		diags,
		Diagnostic {
			range = range,
			severity = .Warning,
			code = "deprecated",
			tags = {.Deprecated},
			message = fmt.tprintf("'%s' is deprecated", resolved.symbol.name),
		},
	)
}

// Deprecation applies to package-level declarations, so the declaring name is a top-level one.
@(private = "file")
is_declaration_name :: proc(ctx: ^LintContext, ident: ^ast.Ident) -> bool {
	for decl in ctx.document.ast.decls {
		value_decl := decl.derived.(^ast.Value_Decl) or_else nil
		if value_decl == nil do continue
		for name in value_decl.names {
			if (name.derived.(^ast.Ident) or_else nil) == ident do return true
		}
	}
	return false
}
