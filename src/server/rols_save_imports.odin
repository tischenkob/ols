package server

import "src:common"

// Sends the organize-imports edits for a saved document as a workspace/applyEdit request. Helix
// has neither willSaveWaitUntil nor code actions on save, so this runs from didSave and leaves
// the buffer dirty; the next save finds nothing to change.
organize_imports_on_save :: proc(document: ^Document, config: ^common.Config, writer: ^Writer) {
	ast_context := make_ast_context(
		document.ast,
		document.imports,
		document.package_name,
		document.uri.uri,
		document.fullpath,
		context.temp_allocator,
	)

	edits := organize_import_edits(document, &ast_context, config, true)

	if len(edits) == 0 {
		return
	}

	edit: WorkspaceEdit
	edit.changes = make(map[string][]TextEdit, 0, context.temp_allocator)
	edit.changes[document.uri.uri] = edits

	send_request(
		make_request_message("workspace/applyEdit", ApplyWorkspaceEditParams{label = "organize imports", edit = edit}),
		writer,
	)
}
