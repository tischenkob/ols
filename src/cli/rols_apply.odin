package cli

import "core:fmt"
import "core:os"
import "core:path/filepath"
import path "core:path/slashpath"
import "core:slice"
import "core:strings"

import "src:common"
import "src:server"

Edit_Status :: enum {
	Applied,
	Dry_Run,
	Refused,
	Noop,
	Check_Failed,
}

// Exit codes of the refactor commands; a usage error exits 2. Read-only queries keep their own codes.
STATUS_EXIT :: [Edit_Status]int {
	.Applied      = 0, // applied
	.Dry_Run      = 0, // a dry run with edits
	.Refused      = 1, // the causes are printed; nothing written, or the files that stayed modified are named
	.Noop         = 3, // nothing to change
	.Check_Failed = 4, // `odin check` reported new errors, so every file was restored
}

// One file an edit touches, before and after. A file the edit creates has existed false; a file it
// deletes has exists false.
File_State :: struct {
	path:     string,
	existed:  bool,
	original: string,
	exists:   bool,
	text:     string,
}

// Every file of a workspace edit with its new text, computed in memory before anything is written.
Edit_Plan :: struct {
	files: [dynamic]File_State,
	edits: int, // text edits, for the summary
}

// The `--json` result of a refactor command.
Edit_Result :: struct {
	status:  string,
	edit:    server.WorkspaceEdit,
	summary: string,
	reasons: []string,
}

// One `odin check` error. Two errors are the same when the first lines of their messages match: later
// lines and the position move with the code, and a move can carry an error to another file.
Check_Error :: struct {
	file:         string,
	line, column: int,
	message:      string,
}

// Previews or applies edit for the refactor command name and returns the exit code. A dry run prints a
// unified diff. An apply writes every file or none: with check set, `odin check` runs on each touched
// package before and after the write, and new errors restore the originals. warnings do not stop the
// edit: text mode prints them on stderr, and JSON keeps them in reasons.
run_edit :: proc(name: string, edit: server.WorkspaceEdit, apply, check: bool, warnings: []string = {}) -> int {
	// Every outcome keeps the warnings.
	reasons := make([dynamic]string, context.temp_allocator)
	for warning in warnings {
		warn(&reasons, warning)
	}

	plan, reason, ok := plan_workspace_edit(edit)
	if !ok {
		append(&reasons, reason)
		return finish(name, .Refused, edit, {}, reasons[:])
	}
	changed := changed_files(plan)
	if len(changed) == 0 {
		return finish(name, .Noop, edit, {}, reasons[:])
	}
	if !apply {
		if !json_output {
			b := strings.builder_make(context.temp_allocator)
			for file in changed {
				old_label := "/dev/null" if !file.existed else diff_label("a", file.path)
				new_label := "/dev/null" if !file.exists else diff_label("b", file.path)
				write_unified_diff(&b, old_label, new_label, file.original, file.text)
			}
			fmt.print(strings.to_string(b))
		}
		return finish(name, .Dry_Run, edit, changed, reasons[:], plan.edits)
	}

	check := check
	dirs := package_dirs(changed)
	before: []Check_Error
	if check {
		paths := checkable_paths(dirs)
		if len(paths) == 0 {
			warn(
				&reasons,
				"no touched package can be checked: each is missing or in checker_skip_packages; writing without odin check",
			)
			check = false
		} else {
			before, reason, ok = check_errors(paths)
			if !ok {
				append(&reasons, reason)
				return finish(name, .Refused, edit, {}, reasons[:])
			}
		}
	}

	if verify_reason, verify_ok := verify_unchanged(changed); !verify_ok {
		append(&reasons, verify_reason)
		return finish(name, .Refused, edit, {}, reasons[:])
	}
	written, write_reason, write_ok := write_files(changed)
	if !write_ok {
		append(&reasons, write_reason)
		// The file that failed may be truncated, so it is restored too.
		return roll_back(name, .Refused, edit, changed[:written + 1], &reasons, plan.edits)
	}

	if check {
		after, after_reason, after_ok := check_errors(checkable_paths(dirs))
		if !after_ok {
			append(&reasons, fmt.tprintf("%s after writing", after_reason))
			return roll_back(name, .Refused, edit, changed, &reasons, plan.edits)
		}
		if fresh := new_errors(before, after); len(fresh) > 0 {
			for e in fresh {
				append(&reasons, fmt.tprintf("%s:%d:%d: %s", e.file, e.line, e.column, e.message))
			}
			return roll_back(name, .Check_Failed, edit, changed, &reasons, plan.edits)
		}
	}
	return finish(name, .Applied, edit, changed, reasons[:], plan.edits)
}

