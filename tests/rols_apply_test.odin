package tests

import "base:runtime"
import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "src:cli"
import "src:common"
import "src:server"

@(private = "file")
text_edit :: proc(start, end: [2]int, text: string) -> server.TextEdit {
	return {range = {{start.x, start.y}, {end.x, end.y}}, newText = text}
}

@(test)
apply_text_edits_refuses_overlap_and_bad_range :: proc(t: ^testing.T) {
	text := "abc\ndef\n"

	result, ok := common.apply_text_edits(
		[]server.TextEdit{text_edit({0, 0}, {0, 2}, "X"), text_edit({0, 1}, {0, 3}, "Y")},
		text,
	)
	testing.expect(t, !ok, "overlapping replacements must fail")
	testing.expect_value(t, result, text)

	_, ok = common.apply_text_edits([]server.TextEdit{text_edit({7, 0}, {7, 1}, "Z")}, text)
	testing.expect(t, !ok, "a range past the end must fail")

	_, ok = common.apply_text_edits([]server.TextEdit{text_edit({1, 2}, {0, 1}, "Z")}, text)
	testing.expect(t, !ok, "a range ending before it starts must fail")

	result, ok = common.apply_text_edits(
		[]server.TextEdit {
			text_edit({1, 0}, {1, 0}, "1"),
			text_edit({1, 0}, {1, 0}, "2"),
			text_edit({0, 0}, {0, 3}, "x"),
		},
		text,
	)
	testing.expect(t, ok, "inserts at one position are ordered by the array")
	testing.expect_value(t, result, "x\n12def\n")

	result, ok = common.apply_text_edits(
		[]server.TextEdit{text_edit({0, 0}, {0, 0}, ">"), text_edit({0, 0}, {0, 3}, "x")},
		text,
	)
	testing.expect(t, ok, "an insert may precede a replace that starts at the same position")
	testing.expect_value(t, result, ">x\ndef\n")

	_, ok = common.apply_text_edits(
		[]server.TextEdit{text_edit({0, 0}, {0, 3}, "x"), text_edit({0, 1}, {0, 1}, ">")},
		text,
	)
	testing.expect(t, !ok, "an insert inside a replaced range must fail")
}

