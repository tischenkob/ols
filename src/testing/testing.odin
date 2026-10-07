package ols_testing

// rols: seed_check_diagnostic allocates off the tracked test allocators
import "base:runtime"
// rols: overwrite_stack
import "base:intrinsics"
import "core:fmt"
import "core:log"
import "core:mem/virtual"
import "core:odin/ast"
import "core:odin/parser"
import "core:slice"
import "core:strings"
// rols: seed_mutex
import "core:sync"
import "core:testing"

import "src:common"
import "src:server"
import "src:spall"

File :: struct {
	name:   string,
	source: string,
}

Package :: struct {
	pkg:    string,
	source: string, // backwards compatable–for single-file packages
	files:  []File,
}

Source :: struct {
	main:        string, // backwards compatable–for single-file packages
	files:       []File,
	packages:    []Package,
	document:    ^server.Document,
	collections: map[string]string,
	config:      common.Config,
}

@(private)
setup :: proc(src: ^Source) {
	spall.thread_begin()

	spall.trace(#procedure)

	// rols: share the test's collections with code that reads the global config
	lock_global_collections(src)

	src.document = new(server.Document)

	src.document.client_owned = true
	src.document.allocator = new(virtual.Arena)
	src.document.symbol_cache_arena = new(virtual.Arena)
	src.document.package_name = "test"

	_ = virtual.arena_init_growing(src.document.allocator)
	_ = virtual.arena_init_growing(src.document.symbol_cache_arena)

	if len(src.main) > 0 {
		src.files = slice.concatenate([][]File{{{"main.odin", src.main}}, src.files}, context.temp_allocator)
		src.main = ""
	}

	if len(src.files) <= 0 {
		log.error("Expected at least one file")
		return
	}

	f := &src.files[0]
	source := transmute([]u8)f.source

	fullpath := strings.join({"test", f.name}, "/", context.temp_allocator)
	src.document.uri = common.create_uri(fullpath, context.temp_allocator)
	src.document.text = source
	src.document.used_text = len(source)

	// Make the test packages reachable through the collections
	if len(src.collections) > 0 {
		server.build_cache.pkg_aliases = make(map[string][dynamic]string, 0, context.temp_allocator)
	}

	for collection, collection_path in src.collections {
		src.config.collections[collection] = collection_path

		aliases := make([dynamic]string, context.temp_allocator)

		for src_pkg in src.packages {
			append(&aliases, src_pkg.pkg)
		}

		server.build_cache.pkg_aliases[collection] = aliases
	}

	builtin_path := server.get_builtin_path()
	server.setup_index(builtin_path)
	defer delete(builtin_path)

	// Set the collection's config to the test's config to enable feature flags like enable_fake_method
	server.indexer.index.collection.config = &src.config

	server.document_setup(src.document)

	server.document_refresh(src.document, &src.config, nil)

	context.allocator = virtual.arena_allocator(src.document.allocator)

	if len(src.files) > 1 {
		pkg := new(ast.Package, context.temp_allocator)
		pkg.name = "test"
		pkg.fullpath = "test"
		pkg.name = "test"

		for f in src.files[1:] {
			process_file(f.name, f.source, pkg)
		}
	}

	for src_pkg in src.packages {
		context.allocator = virtual.arena_allocator(src.document.allocator)

		pkg := new(ast.Package, context.temp_allocator)
		pkg.name = src_pkg.pkg
		pkg.fullpath = strings.join({"test", pkg.name}, "/", context.temp_allocator)

		if pkg.name == "runtime" || strings.contains(pkg.fullpath, "base/runtime") {
			pkg.kind = .Runtime
		}

		if len(src_pkg.files) > 0 do for f in src_pkg.files {
			process_file(f.name, f.source, pkg)
		}
		else {
			process_file("package.odin", src_pkg.source, pkg)
		}
	}

	process_file :: proc(filename: string, source: string, pkg: ^ast.Package) {

		fullpath := strings.join({pkg.fullpath, filename}, "/", context.temp_allocator)

		p := parser.Parser {
			err   = parser.default_error_handler,
			warn  = parser.default_error_handler,
			flags = {.Optional_Semicolons},
		}

		file := ast.File {
			fullpath = fullpath,
			src      = source,
			pkg      = pkg,
		}

		ok := server.parse_file(&p, &file)

		if !ok || file.syntax_error_count > 0 {
			panic("Parser error in test package source")
		}

		uri := common.create_uri(fullpath, context.temp_allocator)

		err := server.collect_symbols(&server.indexer.index.collection, file, uri.uri)
		// rols: the collections of other targets read test sources from memory
		server.note_unsaved_file(fullpath, source)
		if err != .None {
			log.errorf("Error (%v) while collecting symbols in file (%s) \"%s\"", err, fullpath, source)
		}
	}
}

@(private)
teardown :: proc(src: ^Source) {

	defer spall.thread_end()
	spall.trace(#procedure)

	// rols: take the test's collections out of the global config
	unlock_global_collections(src)

	// rols: free the seeded checker diagnostic and release the lock it took
	if seed_locked {
		seed_locked = false
		{
			context.allocator = runtime.default_allocator()
			server.reset_diagnostics()
		}
		sync.unlock(&seed_mutex)
	}

	server.free_index()
	server.indexer.index = {}
	server.build_cache.pkg_aliases = {}

	delete(src.config.collections)
	delete(src.collections)
	delete(src.document.package_name)
	when ODIN_OS == .Windows {
		// Only on Windows fullpath is allocated (replace_separators in document_setup); elsewhere it's an alias of uri.path
		delete(src.document.fullpath)
	}

	virtual.arena_destroy(src.document.allocator)
	free(src.document.allocator)

	virtual.arena_destroy(src.document.symbol_cache_arena)
	free(src.document.symbol_cache_arena)

	free(src.document)
	src.document = nil
}

source_remove_cursor :: proc(src: ^Source) -> (cursor: common.Position) {

	source: ^string
	if src.main != "" {
		source = &src.main
	} else if len(src.files) > 0 {
		source = &src.files[0].source
	}

	if source == nil || len(source) == 0 {
		log.error("Cannot get cursor from an empty file")
		return
	}

	CURSOR :: "{*}"

	marker_pos := strings.index(source^, CURSOR)
	if marker_pos < 0 {
		log.errorf("Didn't find %s in `%s`", CURSOR, source^)
		return
	}

	// remove cursor mark from source
	new_source := make([]u8, len(source) - len(CURSOR), context.temp_allocator)
	copy(new_source[:marker_pos], source[:marker_pos])
	copy(new_source[marker_pos:], source[marker_pos + len(CURSOR):])
	source^ = string(new_source)

	// find cursor (line,col) position
	return common.get_relative_token_position(marker_pos, transmute([]u8)source^, 0)
}

// rols: selection sources and a shared document fixture
// Selection between `{[` and `]}`. Without `{[`, the cursor marker is used and the range is empty.
source_remove_selection :: proc(src: ^Source) -> common.Range {
	source: ^string
	if src.main != "" {
		source = &src.main
	} else if len(src.files) > 0 {
		source = &src.files[0].source
	}

	if source == nil {
		log.error("Cannot get selection from an empty file")
		return {}
	}

	START :: "{["
	END :: "]}"

	start := strings.index(source^, START)
	if start < 0 {
		cursor := source_remove_cursor(src)
		return {cursor, cursor}
	}

	//Only search after the start marker, Odin source has plenty of `]}` of its own.
	end := strings.index(source[start + len(START):], END)
	if end < 0 {
		log.errorf("Didn't find %s after %s in `%s`", END, START, source^)
		return {}
	}
	end += start + len(START)

	new_source := strings.concatenate(
		{source[:start], source[start + len(START):end], source[end + len(END):]},
		context.temp_allocator,
	)
	source^ = new_source

	text := transmute([]u8)source^
	return {
		common.get_relative_token_position(start, text, 0),
		common.get_relative_token_position(end - len(START), text, 0),
	}
}

// Runs f against the parsed and indexed document, with the `{[`…`]}` or `{*}` range.
with_document :: proc(t: ^testing.T, src: ^Source, f: proc(t: ^testing.T, src: ^Source, range: common.Range)) {
	range := source_remove_selection(src)

	setup(src)
	defer teardown(src)

	f(t, src, range)
}

expect_signature_labels :: proc(
	t: ^testing.T,
	src: ^Source,
	expect_labels: []string,
	expected_active_parameter := -1,
) {
	spall.trace(#procedure)

	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	help, ok := server.get_signature_information(src.document, cursor, &src.config)

	if !ok {
		log.error("Failed get_signature_information")
	}

	if len(expect_labels) == 0 && len(help.signatures) > 0 {
		log.errorf("Expected empty signature label, but received %v", help.signatures)
	}

	flags := make([]int, len(expect_labels), context.temp_allocator)

	for expect_label, i in expect_labels {
		for signature, j in help.signatures {
			if expect_label == signature.label {
				flags[i] += 1
			}
		}
	}

	for flag, i in flags {
		if flag != 1 {
			log.errorf("Expected signature label %v, but received %v", expect_labels[i], help.signatures)
		}
	}

	if expected_active_parameter != -1 {
		if expected_active_parameter != help.activeParameter {
			log.errorf(
				"Expected active parameter %v, but reveived %v",
				expected_active_parameter,
				help.activeParameter,
			)
		}
	}
}

expect_signature_parameter_position :: proc(t: ^testing.T, src: ^Source, position: int) {
	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	help, ok := server.get_signature_information(src.document, cursor, &src.config)

	if help.activeParameter != position {
		log.errorf("expected parameter position %v, but received %v", position, help.activeParameter)
	}
}

expect_completion_labels :: proc(
	t: ^testing.T,
	src: ^Source,
	trigger_character: string,
	expect_labels: []string,
	expect_excluded: []string = nil,
) {
	spall.trace(#procedure)

	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	completion_context := server.CompletionContext {
		triggerCharacter = trigger_character,
	}

	completion_list, ok := server.get_completion_list(src.document, cursor, completion_context, &src.config)

	if !ok {
		log.error("Failed get_completion_list")
	}

	missing_expected := make([dynamic]string, context.temp_allocator)
	loop_expected: for label, i in expect_labels {
		for completion, j in completion_list.items {
			if label == completion.label {
				continue loop_expected
			}
		}
		append(&missing_expected, label)
	}

	present_excluded := make([dynamic]string, context.temp_allocator)
	loop_excluded: for label, i in expect_excluded {
		for completion, j in completion_list.items {
			if label == completion.label {
				append(&present_excluded, label)
				continue loop_excluded
			}
		}
	}

	if len(missing_expected) > 0 ||
	   len(present_excluded) > 0 ||
	   (len(expect_labels) == 0 && len(completion_list.items) > 0) {
		sb := strings.builder_make(context.temp_allocator)
		defer log.error(strings.to_string(sb))

		fmt.sbprintln(&sb, "Completion label mismatch.")

		strings.write_string(&sb, "Actual:   [")
		for completion, i in completion_list.items {
			if i > 0 {
				strings.write_string(&sb, ", ")
			}
			fmt.sbprintf(&sb, "\"%s\"", completion.label)
		}
		strings.write_string(&sb, "]\n")

		if len(missing_expected) > 0 {
			fmt.sbprintfln(&sb, "Expected: %v", expect_labels)
			fmt.sbprintfln(&sb, "Missing:  %v", missing_expected[:])
		}

		if len(present_excluded) > 0 {
			fmt.sbprintfln(&sb, "Excluded: %v", expect_excluded)
			fmt.sbprintfln(&sb, "Present:  %v", present_excluded[:])
		}
	}
}

// Checks that every expected label appears exactly once and in the given order.
// Ivar tests use this to verify that fields appear before fake methods.
expect_completion_label_order :: proc(
	t: ^testing.T,
	src: ^Source,
	trigger_character: string,
	expect_labels: []string,
) {
	spall.trace(#procedure)

	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	completion_context := server.CompletionContext {
		triggerCharacter = trigger_character,
	}
	completion_list, ok := server.get_completion_list(src.document, cursor, completion_context, &src.config)
	if !ok {
		log.error("Failed get_completion_list")
	}

	previous_index := -1
	for label in expect_labels {
		index := -1
		count := 0
		for completion, i in completion_list.items {
			if completion.label == label {
				index = i
				count += 1
			}
		}
		if count != 1 {
			log.errorf("Expected one completion labeled %q, received %v", label, count)
		} else if index <= previous_index {
			log.errorf("Expected completion labels in order %v, received %v", expect_labels, completion_list.items)
		}
		previous_index = index
	}
}

expect_completion_docs :: proc(
	t: ^testing.T,
	src: ^Source,
	trigger_character: string,
	expect_details: []string,
	expect_excluded: []string = nil,
) {
	spall.trace(#procedure)

	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	get_doc :: proc(doc: server.CompletionDocumention) -> string {
		switch v in doc {
		case string:
			return v
		case server.MarkupContent:
			first_strip, _ := strings.remove(v.value, "```odin\n", 2, context.temp_allocator)
			content_without_markdown, _ := strings.remove(first_strip, "\n```", 2, context.temp_allocator)
			return content_without_markdown
		}
		return ""
	}

	completion_context := server.CompletionContext {
		triggerCharacter = trigger_character,
	}

	completion_list, ok := server.get_completion_list(src.document, cursor, completion_context, &src.config)

	if !ok {
		log.error("Failed get_completion_list")
	}

	if len(expect_details) == 0 && len(completion_list.items) > 0 {
		log.errorf("Expected empty completion docs, but received %v", completion_list.items)
	}

	flags := make([]int, len(expect_details), context.temp_allocator)

	for expect_detail, i in expect_details {
		for completion, j in completion_list.items {
			if expect_detail == get_doc(completion.documentation) {
				flags[i] += 1
			}
		}
	}

	for flag, i in flags {
		if flag != 1 {
			log.errorf("Expected completion docs %v, but received %v", expect_details[i], completion_list.items)
		}
	}

	for expect_exclude in expect_excluded {
		for completion in completion_list.items {
			if expect_exclude == get_doc(completion.documentation) {
				log.errorf("Expected completion label %v to not be included", expect_exclude)
			}
		}
	}
}

expect_completion_insert_text :: proc(
	t: ^testing.T,
	src: ^Source,
	trigger_character: string,
	expect_inserts: []string,
) {
	spall.trace(#procedure)

	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	completion_context := server.CompletionContext {
		triggerCharacter = trigger_character,
	}

	completion_list, ok := server.get_completion_list(src.document, cursor, completion_context, &src.config)

	if !ok {
		log.error("Failed get_completion_list")
	}

	if len(expect_inserts) == 0 && len(completion_list.items) > 0 {
		log.errorf("Expected empty completion inserts, but received %v", completion_list.items)
	}

	flags := make([]int, len(expect_inserts), context.temp_allocator)

	for expect_insert, i in expect_inserts {
		for completion, j in completion_list.items {
			if insert_text, ok := completion.insertText.(string); ok {
				if expect_insert == insert_text {
					flags[i] += 1
					continue
				}
			}
		}
	}

	for flag, i in flags {
		if flag != 1 {
			log.errorf("Expected completion insert %v, but received %v", expect_inserts[i], completion_list.items)
		}
	}
}

expect_completion_edit_text :: proc(
	t: ^testing.T,
	src: ^Source,
	trigger_character: string,
	label: string,
	expected_text: string,
) {
	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	completion_context := server.CompletionContext {
		triggerCharacter = trigger_character,
	}

	completion_list, ok := server.get_completion_list(src.document, cursor, completion_context, &src.config)

	if !ok {
		log.error("Failed get_completion_list")
	}

	found := false
	for completion in completion_list.items {
		if completion.label == label {
			found = true
			if text_edit, has_edit := completion.textEdit.(server.TextEdit); has_edit {
				if text_edit.newText != expected_text {
					log.errorf(
						"Completion '%v' expected textEdit.newText %q, but received %q",
						label,
						expected_text,
						text_edit.newText,
					)
				}
			} else {
				log.errorf("Completion '%v' has no textEdit", label)
			}
			break
		}
	}
	if !found {
		log.errorf("Expected completion label '%v' not found in %v", label, completion_list.items)
	}
}

expect_completion_edits :: proc(
	t: ^testing.T,
	src: ^Source,
	trigger_character: string,
	label: string,
	expected_edit: server.CompletionTextEdit,
	expected_additional_edits: []server.TextEdit = nil,
) {
	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	completion_context := server.CompletionContext {
		triggerCharacter = trigger_character,
	}

	completion_list, ok := server.get_completion_list(src.document, cursor, completion_context, &src.config)
	if !ok {
		log.error("Failed get_completion_list")
		return
	}

	for completion in completion_list.items {
		if completion.label != label do continue

		testing.expect_value(t, completion.textEdit, expected_edit)
		additional_edits := completion.additionalTextEdits.([]server.TextEdit) or_else nil
		testing.expect(t, slice.equal(additional_edits, expected_additional_edits))
		return
	}

	testing.expectf(t, false, "Expected completion label '%v' not found in %v", label, completion_list.items)
}

expect_hover :: proc(t: ^testing.T, src: ^Source, expect_hover_string: string) {
	spall.trace(#procedure)

	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	hover, valid, ok := server.get_hover_information(src.document, cursor, &src.config)

	if !ok {
		log.error(t, "Failed get_hover_information")
		return
	}

	if !valid {
		log.error(t, "Failed get_hover_information")
		return
	}

	first_strip, _ := strings.remove(hover.contents.value, "```odin\n", 2, context.temp_allocator)
	content_without_markdown, _ := strings.remove(first_strip, "\n```", 2, context.temp_allocator)

	if content_without_markdown != expect_hover_string {
		log.errorf("Expected hover string:\n%q, but received:\n%q", expect_hover_string, content_without_markdown)
	}
}

expect_hover_contains :: proc(t: ^testing.T, src: ^Source, expect_substring: string) {
	spall.trace(#procedure)

	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	hover, valid, ok := server.get_hover_information(src.document, cursor, &src.config)

	if !ok || !valid {
		log.error(t, "Failed get_hover_information")
		return
	}

	if !strings.contains(hover.contents.value, expect_substring) {
		log.errorf("Expected hover to contain:\n%q, but received:\n%q", expect_substring, hover.contents.value)
	}
}

expect_definition_locations :: proc(t: ^testing.T, src: ^Source, expect_locations: []common.Location) {
	spall.trace(#procedure)

	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	locations, ok := server.get_definition_location(src.document, cursor, &src.config)
	if !ok && len(expect_locations) > 0 {
		log.error("No definitions found.")
		return
	}

	// rols: failure output uses temp memory so a failed assertion reports no leaks
	extra_expected, extra_locations, all_good := compare_expected_slice_set(
		locations, expect_locations, allocator = context.temp_allocator, equals = proc (a, e: common.Location) -> bool {
			if e.uri != "" {
				if a.range == e.range && a.uri == e.uri {
					return true
				}
			} else if a.range == e.range {
				return true
			}
			return false
	})
	if all_good do return

	// rols: failure output uses temp memory so a failed assertion reports no leaks
	sb := strings.builder_make(context.temp_allocator)

	if len(extra_expected) > 0 {
		strings.write_rune(&sb, '\n')
		strings.write_int(&sb, len(extra_expected))
		strings.write_string(&sb,  " Definition(s) expected but not reported:\n")
		for i in extra_expected {
			loc := expect_locations[i]
			if loc.uri == "" {
				loc.uri = "test/main.odin"
			}
			strings.write_string(&sb,
				source_location_display(src^, loc, before=ANSI_RED_BG, allocator=context.temp_allocator))
		}
	}

	if len(extra_locations) > 0 {
		strings.write_rune(&sb, '\n')
		strings.write_int(&sb, len(extra_locations))
		strings.write_string(&sb,  " Definition(s) reported but not expected:\n")
		for i in extra_locations {
			strings.write_string(&sb,
				source_location_display(src^, locations[i], before=ANSI_GREEN_BG, allocator=context.temp_allocator))
		}
	}

	log.error(strings.to_string(sb))
}

expect_type_definition_locations :: proc(t: ^testing.T, src: ^Source, expect_locations: []common.Location) {
	spall.trace(#procedure)

	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	locations, ok := server.get_type_definition_locations(src.document, cursor)
	if !ok && len(expect_locations) > 0 {
		log.error("No type definitions found.")
		return
	}

	// rols: failure output uses temp memory so a failed assertion reports no leaks
	extra_expected, extra_locations, all_good := compare_expected_slice_set(
		locations, expect_locations, allocator = context.temp_allocator, equals = proc (a, e: common.Location) -> bool {
			if e.uri != "" {
				if a.range == e.range && a.uri == e.uri {
					return true
				}
			} else if a.range == e.range {
				return true
			}
			return false
	})
	if all_good do return

	// rols: failure output uses temp memory so a failed assertion reports no leaks
	sb := strings.builder_make(context.temp_allocator)

	if len(extra_expected) > 0 {
		strings.write_rune(&sb, '\n')
		strings.write_int(&sb, len(extra_expected))
		strings.write_string(&sb,  " Type definition(s) expected but not reported:\n")
		for i in extra_expected {
			loc := expect_locations[i]
			if loc.uri == "" {
				loc.uri = "test/main.odin"
			}
			strings.write_string(&sb,
				source_location_display(src^, loc, before=ANSI_RED_BG, allocator=context.temp_allocator))
		}
	}

	if len(extra_locations) > 0 {
		strings.write_rune(&sb, '\n')
		strings.write_int(&sb, len(extra_locations))
		strings.write_string(&sb,  " Type definition(s) reported but not expected:\n")
		for i in extra_locations {
			strings.write_string(&sb,
				source_location_display(src^, locations[i], before=ANSI_GREEN_BG, allocator=context.temp_allocator))
		}
	}

	log.error(strings.to_string(sb))
}

expect_reference_locations :: proc(
	t: ^testing.T,
	src: ^Source,
	expect_locations: []common.Location,
	include_declaration := true,
) {
	spall.trace(#procedure)

	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	locations, got_references := server.get_references(src.document, cursor, include_declaration = include_declaration)
	if !got_references && len(expect_locations) > 0 {
		log.error("No references found.")
		return
	}

	// rols: failure output uses temp memory so a failed assertion reports no leaks
	extra_expected, extra_locations, all_good := compare_expected_slice_set(locations, expect_locations,
	                                                                        allocator = context.temp_allocator,
	                                                                        equals = proc (a, b: common.Location) -> bool {return a.range == b.range})
	if all_good do return

	// rols: failure output uses temp memory so a failed assertion reports no leaks
	sb := strings.builder_make(context.temp_allocator)

	if len(extra_expected) > 0 {
		strings.write_rune(&sb, '\n')
		strings.write_int(&sb, len(extra_expected))
		strings.write_string(&sb,  " Reference(s) expected but not reported:\n")
		for i in extra_expected {
			loc := expect_locations[i]
			if loc.uri == "" {
				loc.uri = "test/main.odin"
			}
			strings.write_string(&sb,
				source_location_display(src^, loc, before=ANSI_RED_BG, allocator=context.temp_allocator))
		}
	}

	if len(extra_locations) > 0 {
		strings.write_rune(&sb, '\n')
		strings.write_int(&sb, len(extra_locations))
		strings.write_string(&sb,  " Reference(s) reported but not expected:\n")
		for i in extra_locations {
			strings.write_string(&sb,
				source_location_display(src^, locations[i], before=ANSI_GREEN_BG, allocator=context.temp_allocator))
		}
	}

	log.error(strings.to_string(sb))
}

expect_prepare_rename_range :: proc(t: ^testing.T, src: ^Source, expect_range: common.Range) {
	spall.trace(#procedure)

	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	range, ok := server.get_prepare_rename(src.document, cursor)
	if !ok {
		log.error("Failed to find range")
	}

	if range != expect_range {
		ok = false
		log.errorf("Failed to match with range: %v", expect_range)
	}

	if !ok {
		log.error("Received: %v\n", range)
	}
}


// rols: takes a selection and the package files
expect_action :: proc(t: ^testing.T, src: ^Source, expect_action_names: []string, ctx: server.CodeActionContext = {}) {
	spall.trace(#procedure)

	input_range := source_remove_selection(src)

	setup(src)
	defer teardown(src)

	actions, ok := server.get_code_actions(src.document, ctx, input_range, &src.config, package_files(src))
	if !ok {
		log.error("Failed to find actions")
	}

	if len(expect_action_names) == 0 && len(actions) > 0 {
		log.errorf("Expected empty actions, but received %v", actions)
	}

	flags := make([]int, len(expect_action_names), context.temp_allocator)

	for name, i in expect_action_names {
		for action, j in actions {
			if action.title == name {
				flags[i] += 1
			}
		}
	}

	for flag, i in flags {
		if flag != 1 {
			log.errorf("Expected action %v, but received %v", expect_action_names[i], actions)
		}
	}
}

// rols: takes a selection
expect_action_with_edit :: proc(t: ^testing.T, src: ^Source, action_name: string, expected_new_text: string) {
	spall.trace(#procedure)

	input_range := source_remove_selection(src)

	setup(src)
	defer teardown(src)

	actions, ok := server.get_code_actions(src.document, {}, input_range, &src.config)
	if !ok {
		log.error("Failed to find actions")
		return
	}

	for action in actions {
		if action.title == action_name {
			// Get the text edit for the document
			if edits, found := action.edit.changes[src.document.uri.uri]; found {
				if len(edits) > 0 {
					actual_text := edits[0].newText
					testing.expectf(
						t,
						actual_text == expected_new_text,
						"\nExpected edit text:\n%s\n\nGot:\n%s",
						expected_new_text,
						actual_text,
					)
					return
				}
			}
			log.errorf("Action '%s' found but has no edits", action_name)
			return
		}
	}

	log.errorf("Action '%s' not found in actions: %v", action_name, actions)
}

// rols: the test's collections in the global config
/*
	The reference search parses the imports of other files with `common.config`, so `setup` copies the test's
	collections there. The config is a process global: a test with collections holds `collections_mutex` alone,
	and every other test holds it shared, so no test reads the map while another one changes it.
*/
@(private)
collections_mutex: sync.RW_Mutex
@(private, thread_local)
collections_exclusive: bool
@(private, thread_local)
collections_made_map: bool

@(private)
lock_global_collections :: proc(src: ^Source) {
	if len(src.collections) == 0 {
		sync.shared_lock(&collections_mutex)
		return
	}

	sync.lock(&collections_mutex)
	collections_exclusive = true
	collections_made_map = common.config.collections == nil
	for name, path in src.collections {
		common.config.collections[name] = path
	}
}

@(private)
unlock_global_collections :: proc(src: ^Source) {
	if !collections_exclusive {
		sync.shared_unlock(&collections_mutex)
		return
	}

	for name in src.collections {
		delete_key(&common.config.collections, name)
	}
	if collections_made_map {
		delete(common.config.collections)
		common.config.collections = nil
	}
	collections_exclusive = false
	sync.unlock(&collections_mutex)
}

// rols: lets a test stand in for the checker
seed_mutex: sync.Mutex
@(thread_local)
seed_locked: bool

/*
	Puts one checker diagnostic on the main file, which no test ever runs the checker for. Call it
	before the assertion, which runs the setup. The positions are those of the source without its
	cursor mark. The diagnostic is allocated off the per-test allocators, and the teardown frees it
	with the same allocator.

	Every seed goes to the global maps, so a seeding test holds `seed_mutex` until its teardown to
	keep parallel tests from swapping the diagnostic under it.
*/
seed_check_diagnostic :: proc(src: ^Source, line, col, end_col: int, message: string) {
	sync.lock(&seed_mutex)
	seed_locked = true

	name := len(src.main) > 0 ? "main.odin" : src.files[0].name

	context.allocator = runtime.default_allocator()
	uri := common.create_uri(strings.join({"test", name}, "/", context.temp_allocator), context.temp_allocator)

	config := common.Config {
		enable_diagnostics = true,
	}
	server.add_diagnostics(
		.Check,
		uri.uri,
		server.Diagnostic {
			code = "checker",
			severity = .Error,
			range = {start = {line = line, character = col}, end = {line = line, character = end_col}},
			message = message,
		},
		&config,
	)
}

// rols: splits out the apply so other assertions can reuse it
/*
	Applies all the edits of a code action to the document and compares the result with `expected`.

	The edits are applied back to front, which is one of the orders a client is allowed to use, and
	the one that will produce a different result than a client applying them front to back if any of
	the edits overlap. Overlapping edits are reported as an error for the same reason.
*/
expect_action_applied :: proc(
	t: ^testing.T,
	src: ^Source,
	action_name: string,
	expected: string,
	ctx: server.CodeActionContext = {},
) {
	text, ok := apply_action(t, src, action_name, ctx)
	if ok {
		testing.expectf(t, text == expected, "\nExpected:\n%s\n\nGot:\n%s", expected, text)
	}
}

// rols: action text without an assertion
// The document text with the edits of the named action applied, in the temp allocator.
apply_action :: proc(
	t: ^testing.T,
	src: ^Source,
	action_name: string,
	ctx: server.CodeActionContext = {},
) -> (
	string,
	bool,
) {
	spall.trace(#procedure)

	input_range := source_remove_selection(src)

	setup(src)
	defer teardown(src)

	actions, ok := server.get_code_actions(src.document, ctx, input_range, &src.config, package_files(src))
	if !ok {
		log.error("Failed to find actions")
		return "", false
	}

	for action in actions {
		if action.title != action_name {
			continue
		}

		edits, found := action.edit.changes[src.document.uri.uri]

		if !found {
			log.errorf("Action '%s' found but has no edits", action_name)
			return "", false
		}

		text, applied := common.apply_text_edits(edits, string(src.document.text))
		if !applied {
			log.errorf("Action '%s' has an invalid or overlapping edit range: %v", action_name, edits)
			return "", false
		}
		return strings.clone(text, context.temp_allocator), true
	}

	log.errorf("Action '%s' not found in actions: %v", action_name, actions)
	return "", false
}

// rols: organize-imports-on-save assertion
expect_save_imports_applied :: proc(t: ^testing.T, src: ^Source, expected: string) {
	spall.trace(#procedure)

	setup(src)
	defer teardown(src)

	ast_context := server.make_ast_context(
		src.document.ast,
		src.document.imports,
		src.document.package_name,
		src.document.uri.uri,
		src.document.fullpath,
		context.temp_allocator,
	)

	edits := server.organize_import_edits(src.document, &ast_context, &src.config, true)

	text, applied := common.apply_text_edits(edits, string(src.document.text))
	testing.expectf(t, applied, "Invalid or overlapping edit range in %v", edits)

	testing.expectf(t, text == expected, "\nExpected:\n%s\n\nGot:\n%s", expected, text)
}

// rols: asserts an action is not offered
expect_action_missing :: proc(t: ^testing.T, src: ^Source, action_name: string) {
	spall.trace(#procedure)

	input_range := source_remove_selection(src)

	setup(src)
	defer teardown(src)

	// Other files resolve names from the open document through the index.
	if len(src.files) > 1 {
		server.collect_symbols(&server.indexer.index.collection, src.document.ast, src.document.uri.uri)
	}

	actions, ok := server.get_code_actions(src.document, {}, input_range, &src.config, package_files(src))
	if !ok {
		log.error("Failed to find actions")
		return
	}

	for action in actions {
		if action.title == action_name {
			log.errorf("Expected action '%s' to be missing, but received %v", action_name, actions)
			return
		}
	}
}

expect_semantic_tokens :: proc(t: ^testing.T, src: ^Source, expected: []server.SemanticToken) {
	spall.trace(#procedure)

	setup(src)
	defer teardown(src)


	resolve_flag: server.ResolveReferenceFlag
	symbols_and_nodes := server.resolve_entire_file(src.document)

	range := common.Range {
		end = {line = 9000000},
	} //should be enough
	tokens := server.get_semantic_tokens(src.document, range, symbols_and_nodes)

	testing.expectf(
		t,
		len(expected) == len(tokens),
		"\nExpected %d tokens, but received %d",
		len(expected),
		len(tokens),
	)

	for i in 0 ..< min(len(expected), len(tokens)) {
		e, a := expected[i], tokens[i]
		testing.expectf(
			t,
			e == a,
			"\n[%d]: Expected \n(%d, %d, %d, %v, %w)\nbut received\n(%d, %d, %d, %v, %w)",
			i,
			e.delta_line,
			e.delta_char,
			e.len,
			e.type,
			e.modifiers,
			a.delta_line,
			a.delta_char,
			a.len,
			a.type,
			a.modifiers,
		)
	}
}

resolution_cancel_checks: int

@(private)
cancel_resolution_after_start :: proc() -> bool {
	resolution_cancel_checks += 1
	return resolution_cancel_checks > 1
}

expect_file_resolution_cancelled :: proc(t: ^testing.T, src: ^Source) {
	setup(src)
	defer teardown(src)

	resolution_cancel_checks = 0
	_, completed := server.resolve_entire_file_cancellable(
		src.document,
		cancel_resolution_after_start,
	)
	_, cached := src.document.symbols.?

	testing.expectf(t, !completed, "Expected file resolution to be cancelled")
	testing.expectf(t, !cached, "Cancelled file resolution must not cache partial symbols")
}

expect_inlay_hints :: proc(t: ^testing.T, src: ^Source) {
	spall.trace(#procedure)

	src_builder := strings.builder_make(context.temp_allocator)
	expected_hints := make([dynamic]server.InlayHint, context.temp_allocator)

	HINT_OPEN :: "[["
	HINT_CLOSE :: "]]"

	{
		last, line, col: int
		saw_brackets: bool
		for i := 0; i < len(src.main); i += 1 {
			if saw_brackets {
				if i + 1 < len(src.main) && src.main[i:][:len(HINT_CLOSE)] == HINT_CLOSE {
					saw_brackets = false
					hint_str := src.main[last:i]
					last = i + len(HINT_CLOSE)
					i = last - 1
					// rols: type and value hints expect a different kind
					append(
						&expected_hints,
						server.InlayHint {
							position = {line, col},
							label = hint_str,
							kind = .Type if strings.has_prefix(hint_str, ": ") || strings.has_prefix(hint_str, " = ") else .Parameter,
						},
					)
				}
			} else {
				if i + 1 < len(src.main) && src.main[i:][:len(HINT_OPEN)] == HINT_OPEN {
					strings.write_string(&src_builder, src.main[last:i])
					saw_brackets = true
					last = i + len(HINT_OPEN)
					i = last - 1
				} else if src.main[i] == '\n' {
					line += 1
					col = 0
				} else {
					col += 1
				}
			}
		}

		if saw_brackets {
			log.error("Unclosed inlay hint marker")
			return
		}

		strings.write_string(&src_builder, src.main[last:len(src.main)])
	}

	src.main = strings.to_string(src_builder)

	setup(src)
	defer teardown(src)

	symbols_and_nodes := server.resolve_entire_file(src.document)

	range := common.Range {
		end = {line = 9000000},
	} //should be enough
	hints, hints_ok := server.get_inlay_hints(src.document, range, symbols_and_nodes, &src.config)
	if !hints_ok {
		log.error("Failed get_inlay_hints")
		return
	}

	testing.expectf(
		t,
		len(expected_hints) == len(hints),
		"Expected %d inlay hints, but received %d",
		len(expected_hints),
		len(hints),
	)

	lines := strings.split_lines(src.main, context.temp_allocator)

	get_source_line_with_hint :: proc(lines: []string, hint: server.InlayHint) -> string {
		line := lines[hint.position.line] if hint.position.line >= 0 && hint.position.line < len(lines) else ""
		if hint.position.character >= 0 && hint.position.character <= len(line) {
			builder := strings.builder_make(context.temp_allocator)
			strings.write_string(&builder, line[:hint.position.character])
			strings.write_string(&builder, HINT_OPEN)
			strings.write_string(&builder, hint.label)
			strings.write_string(&builder, HINT_CLOSE)
			strings.write_string(&builder, line[hint.position.character:])
			return strings.to_string(builder)
		}
		return ""
	}

	for i in 0 ..< max(len(expected_hints), len(hints)) {
		expected_text := "---"
		actual_text := "---"

		if i < len(expected_hints) {
			expected := expected_hints[i]
			expected_line := get_source_line_with_hint(lines, expected)
			expected_text = fmt.tprintf(
				"\"%s\" at (%d, %d): \"%s\"",
				expected.label,
				expected.position.line,
				expected.position.character,
				expected_line,
			)
		}

		if i < len(hints) {
			actual := hints[i]
			actual_line := get_source_line_with_hint(lines, actual)
			actual_text = fmt.tprintf(
				"\"%s\" at (%d, %d): \"%s\"",
				actual.label,
				actual.position.line,
				actual.position.character,
				actual_line,
			)
		}

		if i >= len(expected_hints) {
			log.errorf("[%d]: Unexpected inlay hint\nExpected: %s\nActual:   %s", i, expected_text, actual_text)
		} else if i >= len(hints) {
			log.errorf("[%d]: Missing inlay hint\nExpected: %s\nActual:   %s", i, expected_text, actual_text)
		} else if expected_hints[i] != hints[i] {
			log.errorf("[%d]: Inlay hint mismatch\nExpected: %s\nActual:   %s", i, expected_text, actual_text)
		}
	}
}

// rols: assertions for the fork features
LintExpect :: struct {
	line: int, // zero based
	code: string,
}

// `messages`, when given, are the exact messages of the diagnostics in order.
expect_lint_diagnostics :: proc(t: ^testing.T, src: ^Source, expected: []LintExpect, messages: []string = nil) {
	spall.trace(#procedure)

	setup(src)
	defer teardown(src)

	// rols: the other files of the package stand in for the disk
	diagnostics := server.lint_document(src.document, &src.config, package_files(src))

	testing.expectf(
		t,
		len(expected) == len(diagnostics),
		"\nExpected %d lint diagnostics, but received %d:\n%v",
		len(expected),
		len(diagnostics),
		diagnostics,
	)

	for i in 0 ..< min(len(expected), len(diagnostics)) {
		got := LintExpect{diagnostics[i].range.start.line, diagnostics[i].code}
		testing.expectf(t, expected[i] == got, "\n[%d]: Expected %v but received %v", i, expected[i], got)
		if i < len(messages) {
			testing.expectf(
				t,
				messages[i] == diagnostics[i].message,
				"\n[%d]: Expected message %q but received %q",
				i,
				messages[i],
				diagnostics[i].message,
			)
		}
	}
}

// Every lint diagnostic of the source carries exactly these tags.
expect_lint_tags :: proc(t: ^testing.T, src: ^Source, tags: []server.DiagnosticTag) {
	spall.trace(#procedure)

	setup(src)
	defer teardown(src)

	diagnostics := server.lint_document(src.document, &src.config)
	testing.expect(t, len(diagnostics) > 0, "Expected lint diagnostics")
	overwrite_stack()
	for d in diagnostics {
		testing.expectf(t, slice.equal(d.tags, tags), "\nExpected tags %v but received %v", tags, d.tags)
	}
}

// rols: tags that point into a returned lint proc's stack read back as garbage after this
@(private = "file")
overwrite_stack :: #force_no_inline proc() {
	buf: [64 * 1024]u8
	for &b in buf {
		intrinsics.volatile_store(&b, 0xAA)
	}
}

Unused_Expect :: struct {
	file: string,
	line: int, // zero based
}

expect_unused_declarations :: proc(t: ^testing.T, src: ^Source, expected: []Unused_Expect) {
	spall.trace(#procedure)

	diagnostics := unused_declaration_diagnostics(t, src)

	got := make([dynamic]Unused_Expect, context.temp_allocator)
	for uri, diags in diagnostics {
		for d in diags {
			testing.expectf(t, d.code == "unused-declaration", "unexpected code %v", d.code)
			append(&got, Unused_Expect{uri[strings.last_index(uri, "/") + 1:], d.range.start.line})
		}
	}
	less :: proc(a, b: Unused_Expect) -> bool {
		return a.file < b.file || (a.file == b.file && a.line < b.line)
	}
	slice.sort_by(got[:], less)
	expected := slice.clone(expected, context.temp_allocator)
	slice.sort_by(expected, less)

	testing.expectf(t, slice.equal(expected, got[:]), "\nExpected %v but received %v", expected, got[:])
}

// rols: unused-declaration messages, sorted
expect_unused_declaration_messages :: proc(t: ^testing.T, src: ^Source, expected: []string) {
	spall.trace(#procedure)

	diagnostics := unused_declaration_diagnostics(t, src)

	got := make([dynamic]string, context.temp_allocator)
	for _, diags in diagnostics {
		for d in diags do append(&got, d.message)
	}
	slice.sort(got[:])
	expected := slice.clone(expected, context.temp_allocator)
	slice.sort(expected)

	testing.expectf(t, slice.equal(expected, got[:]), "\nExpected %v but received %v", expected, got[:])
}

// The unused-declaration diagnostics of the test package, in temp memory that outlives the teardown.
@(private)
unused_declaration_diagnostics :: proc(t: ^testing.T, src: ^Source) -> map[string][dynamic]server.Diagnostic {
	setup(src)
	defer teardown(src)

	// The saved document is in the index on save; setup only parses it.
	server.collect_symbols(&server.indexer.index.collection, src.document.ast, src.document.uri.uri)

	diagnostics, ok := server.unused_declarations("test", package_files(src), &src.config)
	testing.expect(t, ok, "unused_declarations failed")
	return diagnostics
}

@(private)
package_files :: proc(src: ^Source) -> []server.Package_File {
	files := make([]server.Package_File, len(src.files), context.temp_allocator)
	for f, i in src.files {
		files[i] = {strings.join({"test", f.name}, "/", context.temp_allocator), f.source}
	}
	return files
}

// Applies the named action to the files of src and compares each file listed in expected by name.
expect_action_applied_files :: proc(t: ^testing.T, src: ^Source, action_name: string, expected: []File) {
	input_range := source_remove_selection(src)

	setup(src)
	defer teardown(src)

	// Other files resolve names from the open document through the index.
	server.collect_symbols(&server.indexer.index.collection, src.document.ast, src.document.uri.uri)

	actions, ok := server.get_code_actions(src.document, {}, input_range, &src.config, package_files(src))
	if !ok {
		log.error("Failed to find actions")
		return
	}
	for action in actions {
		if action.title == action_name {
			expect_workspace_edit(t, src, action.edit, expected)
			return
		}
	}
	log.errorf("Action '%s' not found in actions: %v", action_name, actions)
}

// Reorders the parameters of the procedure at the cursor. Empty expected means the reorder is refused.
expect_reorder_params :: proc(t: ^testing.T, src: ^Source, order: []int, expected: []File) {
	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	server.collect_symbols(&server.indexer.index.collection, src.document.ast, src.document.uri.uri)

	edit, _, ok := server.reorder_params(src.document, cursor, order, package_files(src))
	if len(expected) == 0 {
		testing.expectf(t, !ok, "Expected the reorder to be refused but received %v", edit)
		return
	}
	if !testing.expectf(t, ok, "Expected a reorder but it was refused") do return
	expect_workspace_edit(t, src, edit, expected)
}

// Moves the declaration at the cursor to target, a file name of the test package. Empty expected
// means the move is refused.
expect_move_declaration :: proc(t: ^testing.T, src: ^Source, target: string, expected: []File, cause := "") {
	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	server.collect_symbols(&server.indexer.index.collection, src.document.ast, src.document.uri.uri)

	edit, reason, ok := server.move_declaration(src.document, cursor, test_uri(target), package_files(src))
	if len(expected) == 0 {
		if !testing.expectf(t, !ok, "Expected the move to be refused but received %v", edit) do return
		// rols: an empty cause always matches
		testing.expectf(t, strings.contains(reason, cause), "Expected the reason to contain %q but received %q", cause, reason)
		return
	}
	if !testing.expectf(t, ok, "Expected a move but it was refused") do return
	expect_workspace_edit(t, src, edit, expected)
}

// Renames the symbol at the cursor across the files and packages of src once check_rename passes, and
// compares each file listed in expected by name; a package file is named `pkg/package.odin`.
expect_rename :: proc(t: ^testing.T, src: ^Source, new_name: string, expected: []File) {
	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	server.collect_symbols(&server.indexer.index.collection, src.document.ast, src.document.uri.uri)

	files := source_files(src)
	reasons, _ := server.check_rename(src.document, cursor, new_name, &src.config, files)
	if !testing.expectf(t, len(reasons) == 0, "Expected the rename to pass its check, but received %v", reasons) do return
	edit, ok := server.get_rename(src.document, new_name, cursor, files)
	if !testing.expect(t, ok, "Expected a rename") do return
	expect_workspace_edit(t, src, edit, expected)
}

// Renaming the symbol at the cursor is refused with one reason per cause, each containing its cause.
expect_rename_refused :: proc(t: ^testing.T, src: ^Source, new_name: string, causes: []string) {
	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	server.collect_symbols(&server.indexer.index.collection, src.document.ast, src.document.uri.uri)

	reasons, _ := server.check_rename(src.document, cursor, new_name, &src.config, source_files(src))
	expect_causes(t, reasons, causes)
}

// One reason per cause, each containing its cause.
@(private)
expect_causes :: proc(t: ^testing.T, reasons, causes: []string) {
	testing.expectf(t, len(reasons) == len(causes), "\nExpected %d reasons, but received %v", len(causes), reasons)
	expect_contained(t, reasons, causes)
}

// Each of wanted is contained in one entry of got.
@(private)
expect_contained :: proc(t: ^testing.T, got, wanted: []string) {
	for w in wanted {
		found := false
		for entry in got {
			found ||= strings.contains(entry, w)
		}
		testing.expectf(t, found, "\nExpected an entry containing %q in %v", w, got)
	}
}

// Renames the package in test/dir to new_name across the files and packages of src, and compares each
// file listed in expected by its name after the rename; a package file is named `pkg/package.odin`. Each
// of warnings must be contained in one warning.
expect_rename_package :: proc(
	t: ^testing.T,
	src: ^Source,
	dir, new_name: string,
	expected: []File,
	warnings: []string = {},
) {
	setup(src)
	defer teardown(src)

	server.collect_symbols(&server.indexer.index.collection, src.document.ast, src.document.uri.uri)

	full_dir := strings.join({"test", dir}, "/", context.temp_allocator)
	edit, got, reasons, ok := server.rename_package(full_dir, new_name, &src.config, source_files(src))
	if !testing.expectf(t, ok, "Expected the package rename to pass its check, but received %v", reasons) do return
	// The expected files carry their new paths, so they are found only when the directory rename applies.
	expect_workspace_edit(t, src, edit, expected)
	expect_contained(t, got, warnings)
}

// Renaming the package in test/dir to new_name is refused with one reason per cause, each containing its cause.
expect_rename_package_refused :: proc(t: ^testing.T, src: ^Source, dir, new_name: string, causes: []string) {
	setup(src)
	defer teardown(src)

	server.collect_symbols(&server.indexer.index.collection, src.document.ast, src.document.uri.uri)

	full_dir := strings.join({"test", dir}, "/", context.temp_allocator)
	_, _, reasons, ok := server.rename_package(full_dir, new_name, &src.config, source_files(src))
	testing.expect(t, !ok, "Expected the package rename to be refused")
	expect_causes(t, reasons, causes)
}

// Renames the package of the first file to new_name from the cursor on its `package` clause, as the rename
// request does. An empty expected means the rename is refused with one reason per cause; otherwise each
// file listed in expected is compared by its name after the rename.
expect_rename_package_clause :: proc(
	t: ^testing.T,
	src: ^Source,
	new_name: string,
	expected: []File,
	causes: []string = {},
) {
	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	server.collect_symbols(&server.indexer.index.collection, src.document.ast, src.document.uri.uri)

	edit, reasons, found := server.rename_package_clause(src.document, cursor, new_name, &src.config, source_files(src))
	if !testing.expect(t, found, "Expected the cursor on the package clause") do return
	if len(expected) == 0 {
		expect_causes(t, reasons, causes)
		return
	}
	if !testing.expectf(t, len(reasons) == 0, "Expected the package rename to pass its check, but received %v", reasons) do return
	expect_workspace_edit(t, src, edit, expected)
}

Attr_Command :: enum {
	Add, // args: KEY[=VALUE], at the cursor
	Remove, // args: KEY, at the cursor
	Remove_All, // args: KEY, DIR
	Rename, // args: OLD, NEW, DIR
}

// Runs the attr command over the files and packages of src and compares each file listed in expected by
// name; empty expected means a no-op. DIR is relative to test, "" for the whole workspace. Each of
// warnings must be contained in one warning.
expect_attr_edit :: proc(
	t: ^testing.T,
	src: ^Source,
	command: Attr_Command,
	args: []string,
	expected: []File,
	warnings: []string = {},
) {
	edit, got, reasons, ok := run_attr_command(src, command, args)
	defer teardown(src)
	if !testing.expectf(t, ok, "Expected the attr edit to pass its check, but received %v", reasons) do return
	if len(expected) == 0 {
		testing.expectf(t, len(edit.changes) == 0, "Expected a no-op, but received %v", edit.changes)
	} else {
		testing.expectf(t, len(edit.changes) > 0, "Expected an edit, but received a no-op")
		expect_workspace_edit(t, src, edit, expected)
	}
	expect_contained(t, got, warnings)
}

// The attr command is refused with one reason per cause, each containing its cause.
expect_attr_refused :: proc(t: ^testing.T, src: ^Source, command: Attr_Command, args: []string, causes: []string) {
	_, _, reasons, ok := run_attr_command(src, command, args)
	defer teardown(src)
	testing.expect(t, !ok, "Expected the attr edit to be refused")
	expect_causes(t, reasons, causes)
}

// Sets src up and runs the command; the caller tears it down.
@(private)
run_attr_command :: proc(
	src: ^Source,
	command: Attr_Command,
	args: []string,
) -> (
	server.WorkspaceEdit,
	[]string,
	[]string,
	bool,
) {
	cursor: common.Position
	if command == .Add || command == .Remove {
		cursor = source_remove_cursor(src)
	}
	setup(src)
	dir :: proc(name: string) -> string {
		return "" if name == "" else strings.join({"test", name}, "/", context.temp_allocator)
	}
	switch command {
	case .Add:
		return server.attr_add(src.document, cursor, args[0], &src.config)
	case .Remove:
		return server.attr_remove(src.document, cursor, args[0], &src.config)
	case .Remove_All:
		return server.attr_sweep(dir(args[1]), args[0], "", &src.config, source_files(src))
	case .Rename:
		return server.attr_sweep(dir(args[2]), args[0], args[1], &src.config, source_files(src))
	}
	return {}, {}, {}, false
}

// The files of the test package and of every package of src, as the workspace walk would find them.
@(private)
source_files :: proc(src: ^Source) -> []server.Package_File {
	files := make([dynamic]server.Package_File, context.temp_allocator)
	append(&files, ..package_files(src))
	for pkg in src.packages {
		if len(pkg.files) == 0 {
			append(&files, server.Package_File{package_file_path(pkg.pkg, "package.odin"), pkg.source})
		}
		for f in pkg.files {
			append(&files, server.Package_File{package_file_path(pkg.pkg, f.name), f.source})
		}
	}
	return files[:]

	package_file_path :: proc(pkg, name: string) -> string {
		return strings.join({"test", pkg, name}, "/", context.temp_allocator)
	}
}

@(private)
test_uri :: proc(name: string) -> string {
	return common.create_uri(strings.join({"test", name}, "/", context.temp_allocator), context.temp_allocator).uri
}

// Applies edit to the files of src, creating the files it creates, and compares each file listed
// in expected by name.
@(private)
expect_workspace_edit :: proc(t: ^testing.T, src: ^Source, edit: server.WorkspaceEdit, expected: []File) {
	texts := make(map[string]string, context.temp_allocator)
	for f in source_files(src) {
		texts[common.create_uri(f.fullpath, context.temp_allocator).uri] = f.text
	}
	if changes, has := edit.documentChanges.?; has {
		for change in changes {
			switch c in change {
			case server.CreateFile:
				if c.uri not_in texts {
					texts[c.uri] = ""
				}
			case server.TextDocumentEdit:
				text, applied := common.apply_text_edits(c.edits, texts[c.textDocument.uri])
				testing.expectf(t, applied, "Invalid or overlapping edit range in %v", c.edits)
				texts[c.textDocument.uri] = text
			case server.RenameFile:
				// Every file at or below the old path moves to the new one.
				uris, _ := slice.map_keys(texts, context.temp_allocator)
				for uri in uris {
					if server.at_or_below(uri, c.oldUri) {
						moved := strings.concatenate({c.newUri, uri[len(c.oldUri):]}, context.temp_allocator)
						texts[moved] = texts[uri]
						delete_key(&texts, uri)
					}
				}
			}
		}
	}
	for uri, edits in edit.changes {
		text, applied := common.apply_text_edits(edits, texts[uri])
		testing.expectf(t, applied, "Invalid or overlapping edit range in %v", edits)
		texts[uri] = text
	}
	for want in expected {
		text, found := texts[test_uri(want.name)]
		testing.expectf(t, found && text == want.source, "\n%s expected:\n%s\n\nGot:\n%s", want.name, want.source, text)
	}
}

// Name of the call hierarchy item prepared at the cursor, "" when there is none.
expect_call_hierarchy_item :: proc(t: ^testing.T, src: ^Source, expected: string) {
	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	items := server.prepare_call_hierarchy(src.document, cursor, package_files(src))
	name := items[0].name if len(items) == 1 else ""
	testing.expectf(t, name == expected, "\nExpected item %q but received %v", expected, items)
}

Call_Expect :: struct {
	name:  string,
	sites: int,
}

expect_incoming_calls :: proc(t: ^testing.T, src: ^Source, expected: []Call_Expect) {
	expect_calls(t, src, true, expected)
}

expect_outgoing_calls :: proc(t: ^testing.T, src: ^Source, expected: []Call_Expect) {
	expect_calls(t, src, false, expected)
}

@(private)
expect_calls :: proc(t: ^testing.T, src: ^Source, incoming: bool, expected: []Call_Expect) {
	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	// Other files resolve names from the open document through the index.
	server.collect_symbols(&server.indexer.index.collection, src.document.ast, src.document.uri.uri)

	files := package_files(src)
	items := server.prepare_call_hierarchy(src.document, cursor, files)
	if !testing.expectf(t, len(items) == 1, "\nExpected one item but received %v", items) do return

	got := make([dynamic]Call_Expect, context.temp_allocator)
	if incoming {
		for call in server.incoming_calls(items[0], files) do append(&got, Call_Expect{call.from.name, len(call.fromRanges)})
	} else {
		for call in server.outgoing_calls(items[0], files) do append(&got, Call_Expect{call.to.name, len(call.fromRanges)})
	}
	less :: proc(a, b: Call_Expect) -> bool {
		return a.name < b.name
	}
	slice.sort_by(got[:], less)
	expected := slice.clone(expected, context.temp_allocator)
	slice.sort_by(expected, less)

	testing.expectf(t, slice.equal(expected, got[:]), "\nExpected %v but received %v", expected, got[:])
}

// Lens titles on the first file, in declaration order.
expect_code_lenses :: proc(t: ^testing.T, src: ^Source, expected: []string) {
	setup(src)
	defer teardown(src)

	// Other files resolve names from the open document through the index.
	server.collect_symbols(&server.indexer.index.collection, src.document.ast, src.document.uri.uri)

	got := make([dynamic]string, context.temp_allocator)
	for lens in server.get_code_lenses(src.document, &src.config, package_files(src)) {
		append(&got, lens.command.title)
	}
	testing.expectf(t, slice.equal(expected, got[:]), "\nExpected %v but received %v", expected, got[:])
}

expect_implementation_locations :: proc(t: ^testing.T, src: ^Source, expected: []common.Location) {
	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	// Other files resolve names from the open document through the index.
	server.collect_symbols(&server.indexer.index.collection, src.document.ast, src.document.uri.uri)

	locations := server.get_implementation_locations(src.document, cursor, package_files(src))
	for &location in locations do location.uri = ""

	_, _, all_good := compare_expected_slice_set(
		locations,
		expected,
		equals = proc(a, e: common.Location) -> bool {
			return a.range == e.range
		},
		allocator = context.temp_allocator,
	)
	testing.expectf(t, all_good, "\nExpected %v but received %v", expected, locations)
}

// Text of every selection range around the cursor, innermost first.
expect_selection_ranges :: proc(t: ^testing.T, src: ^Source, expected: []string) {
	spall.trace(#procedure)

	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	text := src.document.text[:src.document.used_text]
	chains := server.get_selection_ranges(src.document, {cursor}, &src.config)

	got := make([dynamic]string, context.temp_allocator)
	for range in chains[0] {
		start, _ := common.get_absolute_position(range.start, text)
		end, _ := common.get_absolute_position(range.end, text)
		append(&got, string(text[start:end]))
	}

	testing.expectf(t, slice.equal(expected, got[:]), "\nExpected %v but received %v", expected, got[:])
}

// The whole document after the range-formatting edits over the `{[ … ]}` selection are applied.
expect_range_format :: proc(t: ^testing.T, src: ^Source, expected: string) {
	spall.trace(#procedure)

	range := source_remove_selection(src)

	setup(src)
	defer teardown(src)

	edits := server.get_range_format(src.document, range, &src.config)
	text, applied := common.apply_text_edits(edits, string(src.document.text[:src.document.used_text]))
	testing.expectf(t, applied, "Invalid or overlapping edit range in %v", edits)

	testing.expectf(t, text == expected, "\nExpected:\n%s\n\nGot:\n%s", expected, text)
}

Highlight_Expect :: struct {
	line: int, // 0-based
	text: string,
	kind: server.DocumentHighlightKind,
}

// Document highlights around the cursor, ordered by position.
expect_document_highlights :: proc(t: ^testing.T, src: ^Source, expected: []Highlight_Expect) {
	spall.trace(#procedure)

	cursor := source_remove_cursor(src)

	setup(src)
	defer teardown(src)

	text := src.document.text[:src.document.used_text]
	got := make([dynamic]Highlight_Expect, context.temp_allocator)
	for highlight in server.get_document_highlights(src.document, cursor, &src.config) {
		start, _ := common.get_absolute_position(highlight.range.start, text)
		end, _ := common.get_absolute_position(highlight.range.end, text)
		append(&got, Highlight_Expect{highlight.range.start.line, string(text[start:end]), highlight.kind})
	}

	testing.expectf(t, slice.equal(expected, got[:]), "\nExpected %v but received %v", expected, got[:])
}

expect_folding_ranges :: proc(t: ^testing.T, src: ^Source, expected: []server.FoldingRange) {
	spall.trace(#procedure)

	setup(src)
	defer teardown(src)

	ranges := server.get_folding_ranges(src.document)
	expected := slice.clone(expected, context.temp_allocator)
	slice.sort_by(expected, server.folding_range_less)

	testing.expectf(
		t,
		len(expected) == len(ranges),
		"\nExpected %d folding ranges, but received %d:\n%v",
		len(expected),
		len(ranges),
		ranges,
	)

	for i in 0 ..< min(len(expected), len(ranges)) {
		testing.expectf(t, expected[i] == ranges[i], "\n[%d]: Expected %v but received %v", i, expected[i], ranges[i])
	}
}