// Prints warning on stderr in text mode, or keeps it in reasons for JSON.
@(private = "file")
warn :: proc(reasons: ^[dynamic]string, warning: string) {
	if json_output {
		append(reasons, warning)
	} else {
		fmt.eprintfln("warning: %s", warning)
	}
}

// Restores files and finishes with status, or refuses naming the files that stayed modified when a
// restore fails.
@(private = "file")
roll_back :: proc(
	name: string,
	status: Edit_Status,
	edit: server.WorkspaceEdit,
	files: []File_State,
	reasons: ^[dynamic]string,
	edits: int,
) -> int {
	failures := restore_files(files)
	if len(failures) > 0 {
		append(reasons, ..failures)
		return finish(name, .Refused, edit, files, reasons[:], edits, left_modified = len(failures))
	}
	return finish(name, status, edit, files, reasons[:], edits)
}

// Refuses the refactor command name before it has an edit; each reason is one cause.
refuse :: proc(name: string, reasons: ..string) -> int {
	return finish(name, .Refused, {}, {}, reasons)
}

// Applies every change of edit to the file texts in memory. Fails on an unreadable file, an edit to a
// missing file, or an invalid or overlapping range.
plan_workspace_edit :: proc(edit: server.WorkspaceEdit) -> (plan: Edit_Plan, reason: string, ok: bool) {
	plan.files = make([dynamic]File_State, context.temp_allocator)
	if changes, has := edit.documentChanges.?; has {
		for change in changes {
			switch c in change {
			case server.CreateFile:
				i, file_reason, file_ok := plan_file(&plan, c.uri)
				if !file_ok {
					return {}, file_reason, false
				}
				// An existing file stays as it is, as with ignoreIfExists.
				plan.files[i].exists = true
			case server.TextDocumentEdit:
				if edit_reason, edit_ok := plan_text_edits(&plan, c.textDocument.uri, c.edits); !edit_ok {
					return {}, edit_reason, false
				}
			}
		}
	}
	uris, _ := slice.map_keys(edit.changes, context.temp_allocator)
	slice.sort(uris)
	for uri in uris {
		if edit_reason, edit_ok := plan_text_edits(&plan, uri, edit.changes[uri]); !edit_ok {
			return {}, edit_reason, false
		}
	}
	return plan, "", true
}

@(private = "file")
plan_text_edits :: proc(plan: ^Edit_Plan, uri: string, edits: []server.TextEdit) -> (reason: string, ok: bool) {
	i, file_reason, file_ok := plan_file(plan, uri)
	if !file_ok {
		return file_reason, false
	}
	file := &plan.files[i]
	if !file.exists {
		return fmt.tprintf("the edit changes %s, which does not exist", file.path), false
	}
	text, applied := common.apply_text_edits(edits, file.text)
	if !applied {
		return fmt.tprintf("the edit has an invalid or overlapping range in %s", file.path), false
	}
	file.text = text
	plan.edits += len(edits)
	return "", true
}