@(test)
apply_plan_refuses_overlapping_edit_and_reads_files :: proc(t: ^testing.T) {
	dir, dir_err := os.make_directory_temp("", "rols_apply_*", context.temp_allocator)
	if !testing.expect_value(t, dir_err, nil) do return
	defer os.remove_all(dir)

	file, _ := filepath.join({dir, "a.odin"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(file, "package a\nx :: 1\n"), nil)
	uri := common.create_uri(file, context.temp_allocator).uri

	edit: server.WorkspaceEdit
	edit.changes = make(map[string][]server.TextEdit, context.temp_allocator)
	edit.changes[uri] = []server.TextEdit{text_edit({1, 0}, {1, 1}, "y"), text_edit({1, 0}, {1, 6}, "z :: 2")}
	_, reason, ok := cli.plan_workspace_edit(edit)
	testing.expect(t, !ok)
	testing.expectf(t, strings.contains(reason, "overlapping"), "reason: %q", reason)

	created, _ := filepath.join({dir, "b.odin"}, context.temp_allocator)
	created_uri := common.create_uri(created, context.temp_allocator).uri
	changes := []server.DocumentChange {
		server.CreateFile{kind = "create", uri = created_uri},
		server.TextDocumentEdit {
			textDocument = {uri = created_uri},
			edits = {text_edit({0, 0}, {0, 0}, "package a\n")},
		},
		server.TextDocumentEdit{textDocument = {uri = uri}, edits = {text_edit({1, 0}, {1, 1}, "y")}},
	}
	plan: cli.Edit_Plan
	plan, reason, ok = cli.plan_workspace_edit({documentChanges = changes})
	if !testing.expectf(t, ok, "refused: %s", reason) do return
	testing.expect_value(t, len(plan.files), 2)
	testing.expect_value(t, plan.edits, 2)
	testing.expect(t, !plan.files[0].existed && plan.files[0].exists)
	testing.expect_value(t, plan.files[0].text, "package a\n")
	testing.expect(t, plan.files[1].existed)
	testing.expect_value(t, plan.files[1].text, "package a\ny :: 1\n")

	missing := []server.DocumentChange{server.TextDocumentEdit{textDocument = {uri = created_uri}, edits = {}}}
	_, reason, ok = cli.plan_workspace_edit({documentChanges = missing})
	testing.expect(t, !ok)
	testing.expectf(t, strings.contains(reason, "does not exist"), "reason: %q", reason)
}

@(test)
apply_unified_diff :: proc(t: ^testing.T) {
	b := strings.builder_make(context.temp_allocator)
	old := "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\nlast"
	new := "1\n2\nthree\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\nlast\n"
	cli.write_unified_diff(&b, "a/f.odin", "b/f.odin", old, new)
	testing.expect_value(
		t,
		strings.to_string(b),
		"--- a/f.odin\n+++ b/f.odin\n@@ -1,6 +1,6 @@\n 1\n 2\n-3\n+three\n 4\n 5\n 6\n@@ -13,4 +13,4 @@\n 13\n 14\n 15\n-last\n\\ No newline at end of file\n+last\n",
	)

	strings.builder_reset(&b)
	cli.write_unified_diff(&b, "/dev/null", "b/new.odin", "", "package a\n")
	testing.expect_value(t, strings.to_string(b), "--- /dev/null\n+++ b/new.odin\n@@ -0,0 +1 @@\n+package a\n")

	strings.builder_reset(&b)
	cli.write_unified_diff(&b, "a/f.odin", "b/f.odin", "a\nb\nc\n", "a\nc\n")
	testing.expect_value(t, strings.to_string(b), "--- a/f.odin\n+++ b/f.odin\n@@ -1,3 +1,2 @@\n a\n-b\n c\n")
}

@(test)
apply_restore_files :: proc(t: ^testing.T) {
	dir, dir_err := os.make_directory_temp("", "rols_restore_*", context.temp_allocator)
	if !testing.expect_value(t, dir_err, nil) do return
	defer os.remove_all(dir)

	edited, _ := filepath.join({dir, "a.odin"}, context.temp_allocator)
	created, _ := filepath.join({dir, "b.odin"}, context.temp_allocator)
	unwritable, _ := filepath.join({dir, "missing", "c.odin"}, context.temp_allocator)
	// A write that failed before changing the file, as on permission denied, leaves nothing to restore.
	untouched, _ := filepath.join({dir, "d.odin"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(edited, "changed\n"), nil)
	testing.expect_value(t, os.write_entire_file(created, "new\n"), nil)
	testing.expect_value(t, os.write_entire_file(untouched, "package d\n"), nil)
	testing.expect_value(t, os.change_mode(untouched, {.Read_User}), nil)

	failures := cli.restore_files(
		{
			{path = edited, existed = true, original = "package a\n", exists = true, text = "changed\n"},
			{path = created, exists = true, text = "new\n"},
			{path = unwritable, existed = true, original = "package c\n", exists = true},
			{path = untouched, existed = true, original = "package d\n", exists = true, text = "changed\n"},
		},
	)

	data, _ := os.read_entire_file(edited, context.temp_allocator)
	testing.expect_value(t, string(data), "package a\n")
	testing.expect(t, !os.exists(created), "a created file is deleted")
	if testing.expect_value(t, len(failures), 1) {
		testing.expectf(t, strings.contains(failures[0], "c.odin remains modified"), "failure: %q", failures[0])
	}
}

@(test)
apply_plan_directory_rename :: proc(t: ^testing.T) {
	dir, dir_err := os.make_directory_temp("", "rols_rename_dir_*", context.temp_allocator)
	if !testing.expect_value(t, dir_err, nil) do return
	defer os.remove_all(dir)

	old_dir, _ := filepath.join({dir, "old"}, context.temp_allocator)
	new_dir, _ := filepath.join({dir, "fresh"}, context.temp_allocator)
	file, _ := filepath.join({old_dir, "a.odin"}, context.temp_allocator)
	testing.expect_value(t, os.make_directory(old_dir), nil)
	testing.expect_value(t, os.write_entire_file(file, "package old\n"), nil)
	uri := common.create_uri(file, context.temp_allocator).uri
	rename := server.RenameFile {
		kind   = "rename",
		oldUri = common.create_uri(old_dir, context.temp_allocator).uri,
		newUri = common.create_uri(new_dir, context.temp_allocator).uri,
	}

	edit := []server.DocumentChange {
		server.TextDocumentEdit{textDocument = {uri = uri}, edits = {text_edit({0, 8}, {0, 11}, "fresh")}},
		rename,
	}
	plan, reason, ok := cli.plan_workspace_edit({documentChanges = edit})
	if !testing.expectf(t, ok, "refused: %s", reason) do return
	testing.expect_value(t, len(plan.files), 1)
	testing.expect_value(t, plan.files[0].text, "package fresh\n")
	if testing.expect_value(t, len(plan.renames), 1) {
		testing.expect_value(t, plan.renames[0].old, old_dir)
		testing.expect_value(t, plan.renames[0].new, new_dir)
		new_file, _ := filepath.join({new_dir, "a.odin"}, context.temp_allocator)
		testing.expect_value(t, cli.renamed_path(plan.renames[:], file), new_file)
	}

	after := []server.DocumentChange {
		rename,
		server.TextDocumentEdit{textDocument = {uri = uri}, edits = {text_edit({0, 8}, {0, 11}, "fresh")}},
	}
	_, reason, ok = cli.plan_workspace_edit({documentChanges = after})
	testing.expect(t, !ok, "an edit after the rename of its file must fail")
	testing.expectf(t, strings.contains(reason, "after a rename"), "reason: %q", reason)

	testing.expect_value(t, os.make_directory(new_dir), nil)
	_, reason, ok = cli.plan_workspace_edit({documentChanges = edit})
	testing.expect(t, !ok, "a rename onto an existing directory must fail")
	testing.expectf(t, strings.contains(reason, "already exists"), "reason: %q", reason)
}

@(test)
apply_roll_back_directory_rename :: proc(t: ^testing.T) {
	dir, dir_err := os.make_directory_temp("", "rols_undo_dir_*", context.temp_allocator)
	if !testing.expect_value(t, dir_err, nil) do return
	defer os.remove_all(dir)

	old_dir, _ := filepath.join({dir, "old"}, context.temp_allocator)
	new_dir, _ := filepath.join({dir, "fresh"}, context.temp_allocator)
	file, _ := filepath.join({old_dir, "a.odin"}, context.temp_allocator)
	testing.expect_value(t, os.make_directory(old_dir), nil)
	testing.expect_value(t, os.write_entire_file(file, "package old\r\n"), nil)

	// The apply order: write at the old path, then rename.
	files := []cli.File_State {
		{path = file, existed = true, original = "package old\r\n", exists = true, text = "package fresh\n"},
	}
	renames := []cli.Path_Rename{{old_dir, new_dir}}
	testing.expect_value(t, os.write_entire_file(file, files[0].text), nil)
	renamed, reason, ok := cli.rename_paths(renames)
	if !testing.expectf(t, ok && renamed == 1, "rename failed: %s", reason) do return
	testing.expect(t, !os.exists(old_dir) && os.exists(new_dir))

	failures, left_files, left_dirs := cli.undo_edit(files, renames)
	testing.expectf(t, len(failures) == 0, "failures: %v", failures)
	testing.expect_value(t, left_files, 0)
	testing.expect_value(t, left_dirs, 0)
	testing.expect(t, os.is_directory(old_dir) && !os.exists(new_dir), "the directory is renamed back")
	data, _ := os.read_entire_file(file, context.temp_allocator)
	testing.expect_value(t, string(data), "package old\r\n")

	// A rename that fails leaves the directory where it was and reports why.
	unreachable, _ := filepath.join({dir, "missing", "fresh"}, context.temp_allocator)
	renamed, reason, ok = cli.rename_paths({{old_dir, unreachable}})
	testing.expect(t, !ok && renamed == 0, "a rename into a missing parent must fail")
	testing.expectf(t, strings.contains(reason, "cannot rename"), "reason: %q", reason)
	testing.expect(t, os.is_directory(old_dir))

	// When the rename cannot be undone, the files are restored where they are and the cause is named.
	testing.expect_value(t, os.rename(old_dir, new_dir), nil)
	moved, _ := filepath.join({new_dir, "a.odin"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(moved, "package fresh\n"), nil)
	testing.expect_value(t, os.make_directory(old_dir), nil)
	blocker, _ := filepath.join({old_dir, "keep.txt"}, context.temp_allocator)
	testing.expect_value(t, os.write_entire_file(blocker, "x"), nil)
	failures, left_files, left_dirs = cli.undo_edit(files, renames)
	// The directory stays renamed while its file is restored, so only the directory is counted.
	testing.expect_value(t, left_files, 0)
	testing.expect_value(t, left_dirs, 1)
	if testing.expect_value(t, len(failures), 1) {
		testing.expectf(t, strings.contains(failures[0], "remains renamed"), "failure: %q", failures[0])
	}
	data, _ = os.read_entire_file(moved, context.temp_allocator)
	testing.expect_value(t, string(data), "package old\r\n")
}

@(test)
apply_replace_word_in_check_message :: proc(t: ^testing.T) {
	testing.expect_value(
		t,
		server.replace_word("Cannot assign 'count()' to 's', count is int", "count", "tally"),
		"Cannot assign 'tally()' to 's', tally is int",
	)
	testing.expect_value(t, server.replace_word("'rp.P' of rp", "rp", "rq"), "'rq.P' of rq")
	testing.expect_value(t, server.replace_word("count", "count", "tally"), "tally")
	testing.expect_value(
		t,
		server.replace_word("count_all and recount and count2", "count", "tally"),
		"count_all and recount and count2",
	)
	testing.expect_value(t, server.replace_word("unchanged", "", "x"), "unchanged")
}

@(test)
apply_new_errors_ignores_which_subset_odin_reports :: proc(t: ^testing.T) {
	before := []cli.Check_Error {
		{"a.odin", 3, 1, "Undeclared name: one"},
		{"a.odin", 4, 1, "Undeclared name: two"},
	}
	after := []cli.Check_Error {
		{"a.odin", 4, 1, "Undeclared name: two"},
		{"a.odin", 9, 1, "Undeclared name: one"},
	}
	testing.expect_value(t, len(cli.new_errors(before, after)), 0)
	// A second copy of an error is new, and so is an error that was not there.
	repeated := []cli.Check_Error{after[0], after[0]}
	testing.expect_value(t, len(cli.new_errors(before, repeated)), 1)
	fresh := cli.new_errors(before, {{"a.odin", 5, 1, "Cannot assign value 'x' of type 'int' to 'string'"}})
	testing.expect_value(t, len(fresh), 1)
}

@(test)
apply_new_errors_matches_swapped_package_names :: proc(t: ^testing.T) {
	before := []cli.Check_Error{{"d/b.odin", 1, 9, "Different package name, expected 'a', got 'b'\n"}}
	after := []cli.Check_Error{{"d/a.odin", 1, 9, "Different package name, expected 'b', got 'a'"}}
	testing.expect_value(t, len(cli.new_errors(before, after)), 0)
	// A second mismatch is a new error.
	two := []cli.Check_Error{after[0], after[0]}
	testing.expect_value(t, len(cli.new_errors(before, two)), 1)
}

@(test)
apply_new_errors_keys_package_mismatch_on_both_names :: proc(t: ^testing.T) {
	before := []cli.Check_Error{{"d/b.odin", 1, 9, "Different package name, expected 'a', got 'b'"}}
	swapped := []cli.Check_Error{{"d/a.odin", 1, 9, "Different package name, expected 'b', got 'a'"}}
	testing.expect_value(t, len(cli.new_errors(before, swapped)), 0)
	// A move into a third package name is a new mismatch, not the one that was there.
	third := []cli.Check_Error{{"d/c.odin", 1, 9, "Different package name, expected 'a', got 'c'"}}
	testing.expect_value(t, len(cli.new_errors(before, third)), 1)
}

@(test)
apply_new_errors_rename_matches_only_edited_lines :: proc(t: ^testing.T) {
	// The rename of count to tally edits line 8. An old error on line 8 names count and matches the same
	// error on tally. The same text on line 3, which the rename does not touch, is another symbol's error.
	names := [2]string{"count", "tally"}
	edited := make(cli.Edited_Lines, context.temp_allocator)
	edited["a.odin"] = []cli.Line_Span{{8, 8}}
	on_edited := []cli.Check_Error{{"a.odin", 8, 1, "Cannot assign 'count()' to 's'"}}
	renamed := []cli.Check_Error{{"a.odin", 8, 1, "Cannot assign 'tally()' to 's'"}}
	testing.expect_value(t, len(cli.new_errors(on_edited, renamed, names, edited)), 0)

	// An error in a file the rename does not edit has no edit lines at all.
	otherfile := []cli.Check_Error{{"b.odin", 3, 1, "Cannot assign 'count()' to 's'"}}
	testing.expect_value(t, len(cli.new_errors(otherfile, renamed, names, edited)), 1)
	elsewhere := []cli.Check_Error{{"a.odin", 3, 1, "Cannot assign 'count()' to 's'"}}
	testing.expect_value(t, len(cli.new_errors(elsewhere, renamed, names, edited)), 1)
	// Without edit lines no error is rewritten.
	testing.expect_value(t, len(cli.new_errors(on_edited, renamed, names)), 1)
	// An unmatched error of the edited line is rewritten once: a second new copy stays new.
	twice := []cli.Check_Error{renamed[0], renamed[0]}
	testing.expect_value(t, len(cli.new_errors(on_edited, twice, names, edited)), 1)
}

@(test)
apply_importer_dirs_follow_importers_of_importers :: proc(t: ^testing.T) {
	config: common.Config
	files := []server.Package_File {
		{"/ws/a/a.odin", "package a\n\nimport \"../b\"\n"},
		{"/ws/b/b.odin", "package b\n\nimport \"../c\"\n"},
		{"/ws/c/c.odin", "package c\n\nimport \"../b\"\n"}, // a cycle b <-> c
		{"/ws/d/d.odin", "package d\n\nimport \"../e\"\n"},
		{"/ws/e/e.odin", "package e\n"},
	}
	found := server.importer_dirs([]string{"/ws/c"}, &config, files)
	testing.expect_value(t, len(found), 2)
	if len(found) == 2 {
		testing.expect_value(t, found[0], "/ws/a")
		testing.expect_value(t, found[1], "/ws/b")
	}
	// The unrelated pair is not an importer of c.
	testing.expect_value(t, len(server.importer_dirs([]string{"/ws/a"}, &config, files)), 0)
}

@(test)
apply_gate_targets_follow_the_files_the_host_does_not_build :: proc(t: ^testing.T) {
	host := parser.Build_Target {
		os   = .Darwin,
		arch = .arm64,
	}
	target, need := server.target_for_file("/p/io_windows.odin", "package p\n", host)
	testing.expect_value(t, need, server.Target_Need.Other)
	testing.expect_value(t, target, "windows_amd64")
	target, need = server.target_for_file("/p/io.odin", "#+build js\npackage p\n", host)
	testing.expect_value(t, target, "js_wasm32")
	target, need = server.target_for_file("/p/io.odin", "#+build linux, freebsd\npackage p\n", host)
	testing.expect_value(t, target, "linux_amd64")
	_, need = server.target_for_file("/p/io.odin", "package p\n", host)
	testing.expect_value(t, need, server.Target_Need.None)
	_, need = server.target_for_file("/p/io_darwin.odin", "package p\n", host)
	testing.expect_value(t, need, server.Target_Need.None)
	_, need = server.target_for_file("/p/io.odin", "#+build ignore\npackage p\n", host)
	testing.expect_value(t, need, server.Target_Need.None)
	_, need = server.target_for_file("/p/io.odin", "#+build windows\n#+build linux\npackage p\n", host)
	testing.expect_value(t, need, server.Target_Need.Nowhere)
	target, need = server.target_for_file("/p/io_linux_arm64.odin", "package p\n", {os = .Linux, arch = .amd64})
	testing.expect_value(t, target, "linux_arm64")

	name, ok := server.target_name("windows")
	testing.expect(t, ok)
	testing.expect_value(t, name, "windows_amd64")
	name, ok = server.target_name("js_wasm32")
	testing.expect(t, ok)
	testing.expect_value(t, name, "js_wasm32")
	_, ok = server.target_name("plan9_amd64")
	testing.expect(t, !ok)
	_, ok = server.target_name("darwin_wasm32")
	testing.expect(t, !ok, "an OS and an architecture that odin has no target for")
	testing.expect_value(t, server.base_target("-target:linux_arm64 -vet").arch, runtime.Odin_Arch_Type.arm64)
	testing.expect_value(t, server.gate_check_timeout(0, 8), server.CHECK_TIMEOUT)
	testing.expect_value(t, server.gate_check_timeout(8, 8), server.CHECK_TIMEOUT)
	testing.expect_value(t, server.gate_check_timeout(9, 8), 2 * server.CHECK_TIMEOUT)
	testing.expect_value(t, server.gate_check_timeout(100000, 8), server.GATE_TIMEOUT_CAP)
}

// A build has one project name, so files for different project names never build together. Each
// `#+build-project-name` line must hold, as in the compiler.
@(test)
builds_together_reads_project_names :: proc(t: ^testing.T) {
	together :: proc(text_a, text_b: string) -> bool {
		tags: [2]parser.File_Tags
		for text, i in ([2]string{text_a, text_b}) {
			file := ast.File {
				src      = text,
				fullpath = "/p/x.odin",
			}
			p := parser.Parser {
				flags = {.Optional_Semicolons},
			}
			context.allocator = context.temp_allocator
			parser.parse_file(&p, &file)
			tags[i] = server.build_tags(file)
		}
		return server.builds_together("/p/x.odin", tags[0], "/p/y.odin", tags[1])
	}
	a := "#+build-project-name a\npackage p\n"
	b := "#+build-project-name b\npackage p\n"
	not_a := "#+build-project-name !a\npackage p\n"
	plain := "package p\n"
	testing.expect(t, !together(a, b), "a and b")
	testing.expect(t, together(a, a), "a and a")
	testing.expect(t, !together(a, not_a), "a and !a")
	testing.expect(t, together(b, not_a), "b and !a")
	testing.expect(t, together(not_a, plain), "!a and no tag")
	testing.expect(t, together("#+build-project-name a, b\npackage p\n", b), "a, b and b")
	two_lines := "#+build-project-name a, b\n#+build-project-name !b\npackage p\n"
	testing.expect(t, !together(two_lines, b), "a, b and !b lines and b")
	testing.expect(t, together(two_lines, a), "a, b and !b lines and a")
	spaced := "// +build-project-name a\npackage p\n"
	testing.expect(t, !together(spaced, b), "spaced a comment and b")
	testing.expect(t, together(spaced, a), "spaced a comment and a")
}

@(test)
apply_gate_targets_check_each_target_on_the_packages_that_need_it :: proc(t: ^testing.T) {
	root, dir_err := os.make_directory_temp("", "rols_gate_targets_*", context.temp_allocator)
	if !testing.expect_value(t, dir_err, nil) do return
	defer os.remove_all(root)

	join :: proc(parts: ..string) -> string {
		joined, _ := filepath.join(parts, context.temp_allocator)
		return joined
	}
	// lib is edited. lib_wasi.odin beside it and use_js.odin in an importer that also has a host file are not
	// built on the host. app imports use, other imports only lib.
	sources := [][2]string {
		{"lib/lib.odin", "package lib\n"},
		{"lib/lib_wasi.odin", "package lib\n"},
		{"use/use.odin", "package use\n\nimport \"../lib\"\n"},
		{"use/use_js.odin", "package use\n"},
		{"app/app.odin", "package app\n\nimport \"../use\"\n"},
		{"other/other.odin", "package other\n\nimport \"../lib\"\n"},
	}
	files := make([]server.Package_File, len(sources), context.temp_allocator)
	for source, i in sources {
		file := join(root, source[0])
		os.make_directory_all(filepath.dir(file))
		testing.expect_value(t, os.write_entire_file(file, source[1]), nil)
		files[i] = {file, source[1]}
	}
	lib := join(root, "lib")
	importers := server.importer_dirs({lib}, &common.config, files)
	if !testing.expect_value(t, len(importers), 3) do return
	dirs := []string{lib, importers[0], importers[1], importers[2]}
	changed := []cli.File_State {
		{
			path = files[0].fullpath,
			existed = true,
			original = "package lib\n",
			exists = true,
			text = "package lib\n\nx :: 1\n",
		},
	}

	checks := cli.gate_targets(changed, dirs, importers, nil, files)
	if !testing.expect_value(t, len(checks), 3) do return
	testing.expect_value(t, checks[0].target, "")
	testing.expect_value(t, len(checks[0].dirs), 4)
	// use and its importer app, not lib or other.
	testing.expect_value(t, checks[1].target, "js_wasm32")
	if testing.expect_value(t, len(checks[1].dirs), 2) {
		testing.expect_value(t, checks[1].dirs[0], join(root, "use"))
		testing.expect_value(t, checks[1].dirs[1], join(root, "app"))
	}
	// The sibling of the edited file takes lib and every importer of it.
	testing.expect_value(t, checks[2].target, "wasi_wasm32")
	testing.expect_value(t, len(checks[2].dirs), 4)
	testing.expect_value(t, checks[2].dirs[0], lib)
}

@(test)
apply_recheck_union_absorbs_a_flaky_error_but_not_a_new_copy :: proc(t: ^testing.T) {
	// The first check of the original code missed a redeclaration that a second check reports.
	before := []cli.Check_Error{{"ex/a.odin", 3, 1, "Redeclaration of 'x'"}}
	again := []cli.Check_Error {
		{"ex/a.odin", 3, 1, "Redeclaration of 'x'"},
		{"ex/b.odin", 7, 1, "Redeclaration of 'y'"},
	}
	after := []cli.Check_Error {
		{"ex/b.odin", 7, 1, "Redeclaration of 'y'"},
		{"ex/a.odin", 3, 1, "Redeclaration of 'x'"},
	}
	testing.expect_value(t, len(cli.new_errors(before, after)), 1)
	merged := cli.union_errors(before, again)
	testing.expect_value(t, len(merged), 2)
	testing.expect_value(t, len(cli.new_errors(merged, after)), 0)
	// A key keeps the larger count, so a copy that neither original run reported stays new.
	twice := []cli.Check_Error{after[0], after[0], after[1]}
	testing.expect_value(t, len(cli.new_errors(merged, twice)), 1)
	testing.expect_value(t, len(cli.new_errors(cli.union_errors(before, before), after)), 1)
}

@(private = "file")
file_list :: proc(files: ..string) -> [dynamic]string {
	list := make([dynamic]string, context.temp_allocator)
	append(&list, ..files)
	return list
}

@(test)
apply_recheck_keeps_only_the_directories_that_named_a_fresh_error :: proc(t: ^testing.T) {
	dirs := []string{"/w/lib", "/w/ex", "/w/use"}
	checks := []cli.Gate_Check {
		{dirs = dirs},
		{target = "linux_amd64", dirs = dirs},
		{dirs = dirs, args = "-define:SIM=true"},
	}
	origins := make([]cli.Error_Files, 3, context.temp_allocator)
	for &o in origins {
		o = make(cli.Error_Files, context.temp_allocator)
	}
	origins[0]["/w/ex"] = file_list("/w/ex/a.odin", "/core/chan.odin")
	origins[0]["/w/use"] = file_list("/w/use/u.odin")
	origins[2]["/w/ex"] = file_list("/w/ex/a.odin")
	fresh := []cli.Check_Error{{"/core/chan.odin", 382, 1, "'where' clause evaluated to false"}}
	recheck := cli.recheck_checks(checks, origins, fresh)
	testing.expect_value(t, len(recheck), 1)
	testing.expect_value(t, len(recheck[0].dirs), 1)
	testing.expect_value(t, recheck[0].dirs[0], "/w/ex")
	both := []cli.Check_Error{fresh[0], {"/w/ex/a.odin", 2, 1, "x"}}
	recheck = cli.recheck_checks(checks, origins, both)
	testing.expect_value(t, len(recheck), 2)
	testing.expect_value(t, recheck[1].args, "-define:SIM=true")
	testing.expect_value(t, recheck[1].dirs[0], "/w/ex")
	// A renamed directory is looked up at its new path, and the recheck names the old one.
	moved := make([]cli.Error_Files, 1, context.temp_allocator)
	moved[0] = make(cli.Error_Files, context.temp_allocator)
	moved[0]["/w/lib2"] = file_list("/w/lib2/l.odin")
	renames := []cli.Path_Rename{{"/w/lib", "/w/lib2"}}
	recheck = cli.recheck_checks(checks[:1], moved, {{"/w/lib2/l.odin", 1, 1, "x"}}, renames)
	testing.expect_value(t, recheck[0].dirs[0], "/w/lib")
	// A fresh error whose file no check named keeps every check whole.
	recheck = cli.recheck_checks(checks, origins, {{"/elsewhere.odin", 1, 1, "x"}})
	testing.expect_value(t, len(recheck), 3)
	testing.expect_value(t, len(recheck[0].dirs), 3)
}

@(test)
apply_variants_add_one_check_each_on_the_current_target :: proc(t: ^testing.T) {
	dirs := []string{"/w/a"}
	checks := cli.with_variants({{dirs = dirs}, {target = "js_wasm32", dirs = dirs}}, dirs, {"-define:SIM=true", "  "})
	testing.expect_value(t, len(checks), 3)
	testing.expect_value(t, checks[2].target, "")
	testing.expect_value(t, checks[2].args, "-define:SIM=true")
	testing.expect_value(t, cli.gate_label(checks[1]), "js_wasm32")
	testing.expect_value(t, cli.gate_label(checks[2]), "-define:SIM=true")
	testing.expect_value(t, cli.gate_failure("timed out", checks[0]), "timed out")
	testing.expect_value(t, cli.gate_failure("timed out", checks[1]), "timed out (target js_wasm32)")
	testing.expect_value(t, cli.gate_failure("timed out", checks[2]), "timed out (with -define:SIM=true)")
}

@(test)
apply_second_after_run_keeps_only_errors_both_runs_report :: proc(t: ^testing.T) {
	where_ := cli.Check_Error{"/core/chan.odin", 382, 1, "'where' clause evaluated to false"}
	real := cli.Check_Error{"a.odin", 6, 2, "Undeclared name: one"}
	// A one-off error of the first run after the write is dropped, an error of both runs stays.
	both := cli.intersect_errors({where_, real}, {{"a.odin", 6, 2, "Undeclared name: one"}})
	testing.expect_value(t, len(both), 1)
	testing.expect_value(t, both[0].message, real.message)
	// A key keeps the smaller count.
	testing.expect_value(t, len(cli.intersect_errors({real, real}, {real})), 1)
	testing.expect_value(t, len(cli.intersect_errors({real}, {real, real})), 1)
	testing.expect_value(t, len(cli.intersect_errors({real}, {})), 0)
}
