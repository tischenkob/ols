package server

import "core:path/filepath"
import "core:slice"
import "core:strings"

import "src:common"

// What the last `run_lints` of an open document decided from the other files of its package (see
// `used_as_value_elsewhere`). A change to one of those files relints the document only when it could change a verdict.
@(private = "file")
Lint_Verdicts :: struct {
	// Procedures judged not used as values elsewhere. A file whose text now names one may use it.
	unused:  [dynamic]string,
	// The files whose text named a procedure judged used as a value elsewhere. A change to one may drop that use.
	used_in: [dynamic]string,
}

// The verdicts of each open document by full path. They outlive the request, so they live in persistent memory.
@(private = "file", thread_local)
lint_verdicts: map[string]Lint_Verdicts

// The full path of the document whose `run_lints` is in progress, empty otherwise. Only `run_lints` records, so a
// code action or a test that lints a document leaves the verdicts alone.
@(private = "file", thread_local)
recording: string

// Drops the verdicts of document and records new ones until `end_lint_verdicts`.
@(private = "package")
begin_lint_verdicts :: proc(document: ^Document) {
	drop_lint_verdicts(document.fullpath)
	recording = document.fullpath
}

@(private = "package")
end_lint_verdicts :: proc() {
	recording = ""
}

// Records whether another file of the package uses name as a value, for the document whose lints are running.
@(private = "package")
record_lint_verdict :: proc(ctx: ^LintContext, name: string, used: bool) {
	if recording == "" || recording != ctx.document.fullpath do return
	verdicts := &lint_verdicts[recording]
	if verdicts == nil {
		// The key is a copy: the document frees its path on close.
		lint_verdicts[strings.clone(recording)] = {}
		verdicts = &lint_verdicts[recording]
	}
	if !used {
		append(&verdicts.unused, strings.clone(name))
		return
	}
	for file in sibling_values(ctx).files {
		if !contains_word(file.text, name) || slice.contains(verdicts.used_in[:], file.fullpath) do continue
		append(&verdicts.used_in, strings.clone(file.fullpath))
	}
}

// Relints the open documents of the package of document whose verdicts its new text could change.
@(private = "package")
relint_package_siblings :: proc(document: ^Document, config: ^common.Config) {
	if len(lint_verdicts) == 0 do return
	dir := filepath.dir(document.fullpath)
	text := string(document.text[:document.used_text])
	for _, &sibling in document_storage.documents {
		if !sibling.client_owned || sibling.fullpath == document.fullpath do continue
		if filepath.dir(sibling.fullpath) != dir do continue
		verdicts, found := lint_verdicts[sibling.fullpath]
		if found && verdict_may_change(verdicts, document.fullpath, text) do run_lints(&sibling, config)
	}
}

// Frees the verdicts of the document at fullpath, and the map once it is empty, so no allocation outlives the
// documents that own it.
@(private = "package")
drop_lint_verdicts :: proc(fullpath: string) {
	if fullpath in lint_verdicts do free_verdicts(delete_key(&lint_verdicts, fullpath))
	if len(lint_verdicts) == 0 do drop_all_lint_verdicts()
}

@(private = "package")
drop_all_lint_verdicts :: proc() {
	for key, verdicts in lint_verdicts do free_verdicts(key, verdicts)
	delete(lint_verdicts)
	lint_verdicts = nil
}

@(private = "file")
free_verdicts :: proc(key: string, verdicts: Lint_Verdicts) {
	for name in verdicts.unused do delete(name)
	for path in verdicts.used_in do delete(path)
	delete(verdicts.unused)
	delete(verdicts.used_in)
	delete(key)
}

@(private = "file")
verdict_may_change :: proc(verdicts: Lint_Verdicts, changed_path, text: string) -> bool {
	if slice.contains(verdicts.used_in[:], changed_path) do return true
	for name in verdicts.unused do if contains_word(text, name) do return true
	return false
}
