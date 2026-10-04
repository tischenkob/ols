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
	.Refused      = 1, // the causes are printed; nothing written, or the paths that stayed modified are named
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

// A file or directory the edit moves. Text edits address files by their old path.
Path_Rename :: struct {
	old, new: string,
}

// Every file of a workspace edit with its new text, computed in memory before anything is written.
// Renames run after every file is written, in order.
Edit_Plan :: struct {
	files:   [dynamic]File_State,
	renames: [dynamic]Path_Rename,
	edits:   int, // text edits, for the summary
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
// package and each workspace package that imports one, before and after the write, and new errors
// restore the originals. warnings do not stop the edit: text mode prints them on stderr, and JSON keeps
// them in reasons. names, the old and new name of a rename, lets an existing error that names the old
// one match its renamed form.
run_edit :: proc(
	name: string,
	edit: server.WorkspaceEdit,
	apply, check: bool,
	warnings: []string = {},
	names: [2]string = {},
) -> int {
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
	renames := plan.renames[:]
	if len(changed) == 0 && len(renames) == 0 {
		return finish(name, .Noop, edit, {}, reasons[:])
	}
	if !apply {
		if !json_output {
			b := strings.builder_make(context.temp_allocator)
			for rename in renames {
				fmt.sbprintfln(
					&b,
					"diff --git %s %s\nrename from %s\nrename to %s",
					diff_label("a", rename.old),
					diff_label("b", rename.new),
					workspace_relative(rename.old),
					workspace_relative(rename.new),
				)
			}
			for file in changed {
				old_label := "/dev/null" if !file.existed else diff_label("a", file.path)
				new_label := "/dev/null" if !file.exists else diff_label("b", renamed_path(renames, file.path))
				write_unified_diff(&b, old_label, new_label, file.original, file.text)
			}
			fmt.print(strings.to_string(b))
		}
		return finish(name, .Dry_Run, edit, changed, reasons[:], plan.edits, renames)
	}

	check := check
	// The packages are checked at their old paths before the write and at their new paths after it.
	dirs := package_dirs(changed, renames)
	targets: []string
	if check {
		// An edit can break a package that imports a touched one, directly or not, without touching it.
		importers := server.importer_dirs(dirs, &common.config)
		dirs = slice.concatenate([][]string{dirs, importers}, context.temp_allocator)
		targets = gate_targets(changed, importers, &reasons)
	}
	moved_dirs := make([]string, len(dirs), context.temp_allocator)
	for dir, i in dirs {
		moved_dirs[i] = renamed_path(renames, dir)
	}
	before: []Check_Error
	checked := 0
	if check {
		paths := checkable_paths(dirs)
		if len(paths) == 0 {
			warn(
				&reasons,
				"no touched package can be checked: each is missing or in checker_skip_packages; writing without odin check",
			)
			check = false
		} else {
			before, reason, ok = check_errors(paths, targets)
			if !ok {
				append(&reasons, reason)
				return finish(name, .Refused, edit, {}, reasons[:])
			}
			checked = len(paths)
			warn_existing_errors(&reasons, before)
		}
	}

	if verify_reason, verify_ok := verify_unchanged(changed, renames); !verify_ok {
		append(&reasons, verify_reason)
		return finish(name, .Refused, edit, {}, reasons[:])
	}
	// Files are written at their old paths, then the renames move them.
	written, write_reason, write_ok := write_files(changed)
	if !write_ok {
		append(&reasons, write_reason)
		// The file that failed may be truncated, so it is restored too.
		return roll_back(name, .Refused, edit, changed[:written + 1], {}, &reasons, plan.edits)
	}
	renamed, rename_reason, rename_ok := rename_paths(renames)
	if !rename_ok {
		append(&reasons, rename_reason)
		return roll_back(name, .Refused, edit, changed, renames[:renamed], &reasons, plan.edits)
	}

	if check {
		after, after_reason, after_ok := check_errors(checkable_paths(moved_dirs), targets)
		if !after_ok {
			append(&reasons, fmt.tprintf("%s after writing", after_reason))
			return roll_back(name, .Refused, edit, changed, renames, &reasons, plan.edits)
		}
		if fresh := new_errors(before, after, names, edited_lines(edit) if names[0] != "" else nil);
		   len(fresh) > 0 {
			for e in fresh {
				append(&reasons, fmt.tprintf("%s:%d:%d: %s", e.file, e.line, e.column, e.message))
			}
			return roll_back(name, .Check_Failed, edit, changed, renames, &reasons, plan.edits, checked)
		}
	}
	return finish(name, .Applied, edit, changed, reasons[:], plan.edits, renames, checked = checked)
}

// Warns once per directory that already has `odin check` errors: a parse error stops the check there, and
// a -max-error-count in checker_args stops the reporting, so new errors can hide behind them.
@(private = "file")
warn_existing_errors :: proc(reasons: ^[dynamic]string, errors: []Check_Error) {
	dirs := make([dynamic]string, context.temp_allocator)
	for e in errors {
		dir := path.dir(e.file, context.temp_allocator)
		if !slice.contains(dirs[:], dir) {
			append(&dirs, dir)
		}
	}
	slice.sort(dirs[:])
	for dir in dirs {
		warn(
			reasons,
			fmt.tprintf(
				"odin check already reports errors in %s; a parse error or a -max-error-count in checker_args there can hide new errors, so the gate cannot see them",
				workspace_relative(dir),
			),
		)
	}
}

// Prints warning on stderr in text mode, or keeps it in reasons for JSON.
warn :: proc(reasons: ^[dynamic]string, warning: string) {
	if json_output {
		append(reasons, warning)
	} else {
		fmt.eprintfln("warning: %s", warning)
	}
}

// Undoes renames and restores files, then finishes with status, or refuses naming what stayed modified
// when the undo fails.
@(private = "file")
roll_back :: proc(
	name: string,
	status: Edit_Status,
	edit: server.WorkspaceEdit,
	files: []File_State,
	renames: []Path_Rename,
	reasons: ^[dynamic]string,
	edits: int,
	checked := 0,
) -> int {
	failures, left_files, left_dirs := undo_edit(files, renames)
	if len(failures) > 0 {
		append(reasons, ..failures)
		return finish(name, .Refused, edit, files, reasons[:], edits, left_files = left_files, left_dirs = left_dirs)
	}
	return finish(name, status, edit, files, reasons[:], edits, checked = checked)
}

// Runs each rename in order; on failure, renamed counts the renames already done.
rename_paths :: proc(renames: []Path_Rename) -> (renamed: int, reason: string, ok: bool) {
	for rename, i in renames {
		if err := os.rename(rename.old, rename.new); err != nil {
			return i, fmt.tprintf("cannot rename %s to %s: %v", rename.old, rename.new, err), false
		}
	}
	return len(renames), "", true
}

// Undoes the renames that ran, last first, then restores files byte for byte where each one is now: a
// rename that cannot be undone leaves its files at the new path. Returns a cause per path left modified, and
// counts the files and the directories among those paths.
undo_edit :: proc(files: []File_State, renames: []Path_Rename) -> (failures: []string, left_files, left_dirs: int) {
	causes := make([dynamic]string, context.temp_allocator)
	stuck := make([dynamic]Path_Rename, context.temp_allocator)
	#reverse for rename in renames {
		if err := os.rename(rename.new, rename.old); err != nil {
			append(
				&causes,
				fmt.tprintf("%s remains renamed to %s: cannot rename it back: %v", rename.old, rename.new, err),
			)
			append(&stuck, rename)
			if os.is_directory(rename.new) {
				left_dirs += 1
			} else {
				left_files += 1
			}
		}
	}
	at := make([]File_State, len(files), context.temp_allocator)
	for file, i in files {
		at[i] = file
		at[i].path = renamed_path(stuck[:], file.path)
	}
	restore_failures := restore_files(at)
	append(&causes, ..restore_failures)
	return causes[:], left_files + len(restore_failures), left_dirs
}

