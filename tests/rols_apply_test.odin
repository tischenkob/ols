package tests

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
	testing.expect_value(t, os.write_entire_file(edited, "changed\n"), nil)
	testing.expect_value(t, os.write_entire_file(created, "new\n"), nil)

	failures := cli.restore_files(
		{
			{path = edited, existed = true, original = "package a\n", exists = true, text = "changed\n"},
			{path = created, exists = true, text = "new\n"},
			{path = unwritable, existed = true, original = "package c\n", exists = true},
		},
	)

	data, _ := os.read_entire_file(edited, context.temp_allocator)
	testing.expect_value(t, string(data), "package a\n")
	testing.expect(t, !os.exists(created), "a created file is deleted")
	if testing.expect_value(t, len(failures), 1) {
		testing.expectf(t, strings.contains(failures[0], "c.odin remains modified"), "failure: %q", failures[0])
	}
}
