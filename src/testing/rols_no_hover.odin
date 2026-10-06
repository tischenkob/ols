package ols_testing

import "core:testing"

import "src:server"

// Expects no hover at the cursor.
expect_no_hover :: proc(t: ^testing.T, src: ^Source) {
	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	hover, valid, _ := server.get_hover_information(src.document, cursor)
	testing.expectf(
		t,
		!valid || hover.contents.value == "",
		"\nExpected no hover but received %q",
		hover.contents.value,
	)
}
