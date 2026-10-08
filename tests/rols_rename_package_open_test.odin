package tests

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "src:common"
import "src:server"

// The editor rename passes no file list, so the package files come from the directory. An open file with
// unsaved edits must give its buffer text: here the buffer moved the package clause down one line.
@(test)
rename_package_reads_open_document_text :: proc(t: ^testing.T) {
	lock_global_diagnostics()
	defer unlock_global_diagnostics()

	root, err := os.make_directory_temp("", "ols-rename-open-*", context.temp_allocator)
	if !testing.expectf(t, err == nil, "failed to create temporary directory: %v", err) do return
	defer os.remove_all(root)
	root, err = os.get_absolute_path(root, context.temp_allocator)
	if !testing.expectf(t, err == nil, "failed to resolve temporary directory: %v", err) do return
	dir, _ := filepath.join({root, "old"}, context.temp_allocator)
	file, _ := filepath.join({dir, "a.odin"}, context.temp_allocator)
	if !testing.expect(t, os.make_directory(dir) == nil) do return
	if !testing.expect(t, os.write_entire_file(file, "package old\n\nX :: 1\n") == nil) do return

	config := common.Config {
		collections = make(map[string]string),
	}
	defer delete(config.collections)
	append(&config.workspace_folders, common.WorkspaceFolder{uri = common.create_uri(root, context.temp_allocator).uri})
	defer delete(config.workspace_folders)

	server.document_storage.documents = make(map[string]server.Document)
	defer {
		server.document_storage_shutdown()
		server.document_storage = {}
	}
	builtin_path := server.get_builtin_path()
	defer delete(builtin_path)
	server.setup_index(builtin_path)
	defer server.free_index()

	uri := common.create_uri(file, context.temp_allocator).uri
	open_err := server.document_open(uri, strings.clone("// moved\npackage old\n\nX :: 1\n"), &config, nil)
	if !testing.expectf(t, open_err == .None, "failed to open a.odin: %v", open_err) do return
	defer server.document_close(uri)

	edit, _, reasons, ok := server.rename_package(dir, "fresh", &config)
	if !testing.expectf(t, ok, "Expected the package rename to pass its check, but received %v", reasons) do return

	clause_line := -1
	for change in edit.documentChanges.? or_else {} {
		if text_edit, is_edit := change.(server.TextDocumentEdit); is_edit {
			for e in text_edit.edits {
				if e.newText == "fresh" do clause_line = e.range.start.line
			}
		}
	}
	testing.expectf(t, clause_line == 1, "Expected the clause edit on buffer line 1, got %v", clause_line)
}
