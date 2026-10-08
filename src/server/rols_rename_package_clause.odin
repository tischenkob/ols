package server

import "core:path/filepath"
import "core:strings"

import "src:common"

// The range of the name in the `package` clause of document when position is on that name. The range
// leaves out a `_test` suffix, which the package rename keeps.
package_clause_at :: proc(document: ^Document, position: common.Position) -> (range: common.Range, ok: bool) {
	clause := document.ast.pkg_decl
	if clause == nil || clause.name == "" {
		return
	}
	offset := common.get_absolute_position(position, document.text[:document.used_text]) or_return
	if offset < clause.pos.offset || offset > clause.pos.offset + len(clause.name) {
		return
	}
	return text_range(clause.pos, strings.trim_suffix(clause.name, "_test"), document.ast.src), true
}

// Renames the package of document, as rename_package does, when position is on the name of its
// `package` clause. found is false when position is elsewhere. reasons holds one cause per refusal, and
// warnings holds the changes the rename left out, as rename_package reports them.
// The rename is refused when the client cannot rename the package directory or sent no workspace folders.
rename_package_clause :: proc(
	document: ^Document,
	position: common.Position,
	new_name: string,
	config: ^common.Config,
	files: []Package_File = {},
) -> (
	edit: WorkspaceEdit,
	reasons: []string,
	warnings: []string,
	found: bool,
) {
	context.allocator = context.temp_allocator
	_ = package_clause_at(document, position) or_return
	if !config.client_rename_file_support {
		out := make([]string, 1)
		out[0] = "the client cannot rename directories, so it cannot rename a package: run `ols query rename-package DIR NEW` instead"
		return {}, out, {}, true
	}
	if len(files) == 0 && len(config.workspace_folders) == 0 {
		// The walk for importers covers the workspace folders only, so it would find none.
		out := make([]string, 1)
		out[0] = "the client sent no workspace folders, so the rename cannot find the importers of the package"
		return {}, out, {}, true
	}
	dir := filepath.dir(document.fullpath)
	edit, warnings, reasons, _ = rename_package(dir, new_name, config, files)
	return edit, reasons, warnings, true
}

// Shows the warnings of an editor package rename in a window/showMessage, since the rename response
// carries only the edit.
show_rename_warnings :: proc(warnings: []string, writer: ^Writer) {
	if len(warnings) == 0 {
		return
	}
	message := strings.join(warnings, "\n", context.temp_allocator)
	notification := Notification {
		jsonrpc = "2.0",
		method = "window/showMessage",
		params = NotificationLoggingParams{type = .Warning, message = message},
	}
	send_notification(notification, writer)
}