// The index of the file of uri in plan, read from disk on first use.
@(private = "file")
plan_file :: proc(plan: ^Edit_Plan, uri: string) -> (index: int, reason: string, ok: bool) {
	file_path := common.uri_to_path(uri, context.temp_allocator)
	for file, i in plan.files {
		if file.path == file_path {
			return i, "", true
		}
	}
	state := File_State {
		path = file_path,
	}
	if os.exists(file_path) {
		data, err := os.read_entire_file(file_path, context.temp_allocator)
		if err != nil {
			return 0, fmt.tprintf("cannot read %s: %v", file_path, err), false
		}
		state.existed, state.exists = true, true
		state.original, state.text = string(data), string(data)
	}
	append(&plan.files, state)
	return len(plan.files) - 1, "", true
}

@(private = "file")
changed_files :: proc(plan: Edit_Plan) -> []File_State {
	changed := make([dynamic]File_State, context.temp_allocator)
	for file in plan.files {
		if file.existed != file.exists || file.original != file.text {
			append(&changed, file)
		}
	}
	return changed[:]
}

// The directories of the touched files, each a package `odin check` can check.
@(private = "file")
package_dirs :: proc(files: []File_State) -> []string {
	dirs := make([dynamic]string, context.temp_allocator)
	for file in files {
		dir := path.dir(file.path, context.temp_allocator)
		if !slice.contains(dirs[:], dir) {
			append(&dirs, dir)
		}
	}
	return dirs[:]
}

// Writes each file in order; on failure, written counts the files already written.
@(private = "file")
write_files :: proc(files: []File_State) -> (written: int, reason: string, ok: bool) {
	for file, i in files {
		err: os.Error
		if file.exists {
			err = os.write_entire_file(file.path, file.text)
		} else if file.existed {
			err = os.remove(file.path)
		}
		if err != nil {
			return i, fmt.tprintf("cannot write %s: %v", file.path, err), false
		}
	}
	return len(files), "", true
}

// Fails when a file changed on disk, or appeared, since the plan read it: writing would lose that change.
@(private = "file")
verify_unchanged :: proc(files: []File_State) -> (reason: string, ok: bool) {
	for file in files {
		if !file.existed {
			if os.exists(file.path) {
				return fmt.tprintf("%s was created since the edit was computed; run the command again", file.path),
					false
			}
			continue
		}
		data, err := os.read_entire_file(file.path, context.temp_allocator)
		if err != nil {
			return fmt.tprintf("cannot read %s: %v", file.path, err), false
		}
		if string(data) != file.original {
			return fmt.tprintf("%s changed on disk since the edit was computed; run the command again", file.path),
				false
		}
	}
	return "", true
}

// Puts back the original bytes of files and deletes those the edit created. Returns a cause per file
// it could not restore.
restore_files :: proc(files: []File_State) -> []string {
	failures := make([dynamic]string, context.temp_allocator)
	for file in files {
		err: os.Error
		if file.existed {
			err = os.write_entire_file(file.path, file.original)
		} else if os.exists(file.path) {
			err = os.remove(file.path)
		}
		if err != nil {
			append(&failures, fmt.tprintf("%s remains modified: cannot restore it: %v", file.path, err))
		}
	}
	return failures[:]
}

// The check paths of the package directories that exist and are not in checker_skip_packages.
@(private = "file")
checkable_paths :: proc(dirs: []string) -> []string {
	paths := make([dynamic]string, context.temp_allocator)
	for dir in dirs {
		if os.is_directory(dir) && dir not_in common.config.checker_skip_packages {
			// resolve_check_paths checks the directory of each path; the slash keeps dir itself.
			append(&paths, strings.concatenate({dir, "/"}, context.temp_allocator))
		}
	}
	return paths[:]
}