// Where file_path is after renames: the new path of the last rename of it or of a directory above it.
renamed_path :: proc(renames: []Path_Rename, file_path: string) -> string {
	result := file_path
	for rename in renames {
		if server.at_or_below(result, rename.old) {
			result = strings.concatenate({rename.new, result[len(rename.old):]}, context.temp_allocator)
		}
	}
	return result
}

// Refuses the refactor command name before it has an edit; each reason is one cause.
refuse :: proc(name: string, reasons: ..string) -> int {
	return finish(name, .Refused, {}, {}, reasons)
}

// Applies every change of edit to the file texts in memory. Fails on an unreadable file, an edit to a
// missing file, an invalid or overlapping range, a rename of a missing path or onto an existing one, and
// a change after a rename to a path it moves: text edits address the old paths, so they precede renames.
plan_workspace_edit :: proc(edit: server.WorkspaceEdit) -> (plan: Edit_Plan, reason: string, ok: bool) {
	plan.files = make([dynamic]File_State, context.temp_allocator)
	plan.renames = make([dynamic]Path_Rename, context.temp_allocator)
	if changes, has := edit.documentChanges.?; has {
		for change in changes {
			switch c in change {
			case server.CreateFile:
				if order_reason, order_ok := before_renames(plan, c.uri); !order_ok {
					return {}, order_reason, false
				}
				i, file_reason, file_ok := plan_file(&plan, c.uri)
				if !file_ok {
					return {}, file_reason, false
				}
				// An existing file stays as it is, as with ignoreIfExists.
				plan.files[i].exists = true
			case server.TextDocumentEdit:
				if order_reason, order_ok := before_renames(plan, c.textDocument.uri); !order_ok {
					return {}, order_reason, false
				}
				if edit_reason, edit_ok := plan_text_edits(&plan, c.textDocument.uri, c.edits); !edit_ok {
					return {}, edit_reason, false
				}
			case server.RenameFile:
				rename := Path_Rename {
					old = common.uri_to_path(c.oldUri, context.temp_allocator),
					new = common.uri_to_path(c.newUri, context.temp_allocator),
				}
				if !os.exists(rename.old) {
					return {}, fmt.tprintf("the edit renames %s, which does not exist", rename.old), false
				}
				if os.exists(rename.new) {
					return {},
						fmt.tprintf("the edit renames %s to %s, which already exists", rename.old, rename.new),
						false
				}
				append(&plan.renames, rename)
			}
		}
	}
	uris, _ := slice.map_keys(edit.changes, context.temp_allocator)
	slice.sort(uris)
	for uri in uris {
		if order_reason, order_ok := before_renames(plan, uri); !order_ok {
			return {}, order_reason, false
		}
		if edit_reason, edit_ok := plan_text_edits(&plan, uri, edit.changes[uri]); !edit_ok {
			return {}, edit_reason, false
		}
	}
	return plan, "", true
}

