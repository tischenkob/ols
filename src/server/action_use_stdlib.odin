#+private file

package server

import "core:fmt"

@(private = "package")
add_use_stdlib_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_lint_use_stdlib {
		return
	}
	for m in stdlib_matches(ctx.document) {
		if m.start > ctx.range.start || ctx.range.end > m.end {
			continue
		}

		alias, imported := import_alias(ctx.document, m.rule.pkg)
		edits := make([dynamic]TextEdit, context.temp_allocator)
		append(&edits, TextEdit{range = range_of(ctx, m.start, m.end), newText = stdlib_rewrite(m, alias)})
		if m.rule.pkg != "" && !imported {
			append(&edits, import_edit(ctx, m.rule.pkg))
		}

		title := fmt.tprintf("Replace with %s", m.rule.target)
		append(ctx.actions, make_code_action(ctx, title, "quickfix", edits[:]))
	}
}

// `document.imports` drops packages whose collection is not configured, so read the parsed imports.
import_alias :: proc(document: ^Document, pkg: string) -> (alias: string, imported: bool) {
	fullpath := fmt.tprintf("\"core:%s\"", pkg)
	for imp in document.ast.imports {
		if imp.fullpath == fullpath {
			return imp.name.text, true
		}
	}
	return "", false
}

import_edit :: proc(ctx: ^ActionContext, pkg: string) -> TextEdit {
	if ctx.config.enable_add_import_to_bottom {
		line, is_import := find_most_bottom_line_number(ctx.ast_context)
		return {
			range = {start = {line = line, character = 0}, end = {line = line, character = 0}},
			newText = is_import ? fmt.tprintf("import \"core:%s\"\n", pkg) : fmt.tprintf("\nimport \"core:%s\"", pkg),
		}
	}

	// pkg_decl lines are 1-based, so this is the 0-based line right after the package clause.
	line := ctx.ast_context.file.pkg_decl.end.line
	return {
		range = {start = {line = line, character = 0}, end = {line = line, character = 0}},
		newText = fmt.tprintf("import \"core:%s\"\n", pkg),
	}
}