// The `odin check` errors of paths. Fails when a check could not run to a parsed result.
@(private = "file")
check_errors :: proc(paths: []string) -> (errors: []Check_Error, reason: string, ok: bool) {
	config := &common.config
	// The gate checks the touched packages, whatever the profile names, and needs the diagnostics stored.
	checker_path, enable_diagnostics := config.profile.checker_path, config.enable_diagnostics
	config.profile.checker_path, config.enable_diagnostics = nil, true
	defer config.profile.checker_path, config.enable_diagnostics = checker_path, enable_diagnostics

	server.check_run = {}
	server.check(.Saved, paths, config)
	if !server.check_run.ran {
		return {}, "`odin check` did not run", false
	}
	if server.check_run.failure != "" {
		return {}, server.check_run.failure, false
	}

	found := make([dynamic]Check_Error, context.temp_allocator)
	for uri in server.get_merged_diagnostics() {
		file := common.uri_to_path(uri, context.temp_allocator)
		for diagnostic in server.diagnostics_of(.Check, uri, context.temp_allocator) {
			if diagnostic.severity != .Error {
				continue
			}
			// check stores odin's byte column, so no conversion from UTF-16 applies.
			start := diagnostic.range.start
			append(&found, Check_Error{file, start.line + 1, start.character + 1, diagnostic.message})
		}
	}
	return found[:], "", true
}

// The errors of after that before does not have, keyed by the first line of the message and counting
// repeats: a second copy of an existing error is new.
@(private = "file")
new_errors :: proc(before, after: []Check_Error) -> []Check_Error {
	counts := make(map[string]int, context.temp_allocator)
	for e in before {
		counts[strings.truncate_to_byte(e.message, '\n')] += 1
	}
	fresh := make([dynamic]Check_Error, context.temp_allocator)
	for e in after {
		key := strings.truncate_to_byte(e.message, '\n')
		if counts[key] > 0 {
			counts[key] -= 1
		} else {
			append(&fresh, e)
		}
	}
	return fresh[:]
}

// prefix/PATH with PATH relative to the workspace root, or prefix followed by the absolute path outside it.
@(private = "file")
diff_label :: proc(prefix, file: string) -> string {
	if len(common.config.workspace_folders) > 0 {
		root := common.uri_to_path(common.config.workspace_folders[0].uri, context.temp_allocator)
		if rel, err := filepath.rel(root, file, context.temp_allocator); err == nil && !strings.has_prefix(rel, "..") {
			return strings.concatenate({prefix, "/", rel}, context.temp_allocator)
		}
	}
	return strings.concatenate({prefix, file}, context.temp_allocator)
}

// Prints the result of a refactor command and returns its exit code. left_modified counts the files a
// failed rollback could not restore.
@(private = "file")
finish :: proc(
	name: string,
	status: Edit_Status,
	edit: server.WorkspaceEdit,
	changed: []File_State,
	reasons: []string,
	edits := 0,
	left_modified := 0,
) -> int {
	summary: string
	counts := fmt.tprintf(
		"%d edit%s in %d file%s",
		edits,
		"" if edits == 1 else "s",
		len(changed),
		"" if len(changed) == 1 else "s",
	)
	switch status {
	case .Dry_Run:
		summary = fmt.tprintf("%s: %s", name, counts)
	case .Applied:
		summary = fmt.tprintf("%s: %s written", name, counts)
	case .Noop:
		summary = fmt.tprintf("%s: nothing to change", name)
	case .Refused:
		if left_modified > 0 {
			summary = fmt.tprintf(
				"%s: refused, %d %s modified",
				name,
				left_modified,
				"file remains" if left_modified == 1 else "files remain",
			)
		} else {
			summary = fmt.tprintf("%s: refused, nothing written", name)
		}
	case .Check_Failed:
		summary = fmt.tprintf("%s: %s rolled back, odin check reports new errors", name, counts)
	}

	exit_codes := STATUS_EXIT
	if json_output {
		status_name := strings.to_lower(fmt.tprint(status), context.temp_allocator)
		print(Edit_Result{status_name, edit, summary, reasons if reasons != nil else []string{}})
		return exit_codes[status]
	}
	switch status {
	case .Applied:
		for file in changed {
			fmt.println(file.path)
		}
		fmt.println(summary)
	case .Dry_Run, .Noop:
		fmt.println(summary)
	case .Refused, .Check_Failed:
		fmt.eprintln(summary)
		for reason in reasons {
			fmt.eprintfln("error: %s", reason)
		}
	}
	return exit_codes[status]
}
