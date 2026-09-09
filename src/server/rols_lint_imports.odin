package server

import "core:fmt"
import "core:odin/ast"
import "core:os"
import "core:strings"

import "src:common"

lint_imports :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_imports do return

	imp, is_import := node.derived.(^ast.Import_Decl)
	if !is_import do return

	path := strings.trim(imp.fullpath, `"`)

	for decl in ctx.document.ast.decls {
		earlier := decl.derived.(^ast.Import_Decl) or_continue
		if earlier == imp do break
		if earlier.fullpath != imp.fullpath do continue
		append(
			diags,
			Diagnostic {
				range = common.get_token_range(imp, ctx.src),
				severity = .Hint,
				code = "duplicate-import",
				message = fmt.tprintf("'%s' is already imported", path),
				tags = {.Unnecessary},
			},
		)
		start, end := whole_lines(ctx.src, imp.pos.offset, imp.end.offset)
		append(&ctx.fixes, Lint_Fix{start, end, "Remove duplicate import", ""})
		return
	}

	// Imports with a collection the config does not know are absent from document.imports.
	for pkg in ctx.document.imports {
		if pkg.import_decl != imp do continue
		if !os.exists(pkg.name) {
			append(
				diags,
				Diagnostic {
					range = common.get_token_range(imp, ctx.src),
					severity = .Error,
					code = "missing-import",
					message = fmt.tprintf("package '%s' not found", path),
				},
			)
		}
		return
	}
}
