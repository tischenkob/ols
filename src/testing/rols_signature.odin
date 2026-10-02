package ols_testing

import "core:log"
import "core:slice"
import "core:testing"

import "src:server"

// Expects exactly `expect_labels` as the signature labels, in that order.
expect_signature_label_order :: proc(t: ^testing.T, src: ^Source, expect_labels: []string) {
	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	help, _ := server.get_signature_information(src.document, cursor, &src.config)

	labels := make([]string, len(help.signatures), context.temp_allocator)
	for signature, i in help.signatures {
		labels[i] = signature.label
	}

	if !slice.equal(labels, expect_labels) {
		log.errorf("Expected signature labels %v, but received %v", expect_labels, labels)
	}
}
