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
