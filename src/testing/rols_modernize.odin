package ols_testing

import "core:slice"
import "core:testing"

import "src:server"

// The text modernize leaves for rules, a list of rule ids and family names; none selects the
// default set. Every run must converge and leave the document at its original text. applied,
// when given, lists every applied fix; titles are not compared.
expect_modernized :: proc(
	t: ^testing.T,
	src: ^Source,
	rules: []string,
	expected: string,
	applied: []server.Modernize_Applied = nil,
) {
	setup(src)
	defer teardown(src)

	selected, unknown, ok := server.modernize_select(rules, &src.config)
	if !testing.expectf(t, ok, "Unknown rule %q", unknown) do return

	// Other files resolve names from the open document through the index.
	if len(src.files) > 1 {
		server.collect_symbols(&server.indexer.index.collection, src.document.ast, src.document.uri.uri)
	}
	original := string(src.document.text[:src.document.used_text])
	result := server.modernize_document(src.document, selected, &src.config, source_files(src))
	testing.expectf(t, result.converged, "Expected modernize to converge, failed rules: %v", result.failed)
	testing.expectf(t, result.text == expected, "\nExpected:\n%s\n\nGot:\n%s", expected, result.text)
	testing.expect(t, string(src.document.text[:src.document.used_text]) == original, "Document text changed")
	if applied == nil do return
	ok = len(applied) == len(result.applied)
	for a, i in applied {
		if !ok do break
		b := result.applied[i]
		ok = a.rule == b.rule && a.pass == b.pass && a.line == b.line && a.col == b.col
	}
	testing.expectf(t, ok, "\nExpected applied:\n%v\nGot:\n%v", applied, result.applied)
}

// One pass over fixes: it fails when ok is false, else keeps the fixes of kept, in order. A failed pass
// leaves the document at its text.
expect_modernize_pass :: proc(
	t: ^testing.T,
	src: ^Source,
	fixes: []server.Modernize_Fix,
	ok: bool,
	kept: []string = nil,
) {
	setup(src)
	defer teardown(src)

	original := string(src.document.text[:src.document.used_text])
	got, _, got_ok := server.modernize_pass(src.document, fixes, &src.config)
	testing.expectf(t, got_ok == ok, "Expected the pass to succeed: %v, got %v", ok, got_ok)
	if !ok {
		testing.expect(t, string(src.document.text[:src.document.used_text]) == original, "Document text changed")
		testing.expect(t, src.document.ast.syntax_error_count == 0, "Document left unparsed")
		return
	}
	rules := make([]string, len(got), context.temp_allocator)
	for fix, i in got do rules[i] = fix.rule
	testing.expectf(t, slice.equal(rules, kept), "Expected kept %v, got %v", kept, rules)
}
