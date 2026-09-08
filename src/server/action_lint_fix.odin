#+private file

package server

@(private = "package")
add_lint_fix_action :: proc(ctx: ^ActionContext) {
	for fix in lint_fixes(ctx.document, ctx.config) {
		if fix.start > ctx.range.start || ctx.range.end > fix.end {
			continue
		}
		edits := make([]TextEdit, 1, context.temp_allocator)
		edits[0] = TextEdit {
			range   = range_of(ctx, fix.start, fix.end),
			newText = fix.text,
		}
		append(ctx.actions, make_code_action(ctx, fix.title, "quickfix", edits))
	}
}
