package server

import "core:fmt"
import "core:odin/ast"
import "src:common"

// `odin test` only runs procedures marked `@(test)`, and it calls them as `proc(t: ^testing.T)`,
// so the attribute and the signature have to agree. The compiler checks the signature only under
// `odin test`, so a file that does not import core:testing may mark procs for another runner.
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
	testing_alias, imports_testing := core_testing_alias(ctx)
	takes_t := imports_testing && takes_testing_t(ctx, lit, testing_alias)
	no_results := lit.type.results == nil || len(lit.type.results.list) == 0

	if has_test {
		if !imports_testing || (takes_t && no_results) do return
		append(
			diags,
			Diagnostic {
				range = common.get_token_range(name, ctx.src),
				severity = .Warning,
				code = "test-signature",
				message = fmt.tprintf("@(test) procedures must be proc(t: ^%s.T)", testing_alias),
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
			code = "missing-test-attribute",
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

// The name this file gives core:testing.
@(private = "file")
core_testing_alias :: proc(ctx: ^LintContext) -> (string, bool) {
	for imp in ctx.document.ast.imports {
		if imp.fullpath == `"core:testing"` do return pattern_import_name(imp), true
	}
	return "", false
}

@(private = "file")
takes_testing_t :: proc(ctx: ^LintContext, lit: ^ast.Proc_Lit, testing_alias: string) -> bool {
	params := lit.type.params
	if params == nil || len(params.list) != 1 || len(params.list[0].names) != 1 || params.list[0].type == nil do return false
	return node_text(ctx.src, params.list[0].type) == fmt.tprintf("^%s.T", testing_alias)
}

@(private = "file")
is_top_level :: proc(ctx: ^LintContext, decl: ^ast.Value_Decl) -> bool {
	stmt := top_level_stmt_at(ctx.document.ast.decls[:], decl.pos.offset)
	return stmt != nil && (stmt.derived.(^ast.Value_Decl) or_else nil) == decl
}
