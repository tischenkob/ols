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
// `package` clause. found is false when position is elsewhere. reasons holds one cause per refusal.
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
	found: bool,
) {
	context.allocator = context.temp_allocator
	_ = package_clause_at(document, position) or_return
	if !config.client_rename_file_support {
		out := make([]string, 1, context.temp_allocator)
		out[0] = "the client cannot rename directories, so it cannot rename a package: run `ols query rename-package DIR NEW` instead"
		return {}, out, true
	}
	if len(files) == 0 && len(config.workspace_folders) == 0 {
		// The walk for importers covers the workspace folders only, so it would find none.
		out := make([]string, 1, context.temp_allocator)
		out[0] = "the client sent no workspace folders, so the rename cannot find the importers of the package"
		return {}, out, true
	}
	dir := filepath.dir(document.fullpath)
	edit, _, reasons, _ = rename_package(dir, new_name, config, files)
	return edit, reasons, true
}
