package tests

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

import "src:common"
import "src:server"
import test "src:testing"

@(private = "file")
reorder_source :: proc(main: string, files: []test.File = {}, enabled := true) -> test.Source {
	return {main = main, files = files, config = {enable_code_action_reorder_fields = enabled}}
}

// No title of the action appears, whatever sizes it would name.
@(private = "file")
expect_no_reorder :: proc(t: ^testing.T, main: string, files: []test.File = {}, enabled := true) {
	source := reorder_source(main, files, enabled)
	test.with_document(t, &source, proc(t: ^testing.T, src: ^test.Source, range: common.Range) {
		server.collect_symbols(&server.indexer.index.collection, src.document.ast, src.document.uri.uri)
		files := make([]server.Package_File, len(src.files), context.temp_allocator)
		for f, i in src.files {
			files[i] = {strings.concatenate({"test/", f.name}, context.temp_allocator), f.source}
		}
		actions, ok := server.get_code_actions(src.document, {}, range, &src.config, files)
		testing.expect(t, ok)
		for action in actions {
			testing.expectf(t, !strings.has_prefix(action.title, "Reorder fields"), "unexpected %s", action.title)
		}
	})
}

// Every field keeps its comments, and a field without a comma gains one.
@(test)
reorder_fields_keeps_comments :: proc(t: ^testing.T) {
	source := reorder_source(
		`package test

Fo{*}o :: struct {
	// the flag
	a: u8, // first
	b: i64,

	c, d: u8 "tag",
	e: string
	// after the fields
}
`,
	)
	test.expect_action_applied(
		t,
		&source,
		"Reorder fields to reduce padding (40 to 32 bytes)",
		`package test

Foo :: struct {
	b: i64,
	e: string,
	// the flag
	a: u8, // first
	c, d: u8 "tag",
	// after the fields
}
`,
	)
}

@(test)
reorder_fields_one_line :: proc(t: ^testing.T) {
	source := reorder_source(`package test

Fo{*}o :: struct {a: u8, b: ^int, c: bool}
`)
	test.expect_action_applied(
		t,
		&source,
		"Reorder fields to reduce padding (24 to 16 bytes)",
		`package test

Foo :: struct {b: ^int, a: u8, c: bool}
`,
	)
}

// The struct is already as small as it gets, or the layout is fixed, depends on arguments, or holds a field of a size
// that is not computed.
@(test)
reorder_fields_refusals :: proc(t: ^testing.T) {
	expect_no_reorder(t, `package test

Fo{*}o :: struct {
	b: i64,
	a: u8,
	c: u8,
}
`)
	shapes := []string {
		"Fo{*}o :: struct #packed {\n\ta: u8,\n\tb: ^int,\n\tc: bool,\n}\n",
		"Fo{*}o :: struct #raw_union {\n\ta: u8,\n\tb: ^int,\n\tc: bool,\n}\n",
		"Fo{*}o :: struct #align(8) {\n\ta: u8,\n\tb: ^int,\n\tc: bool,\n}\n",
		"Fo{*}o :: struct($T: typeid) {\n\ta: u8,\n\tb: ^int,\n\tc: bool,\n}\n",
		"Bar :: struct {\n\tx: int,\n}\n\nFo{*}o :: struct {\n\ta: u8,\n\tusing bar: ^Bar,\n\tc: bool,\n}\n",
		"Bar :: struct {\n\tx: int,\n}\n\nFo{*}o :: struct {\n\ta: u8,\n\tb: #subtype ^Bar,\n\tc: bool,\n}\n",
		"Fo{*}o :: struct {\n\ta: u8,\n\tb: ^int,\n\t_: u8,\n}\n",
		"Fo{*}o :: struct {\n\ta: u8,\n\tb: Maybe(^int),\n\tc: bool,\n}\n",
		"Fo{*}o :: struct {\n\ta: u8, b: ^int,\n\tc: bool,\n}\n",
	}
	for shape in shapes {
		expect_no_reorder(t, strings.concatenate({"package test\n\n", shape}, context.temp_allocator))
	}
	expect_no_reorder(t, "package test\n\nFo{*}o :: struct {\n\ta: u8,\n\tb: ^int,\n\tc: bool,\n}\n", enabled = false)
}

