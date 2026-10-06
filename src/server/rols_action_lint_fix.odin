#+private file

package server

import "core:odin/ast"

@(private = "package")
add_lint_fix_action :: proc(ctx: ^ActionContext) {
	for fix in lint_fixes(ctx.document, ctx.config) {
		if fix.start > ctx.range.start || ctx.range.end > fix.end {
			continue
		}
		// Renaming the parameter to `_` could break a call in another file, which the lint does not see.
		if fix.code == "unused-parameter" {
			function := ctx.position_context.function
			name := ctx.document.ast.src[fix.start:fix.end]
			if function == nil || param_named_elsewhere(ctx.document, function, name, ctx.files) {
				continue
			}
		}
		edits := make([]TextEdit, 1, context.temp_allocator)
		edits[0] = TextEdit {
			range   = range_of(ctx, fix.start, fix.end),
			newText = fix.text,
		}
		append(ctx.actions, make_code_action(ctx, fix.title, "quickfix", edits))
	}
}

// Whether renaming the parameter name of lit, a procedure of document, to `_` could break a call in another
// file (files stands in for the workspace). A reference other than a call counts, as does any call in a
// referencing file that names an argument like the parameter. A call of a platform variant counts too. A
// procedure not declared at the top level is visible to this file only.
@(private = "package")
param_named_elsewhere :: proc(document: ^Document, lit: ^ast.Proc_Lit, name: string, files: []Package_File) -> bool {
	decl, is_top := proc_decl_of(document, lit)
	if !is_top {
		return false
	}
	h := Call_Hierarchy{files, make(map[string]^Document, context.temp_allocator)}
	checked := make(map[^Document]struct{}, context.temp_allocator)
	checked[document] = {}
	variants := variant_symbols(top_level_variants(&h, document, decl))
	for location in proc_references(document, decl, files, variants) {
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
