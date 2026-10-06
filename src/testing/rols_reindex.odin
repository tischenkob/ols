package ols_testing

import "core:log"
import "core:strings"
import "core:testing"

import "src:common"
import "src:server"

// Like expect_hover, after `index_file` reindexes each of `reindexed` in order, as a save does.
expect_hover_after_reindex :: proc(t: ^testing.T, src: ^Source, reindexed: []File, expect_hover_string: string) {
	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	for file in reindexed {
		fullpath := strings.join({"test", file.name}, "/", context.temp_allocator)
		uri := common.create_uri(fullpath, context.temp_allocator)
		testing.expectf(t, server.index_file(uri, file.source) == .None, "Expected %s to reindex", file.name)
	}

	hover, valid, ok := server.get_hover_information(src.document, cursor)
	if !ok || !valid {
		log.error("Failed get_hover_information")
		return
	}

	first_strip, _ := strings.remove(hover.contents.value, "```odin\n", 2, context.temp_allocator)
	content, _ := strings.remove(first_strip, "\n```", 2, context.temp_allocator)
	if content != expect_hover_string {
		log.errorf("Expected hover string:\n%q, but received:\n%q", expect_hover_string, content)
	}
}

// Like expect_action_missing, while each of `unsaved` holds edits that are not saved: the action
// reads that text, and the index keeps the text of src.
expect_action_missing_unsaved :: proc(t: ^testing.T, src: ^Source, action_name: string, unsaved: []File) {
	input_range := source_remove_selection(src)

	setup(src)
	defer teardown(src)

	// Other files resolve names from the open document through the index.
	server.collect_symbols(&server.indexer.index.collection, src.document.ast, src.document.uri.uri)

	files := package_files(src)
	for file in unsaved {
		fullpath := strings.join({"test", file.name}, "/", context.temp_allocator)
		for &f in files {
			if f.fullpath == fullpath do f.text = file.source
		}
	}
	actions, ok := server.get_code_actions(src.document, {}, input_range, &src.config, files)
	if !ok {
		log.error("Failed to find actions")
		return
	}
	for action in actions {
		testing.expectf(t, action.title != action_name, "Expected action '%s' to be missing: %v", action_name, actions)
	}
}