// A literal that lists values by position, a `transmute` and a foreign signature depend on the field order.
@(test)
reorder_fields_layout_uses :: proc(t: ^testing.T) {
	TITLE :: "Reorder fields to reduce padding (24 to 16 bytes)"
	FOO :: "package test\n\nFo{*}o :: struct {\n\ta: u8,\n\tb: ^int,\n\tc: bool,\n}\n"
	uses := []string {
		"package test\n\nmake_foo :: proc() -> Foo {\n\treturn Foo{1, nil, true}\n}\n",
		"package test\n\nfoos :: proc() -> []Foo {\n\treturn []Foo{{1, nil, true}}\n}\n",
		"package test\n\nfoo: Foo = {1, nil, true}\n",
		"package test\n\nmake_foo :: proc() -> Foo {\n\treturn {1, nil, true}\n}\n",
		"package test\n\nset_foo :: proc(f: ^Foo) {\n\tf^ = {1, nil, true}\n}\n",
		"package test\n\ntake :: proc(f: Foo) {}\n\nuse :: proc() {\n\ttake({1, nil, true})\n}\n",
		"package test\n\nBar :: struct {\n\tf: Foo,\n}\n\nbar := Bar{f = {1, nil, true}}\n",
		"package test\n\nbytes :: proc(f: Foo) -> [24]u8 {\n\treturn transmute([24]u8)f\n}\n",
		"package test\n\nforeign import lib \"system:c\"\n\nforeign lib {\n\ttake_foo :: proc(f: ^Foo) ---\n}\n",
	}
	for use in uses {
		expect_no_reorder(t, FOO, {{"b.odin", use}})
	}
	// A named literal keeps its meaning.
	source := reorder_source(FOO, {{"b.odin", "package test\n\nfoo := Foo{a = 1, c = true}\n"}})
	test.expect_action_applied(
		t,
		&source,
		TITLE,
		"package test\n\nFoo :: struct {\n\tb: ^int,\n\ta: u8,\n\tc: bool,\n}\n",
	)
}

// The sizes in the title match what the compiler reports for the struct before and after.
@(test)
reorder_fields_sizes_match_odin :: proc(t: ^testing.T) {
	BEFORE :: `package test

Kind :: enum u16 {
	A,
	B,
}

Inner :: struct {
	x: u8,
	y: f64,
}

Fo{*}o :: struct {
	a:  u8,
	b:  i64,
	c:  bool,
	d:  string,
	e:  [3]u16,
	f:  map[int]int,
	g:  [dynamic]u8,
	h:  []int,
	i:  f32,
	j:  Inner,
	k:  Kind,
	l:  bit_set[Kind; u8],
	m:  i128,
	n:  any,
	o:  proc(),
	p:  [^]u8,
	q:  typeid,
	r:  complex64,
	s:  u16,
}
`
	TITLE :: "Reorder fields to reduce padding (256 to 224 bytes)"
	source := reorder_source(BEFORE)
	after, ok := test.apply_action(t, &source, TITLE)
	if !testing.expect(t, ok) {
		return
	}
	before, _ := strings.replace_all(BEFORE, "{*}", "", context.temp_allocator)
	renamed, _ := strings.replace_all(after, "Foo :: struct", "Foo_After :: struct", context.temp_allocator)
	_, _, body := strings.partition(renamed, "Foo_After :: struct")
	program := fmt.tprintf(
		"%s\nFoo_After :: struct%s\nimport \"core:fmt\"\n\nmain :: proc() {{\n\tfmt.println(size_of(Foo), size_of(Foo_After))\n}}\n",
		before,
		body,
	)

	root, err := os.make_directory_temp("", "ols-reorder-*", context.temp_allocator)
	if !testing.expect(t, err == nil) {
		return
	}
	defer os.remove_all(root)
	path, _ := filepath.join({root, "main.odin"}, context.temp_allocator)
	if !testing.expect(t, os.write_entire_file(path, program) == nil) {
		return
	}
	common.process_spawn_lock()
	state, stdout, stderr, run_err := os.process_exec({command = {"odin", "run", root}}, context.temp_allocator)
	common.process_spawn_unlock()
	if !testing.expectf(t, run_err == nil && state.exit_code == 0, "odin run failed: %v %s", run_err, stderr) {
		return
	}
	testing.expect_value(t, strings.trim_space(string(stdout)), "256 224")
}
