#+private file

package server

@(private = "package")
add_simplify_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_lint_simplify {
		return
	}
	for s in simplifications(ctx.document) {
		if s.start > ctx.range.start || ctx.range.end > s.end {
			continue
		}
		edits := make([]TextEdit, 1, context.temp_allocator)
		edits[0] = TextEdit {
			range   = range_of(ctx, s.start, s.end),
			newText = s.text,
		}
		append(ctx.actions, make_code_action(ctx, s.title, "quickfix", edits))
	}
}
