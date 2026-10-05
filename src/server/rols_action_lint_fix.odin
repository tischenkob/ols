#+private file

package server

@(private = "package")
add_lint_fix_action :: proc(ctx: ^ActionContext) {
	for fix in lint_fixes(ctx.document, ctx.config) {
		if fix.start > ctx.range.start || ctx.range.end > fix.end {
			continue
		}
		if fix.code == "unused-parameter" && named_elsewhere(ctx, fix) {
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

// Whether renaming the parameter under fix to `_` could break a call in another file, which the lint does
// not see. A reference other than a call counts, as does any call in a referencing file that names an
// argument like the parameter. A procedure not declared at the top level is visible to this file only.
named_elsewhere :: proc(ctx: ^ActionContext, fix: Lint_Fix) -> bool {
	function := ctx.position_context.function
	if function == nil {
		return true
	}
	decl, is_top := proc_decl_of(ctx.document, function)
	if !is_top {
		return false
	}
	name := ctx.document.ast.src[fix.start:fix.end]
	h := Call_Hierarchy{ctx.files, make(map[string]^Document, context.temp_allocator)}
	h.documents[ctx.document.uri.uri] = ctx.document
	checked := make(map[^Document]struct{}, context.temp_allocator)
	checked[ctx.document] = {}
	for location in proc_references(ctx.document, decl, ctx.files) {
		caller := hierarchy_document(&h, location.uri)
		if caller == nil {
			return true
		}
		if call, ok := call_at_reference(caller, location); !ok || call == nil {
			return true
		}
		if caller in checked {
			continue
		}
		checked[caller] = {}
		if name in named_arguments(&caller.ast) {
			return true
		}
	}
	return false
}