// Fails when the file of uri lies at or below a path that a planned rename moves from or to.
@(private = "file")
before_renames :: proc(plan: Edit_Plan, uri: string) -> (reason: string, ok: bool) {
	file_path := common.uri_to_path(uri, context.temp_allocator)
	for rename in plan.renames {
		if server.at_or_below(file_path, rename.old) || server.at_or_below(file_path, rename.new) {
			return fmt.tprintf("the edit changes %s after a rename that moves it; edit the old path first", file_path),
				false
		}
	}
	return "", true
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

// The directories of the touched files and the renamed directories, each a package `odin check` can check.
@(private = "file")
package_dirs :: proc(files: []File_State, renames: []Path_Rename) -> []string {
	dirs := make([dynamic]string, context.temp_allocator)
	for file in files {
		dir := path.dir(file.path, context.temp_allocator)
		if !slice.contains(dirs[:], dir) {
			append(&dirs, dir)
		}
	}
	// A rename with no text edit in its directory still needs the check; rename-package always edits there.
	for rename in renames {
		if os.is_directory(rename.old) && !slice.contains(dirs[:], rename.old) {
			append(&dirs, rename.old)
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
// Also fails when a rename source is gone or its target has appeared.
@(private = "file")
verify_unchanged :: proc(files: []File_State, renames: []Path_Rename) -> (reason: string, ok: bool) {
	for rename in renames {
		if !os.exists(rename.old) {
			return fmt.tprintf("%s was removed since the edit was computed; run the command again", rename.old), false
		}
		if os.exists(rename.new) {
			return fmt.tprintf("%s was created since the edit was computed; run the command again", rename.new), false
		}
	}
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

// Puts back the original bytes of files and deletes those the edit created. A file that still holds its
// original bytes is left alone: a write that failed before changing it needs no restore. Returns a cause per
// file it could not restore.
restore_files :: proc(files: []File_State) -> []string {
	failures := make([dynamic]string, context.temp_allocator)
	for file in files {
		err: os.Error
		if file.existed {
			if data, read_err := os.read_entire_file(file.path, context.temp_allocator);
			   read_err == nil && string(data) == file.original {
				continue
			}
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

// The `odin check` errors of paths for each of targets, joined: each is a `-target:` value of odin, or empty
// for the current one. Fails when a check could not run to a parsed result, naming its target.
check_errors :: proc(paths: []string, targets: []string) -> (errors: []Check_Error, reason: string, ok: bool) {
	all := make([dynamic]Check_Error, context.temp_allocator)
	for target in targets {
		found, failure, ran := check_errors_for(paths, target)
		if !ran {
			return {}, failure if target == "" else fmt.tprintf("%s (target %s)", failure, target), false
		}
		append(&all, ..found)
	}
	return all[:], "", true
}

// The `odin check` errors of paths for target, `-target:` of odin or empty for the current one. Fails when
// a check could not run to a parsed result.
@(private = "file")
check_errors_for :: proc(paths: []string, target: string) -> (errors: []Check_Error, reason: string, ok: bool) {
	config := &common.config
	// The gate checks the touched packages, whatever the profile names, needs the diagnostics stored, and
	// leaves out the vet and style flags, whose Syntax Errors stop the check and blind the gate.
	saved := config^
	config^ = server.gate_config(saved)
	defer config^ = saved
	if target != "" {
		// A later flag wins over one in checker_args.
		config.checker_args = strings.concatenate({config.checker_args, " -target:", target}, context.temp_allocator)
	}

	server.check_run = {}
	// 20 s per batch of core-count packages, capped at GATE_TIMEOUT_CAP.
	server.check(.Saved, paths, config, server.gate_check_timeout(len(paths), os.get_processor_core_count()))
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

// The errors of after that before does not have, keyed by error_key and counting
// repeats: a second copy of an existing error is new. With names, the old and new name of a rename, a
// before error left unmatched also matches with the old name replaced as a whole word, so an existing
// error that names the renamed symbol is not new. Only a before error on a line that edited holds an
// edit of can match this way, so an error about another symbol that has the old name stays as it is. The
// unchanged key is tried first.
new_errors :: proc(before, after: []Check_Error, names: [2]string = {}, edited: Edited_Lines = nil) -> []Check_Error {
	counts := make(map[string]int, context.temp_allocator)
	for e in before {
		counts[error_key(e.message)] += 1
	}
	unmatched := take_unmatched(&counts, after)
	if names[0] == "" || len(unmatched) == 0 {
		return unmatched
	}
	eligible := make(map[string]int, context.temp_allocator)
	for e in before {
		if on_edited_line(edited, e) {
			eligible[error_key(e.message)] += 1
		}
	}
	renamed := make(map[string]int, context.temp_allocator)
	for key, count in eligible {
		// Eligible errors that the first pass already matched are not left over.
		if left := min(count, counts[key]); left > 0 {
			renamed[error_key(server.replace_word(key, names[0], names[1]))] += left
		}
	}
	return take_unmatched(&renamed, unmatched)
}

// The errors that counts has no copy of, in order. Each match uses up one count.
@(private = "file")
take_unmatched :: proc(counts: ^map[string]int, errors: []Check_Error) -> []Check_Error {
	unmatched := make([dynamic]Check_Error, context.temp_allocator)
	for e in errors {
		key := error_key(e.message)
		if counts[key] > 0 {
			counts[key] -= 1
		} else {
			append(&unmatched, e)
		}
	}
	return unmatched[:]
}

// The first line of an error message. odin names the files of a directory with two package names in the
// order it parses them, so "Different package name, expected 'a', got 'b'" swaps its names between
// runs. Its key holds the two names sorted: the swap keys the same, and a third name keys differently.
@(private = "file")
error_key :: proc(message: string) -> string {
	line := strings.truncate_to_byte(message, '\n')
	if strings.has_prefix(line, "Different package name") {
		quoted := strings.split(line, "'", context.temp_allocator)
		if len(quoted) < 4 {
			return "Different package name"
		}
		first, second := quoted[1], quoted[3]
		if second < first {
			first, second = second, first
		}
		return fmt.tprintf("Different package name '%s' '%s'", first, second)
	}
	return line
}

// prefix/PATH with PATH relative to the workspace root, or prefix followed by the absolute path outside it.
@(private = "file")
diff_label :: proc(prefix, file: string) -> string {
	rel := workspace_relative(file)
	return strings.concatenate({prefix, "" if rel == file else "/", rel}, context.temp_allocator)
}

// file relative to the workspace root, or file itself outside it. When the spellings differ, both sides
// resolve symlinks, so /var and /private/var compare equal; only the parent of file resolves, as created
// files and rename targets do not exist yet.
@(private = "file")
workspace_relative :: proc(file: string) -> string {
	if len(common.config.workspace_folders) > 0 {
		root := common.uri_to_path(common.config.workspace_folders[0].uri, context.temp_allocator)
		real := path.join(
			{server.canonical_dir(path.dir(file, context.temp_allocator)), path.base(file)},
			context.temp_allocator,
		)
		for pair in ([2][2]string{{root, file}, {server.canonical_dir(root), real}}) {
			if rel, inside := relative_inside(pair[0], pair[1]); inside {
				return rel
			}
		}
	}
	return file
}

// file relative to root, when it lies in root. The path leaves root when it is `..` or starts with `..` and a
// separator, so a file called `..x.odin` in root stays inside.
relative_inside :: proc(root, file: string) -> (string, bool) {
	rel, err := filepath.rel(root, file, context.temp_allocator)
	outside := rel == ".." || strings.has_prefix(rel, "../") || strings.has_prefix(rel, "..\\")
	return rel, err == nil && !outside
}

// Prints the result of a refactor command and returns its exit code. renames name the moved paths,
// left_files and left_dirs count the files and directories a failed rollback could not restore, and
// checked counts the packages `odin check` ran on.
@(private = "file")
finish :: proc(
	name: string,
	status: Edit_Status,
	edit: server.WorkspaceEdit,
	changed: []File_State,
	reasons: []string,
	edits := 0,
	renames: []Path_Rename = {},
	left_files := 0,
	left_dirs := 0,
	checked := 0,
) -> int {
	summary: string
	counts := fmt.tprintf(
		"%d edit%s in %d file%s",
		edits,
		"" if edits == 1 else "s",
		len(changed),
		"" if len(changed) == 1 else "s",
	)
	if len(renames) > 0 {
		counts = fmt.tprintf("%s and %d rename%s", counts, len(renames), "" if len(renames) == 1 else "s")
	}
	switch status {
	case .Dry_Run:
		summary = fmt.tprintf("%s: %s", name, counts)
	case .Applied:
		summary = fmt.tprintf("%s: %s written", name, counts)
	case .Noop:
		summary = fmt.tprintf("%s: nothing to change", name)
	case .Refused:
		left := make([dynamic]string, context.temp_allocator)
		if left_files > 0 {
			append(&left, fmt.tprintf("%d %s modified", left_files, "file remains" if left_files == 1 else "files remain"))
		}
		if left_dirs > 0 {
			append(
				&left,
				fmt.tprintf("%d %s renamed", left_dirs, "directory remains" if left_dirs == 1 else "directories remain"),
			)
		}
		summary = fmt.tprintf(
			"%s: refused, %s",
			name,
			strings.join(left[:], " and ", context.temp_allocator) if len(left) > 0 else "nothing written",
		)
	case .Check_Failed:
		summary = fmt.tprintf("%s: %s rolled back, odin check reports new errors", name, counts)
	}
	if checked > 0 && (status == .Applied || status == .Check_Failed) {
		summary = fmt.tprintf("%s, %d package%s checked", summary, checked, "" if checked == 1 else "s")
	}

	exit_codes := STATUS_EXIT
	if json_output {
		status_name := strings.to_lower(fmt.tprint(status), context.temp_allocator)
		print(Edit_Result{status_name, edit, summary, reasons if reasons != nil else []string{}})
		return exit_codes[status]
	}
	switch status {
	case .Applied:
		for rename in renames {
			fmt.printfln("%s -> %s", rename.old, rename.new)
		}
		for file in changed {
			fmt.println(renamed_path(renames, file.path))
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
