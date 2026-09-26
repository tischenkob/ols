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

		import_path := fmt.tprintf("core:%s", m.rule.pkg)
		alias, imported := import_alias(ctx.document, import_path)
		edits := make([dynamic]TextEdit, context.temp_allocator)
		append(&edits, TextEdit{range = range_of(ctx, m.start, m.end), newText = stdlib_rewrite(m, alias)})
		if m.rule.pkg != "" && !imported {
			append(&edits, import_edit(ctx, import_path))
		}

		title := fmt.tprintf("Replace with %s", m.rule.target)
		append(ctx.actions, make_code_action(ctx, title, "quickfix", edits[:]))
	}
}
