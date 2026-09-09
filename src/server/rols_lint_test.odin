package server

import "core:fmt"
import "core:odin/ast"
import "src:common"

// `odin test` only runs procedures marked `@(test)`, and it calls them as `proc(t: ^testing.T)`,
// so the attribute and the signature have to agree.
lint_test_attribute :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_test_attribute do return
	decl, is_decl := node.derived.(^ast.Value_Decl)
	if !is_decl || !is_top_level(ctx, decl) do return
	if len(decl.names) != 1 || len(decl.values) != 1 do return
	name := decl.names[0].derived.(^ast.Ident) or_else nil
	lit := decl.values[0].derived.(^ast.Proc_Lit) or_else nil
	if name == nil || lit == nil || lit.type == nil do return

	has_test := false
	for attribute in attribute_names(decl.attributes[:]) {
		if attribute == "test" do has_test = true
	}
	takes_t := takes_testing_t(ctx, lit)
	no_results := lit.type.results == nil || len(lit.type.results.list) == 0

	if has_test {
		if takes_t && no_results do return
		append(
			diags,
			Diagnostic {
				range = common.get_token_range(name, ctx.src),
				severity = .Warning,
				code = "test-signature",
				message = "@(test) procedures must be proc(t: ^testing.T)",
			},
		)
		return
	}
	if !takes_t do return
	// A proc called from elsewhere in the file is a helper.
	if is_used_elsewhere(ctx, name) do return

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(name, ctx.src),
			severity = .Warning,
			code = "missing-test-attribute",
			message = fmt.tprintf("'%s' takes ^testing.T but has no @(test)", name.name),
		},
	)

	line_start := decl.pos.offset
	for line_start > 0 && ctx.src[line_start - 1] != '\n' do line_start -= 1
	append(
		&ctx.fixes,
		Lint_Fix {
			start = line_start,
			end = name.end.offset,
			title = "Add @(test)",
			text = fmt.tprintf("@(test)\n%s", ctx.src[line_start:name.end.offset]),
		},
	)
}

@(private = "file")
is_used_elsewhere :: proc(ctx: ^LintContext, name: ^ast.Ident) -> bool {
	for decl in ctx.document.ast.decls {
		for use in collect_ident_uses(decl) {
			if use.ident.name == name.name && use.ident != name do return true
		}
	}
	return false
}

@(private = "file")
takes_testing_t :: proc(ctx: ^LintContext, lit: ^ast.Proc_Lit) -> bool {
	params := lit.type.params
	if params == nil || len(params.list) != 1 || len(params.list[0].names) != 1 || params.list[0].type == nil do return false
	return node_text(ctx.src, params.list[0].type) == fmt.tprintf("^%s.T", testing_package_name(ctx))
}

@(private = "file")
testing_package_name :: proc(ctx: ^LintContext) -> string {
	for imp in ctx.document.ast.imports {
		if imp.fullpath == `"core:testing"` && imp.name.text != "" do return imp.name.text
	}
	return "testing"
}

@(private = "file")
is_top_level :: proc(ctx: ^LintContext, decl: ^ast.Value_Decl) -> bool {
	for stmt in ctx.document.ast.decls {
		if (stmt.derived.(^ast.Value_Decl) or_else nil) == decl do return true
	}
	return false
}
