#+feature dynamic-literals

package tests

import "core:odin/ast"
import "core:odin/parser"
import "core:testing"

import "src:common"
import "src:server"

import test "src:testing"

@(private = "file")
document_symbol_names :: proc(symbols: []server.DocumentSymbol) -> []string {
	names := make([]string, len(symbols), context.temp_allocator)
	for symbol, i in symbols do names[i] = symbol.name
	return names
}

// Corpus: reduced, see docs/corpus-validation.md.
@(test)
skip_file_keeps_bsd_files_on_darwin :: proc(t: ^testing.T) {
	testing.expectf(t, !server.skip_file("a_bsd.odin"), "odin builds *_bsd.odin on every host, but skip_file rejects it")
}

@(test)
skip_file_follows_odin_suffix_rules :: proc(t: ^testing.T) {
	// The process-global config is shared by parallel tests, so this runs on the host it expects.
	when ODIN_OS == .Darwin && ODIN_ARCH == .arm64 {
		for name in ([]string{"a.odin", "a_unix.odin", "a_darwin.odin", "a_arm64.odin", "a_darwin_arm64.odin", "a_arm64_darwin.odin"}) {
			testing.expectf(t, !server.skip_file(name), "%s is built on darwin arm64", name)
		}
		for name in ([]string{"a_linux.odin", "a_amd64.odin", "a_darwin_amd64.odin", "a_linux_arm64.odin", ".a.odin"}) {
			testing.expectf(t, server.skip_file(name), "%s is not built on darwin arm64", name)
		}
	}
}

// Corpus: reduced, see docs/corpus-validation.md.
@(test)
document_symbols_list_build_excluded_file :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+build windows
package test

fo{*}o :: proc() {}
`,
	}
	test.with_document(t, &source, proc(t: ^testing.T, src: ^test.Source, _: common.Range) {
		names := document_symbol_names(server.get_document_symbols(src.document))
		testing.expectf(t, len(names) == 1 && names[0] == "foo", "\nExpected [foo] but received %v", names)
	})
}

// Corpus: reduced, see docs/corpus-validation.md.
@(test)
document_symbols_list_when_false_comparison :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

FLAG :: false
when FLAG == false {
	a{*} :: proc() {}
}
`,
	}
	test.with_document(t, &source, proc(t: ^testing.T, src: ^test.Source, _: common.Range) {
		names := document_symbol_names(server.get_document_symbols(src.document))
		found := false
		for name in names do found ||= name == "a"
		testing.expectf(t, found, "\nExpected `a` among %v", names)
	})
}

// Corpus: reduced, see docs/corpus-validation.md.
@(test)
document_symbols_config_is_constant :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

FL{*}AG :: #config(FLAG, false)
`,
	}
	test.with_document(t, &source, proc(t: ^testing.T, src: ^test.Source, _: common.Range) {
		symbols := server.get_document_symbols(src.document)
		if !testing.expectf(t, len(symbols) == 1, "\nExpected one symbol but received %v", symbols) do return
		testing.expect_value(t, symbols[0].kind, server.SymbolKind.Constant)
	})
}

@(test)
document_symbols_compound_literal_values_have_a_kind :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

P :: struct { x: int }
A := []int{1, 2}
B := [2]int{1, 2}
C :: P{x = 1}
D := P{x = 1}
E := 3
F{*} :: [2]int{1, 2}
`,
	}
	test.with_document(t, &source, proc(t: ^testing.T, src: ^test.Source, _: common.Range) {
		expected := map[string]server.SymbolKind {
			"P" = .Struct,
			"A" = .Variable,
			"B" = .Variable,
			"C" = .Constant,
			"D" = .Variable,
			"E" = .Variable,
			"F" = .Constant,
		}
		defer delete(expected)
		symbols := server.get_document_symbols(src.document)
		testing.expectf(t, len(symbols) == len(expected), "\nExpected %d symbols but received %v", len(expected), symbols)
		for symbol in symbols {
			testing.expectf(t, expected[symbol.name] == symbol.kind, "%s: expected %v, got %v", symbol.name, expected[symbol.name], symbol.kind)
			// Upstream lists the fields a struct literal sets as its children.
			if symbol.name == "C" || symbol.name == "D" {
				ok := len(symbol.children) == 1 && symbol.children[0].name == "x" && symbol.children[0].kind == .Field
				testing.expectf(t, ok, "%s: expected the child field x, got %v", symbol.name, symbol.children)
			}
		}
	})
}

// Corpus: reduced, see docs/corpus-validation.md.
@(test)
definition_follows_true_string_when_branch :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

E_NAME :: "gl"
when E_NAME == "gl" {
	E :: 1
} else {
	E :: 2
}
use :: proc() -> int { return E{*} }
`,
	}
	test.expect_definition_locations(
		t,
		&source,
		{{range = {start = {line = 4, character = 1}, end = {line = 4, character = 2}}}},
	)
}

// Corpus: reduced, see docs/corpus-validation.md.
@(test)
definition_of_field_through_const_alias :: proc(t: ^testing.T) {
	source := test.Source {
		main  = `package test

qq :: V
use4 :: proc() { qq.x{*}() }
`,
		files = {
			{"a.odin", `package test

S :: struct {
	x: proc(),
}
`},
			{"b.odin", `package test

V :: S{x = f}
f :: proc() {}
`},
		},
	}
	test.expect_definition_locations(
		t,
		&source,
		{{uri = "file://test/a.odin", range = {start = {line = 3, character = 1}, end = {line = 3, character = 2}}}},
	)
}

// Corpus: core strings/builder.odin:73, see docs/corpus-validation.md.
@(test)
implementation_of_group_member_is_group :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

a{*} :: proc(x: int) {}
b :: proc(x: f32) {}
g :: proc{a, b}
`,
	}
	test.expect_implementation_locations(
		t,
		&source,
		{{range = {start = {line = 4, character = 0}, end = {line = 4, character = 1}}}},
	)
}

// Corpus: reduced, see docs/corpus-validation.md.
@(test)
hover_promoted_field_offset_is_zero :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Base :: struct { magic: int }
Derived :: struct { using base: Base, extra: int }
use :: proc(d: ^Derived) { d.mag{*}ic = 1 }
`,
		config = {enable_hover_struct_size = true},
	}
	test.expect_hover(t, &source, "Derived.magic: int\n---\noffset: 0, size: 8")
}

// Corpus: reduced, see docs/corpus-validation.md.
@(test)
incoming_calls_skip_build_ignore_file :: proc(t: ^testing.T) {
	source := test.Source {
		main  = `package test

dr{*}aw :: proc(x: int) {}
main :: proc() { draw(1) }
`,
		files = {{"doc.odin", `#+build ignore
package test

draw :: proc(x: int)
`}},
	}
	test.expect_incoming_calls(t, &source, {{"main", 1}})
}

// Corpus: reduced, see docs/corpus-validation.md.
@(test)
hover_poly_call_inside_poly_proc :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

conv :: proc(p: rawptr, $T: typeid) -> T { return (^T)(p)^ }
outer :: proc($A: typeid, p: rawptr) -> A {
	x{*} := conv(p, A)
	return x
}
`,
	}
	test.expect_hover(t, &source, "test.x: A")
}

// Corpus: reduced, see docs/corpus-validation.md.
@(test)
hover_overload_with_poly_constant_param :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Tag :: distinct u16
T1 :: Tag(0x40)
a :: proc($tag: Tag, p: []u8) -> int { return 0 }
b :: proc($tag: Tag, p: ^int) -> int { return 0 }
ab :: proc{a, b}
g :: proc() {
	r1{*} := ab(T1, nil)
	_ = r1
}
`,
	}
	test.expect_hover(t, &source, "test.r1: int")
}

// Corpus: reduced, see docs/corpus-validation.md.
@(test)
hover_overload_picks_matching_member :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

import "lib"
f :: proc() {
	v := 1
	lib.se{*}nd(&v)
}
`,
		packages = {
			{
				pkg = "lib",
				source = `package lib

send_raw :: proc(x: int) {}
send_typed :: proc(x: ^$T) {}
send :: proc{send_raw, send_typed}
`,
			},
		},
	}
	test.expect_hover(t, &source, "lib.send :: proc(x: ^$T)")
}

// Corpus: reduced.
@(test)
references_enum_after_call_argument :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

E :: enum { X, Y{*} }
f :: proc(s: string, e: E) {}
g :: proc(s: string) -> string { return s }
main :: proc() {
	f(g("x"), .Y)
	f("x", .Y)
}
`,
	}
	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 2, character = 15}, end = {line = 2, character = 16}}},
			{range = {start = {line = 6, character = 12}, end = {line = 6, character = 13}}},
			{range = {start = {line = 7, character = 9}, end = {line = 7, character = 10}}},
		},
	)
}

// Corpus: Skald examples/06_flex/main.odin:33, see docs/corpus-validation.md.
@(test)
references_enum_named_argument_after_variadic :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Align :: enum { Start, Center{*} }
row :: proc(children: ..int, align: Align = .Start) -> int { return len(children) }
main :: proc() {
	_ = row(1, 2, align = .Center)
}
`,
	}
	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 2, character = 23}, end = {line = 2, character = 29}}},
			{range = {start = {line = 5, character = 24}, end = {line = 5, character = 30}}},
		},
	)
}

// Corpus: reduced, see docs/corpus-validation.md.
@(test)
references_enum_in_comp_lit_argument :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Kind :: enum { A, B{*} }
Item :: struct { kind: Kind }
take :: proc(it: Item) -> Kind { return it.kind }
main :: proc() {
	_ = take(Item{kind = .B})
}
`,
	}
	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 2, character = 18}, end = {line = 2, character = 19}}},
			{range = {start = {line = 6, character = 23}, end = {line = 6, character = 24}}},
		},
	)
}

// The reported shape: the literal is an argument of a call whose result is assigned.
@(test)
references_enum_in_comp_lit_argument_assigned :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Kind :: enum { A, B{*} }
Item :: struct { kind: Kind }
take :: proc(it: Item) -> Kind { return it.kind }
main :: proc() {
	k: Kind
	k = take(Item{kind = .B})
}
`,
	}
	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 2, character = 18}, end = {line = 2, character = 19}}},
			{range = {start = {line = 7, character = 23}, end = {line = 7, character = 24}}},
		},
	)
}

// The assigned name must not decide the type of a selector inside the literal on the right.
@(test)
references_enum_in_comp_lit_assigned_to_a_variable :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Kind :: enum { A, B{*} }
Item :: struct { kind: Kind }
main :: proc() {
	x: Item
	x = Item{kind = .B}
}
`,
	}
	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 2, character = 18}, end = {line = 2, character = 19}}},
			{range = {start = {line = 6, character = 18}, end = {line = 6, character = 19}}},
		},
	)
}

// Corpus: reduced, see docs/corpus-validation.md.
@(test)
references_imported_global_with_field :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

import "a"
f :: proc() {
	a.cf{*}g.x = 1
}
`,
		packages = {{pkg = "a", source = `package a

Config :: struct { x: int }
cfg: Config
`}},
	}
	// The harness only searches the open file, so the declaration in package a is not listed.
	test.expect_reference_locations(
		t,
		&source,
		{{range = {start = {line = 4, character = 3}, end = {line = 4, character = 6}}}},
	)
}

// Corpus: reduced, see docs/corpus-validation.md.
@(test)
references_field_through_using_param :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+feature using-stmt
package test

W :: struct { i{*}d: u32 }
f :: proc(using w: ^W) -> u32 { return id }
`,
	}
	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 3, character = 14}, end = {line = 3, character = 16}}},
			{range = {start = {line = 4, character = 39}, end = {line = 4, character = 41}}},
		},
	)
}

// Corpus: reduced (findings-A F16), see docs/corpus-validation.md.
@(test)
hover_imported_struct_global :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

import "a"
f :: proc() {
	a.cf{*}g.x = 1
}
`,
		packages = {{pkg = "a", source = `package a

Config :: struct { x: int }
cfg: Config
`}},
	}
	test.expect_hover(t, &source, "a.cfg: a.Config")
}

// Corpus: Skald, see docs/corpus-validation.md. A logged error fails the test.
@(test)
hover_generic_call_with_named_argument_call_value :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Ctx :: struct($M: typeid) { m: M }
g :: proc(a: string) -> int { return len(a) }
button :: proc(ctx: ^Ctx($M), on_click: M, id := 0) -> int { return id }
f :: proc(ctx: ^Ctx(int)) -> int {
	r{*} := button(ctx, 1, id = g("x"))
	return r
}
`,
	}
	test.expect_hover(t, &source, "test.r: int")
}

// Corpus: reduced, see docs/corpus-validation.md. A logged error fails the test.
@(test)
indexing_a_file_with_shebang_line_logs_no_error :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#!/usr/bin/env odin
package test

f{*} :: proc() {}
`,
	}
	test.with_document(t, &source, proc(t: ^testing.T, src: ^test.Source, _: common.Range) {
		server.collect_symbols(&server.indexer.index.collection, src.document.ast, src.document.uri.uri)
	})
}

// Review of the const alias fix: an instantiated generic keeps the call site's type node for a bare `T` field.
@(test)
definition_of_field_of_generic_struct_in_other_file :: proc(t: ^testing.T) {
	source := test.Source {
		main  = `package test

use :: proc(v: Vec(f32)) { _ = v.x{*} }
`,
		files = {{"a.odin", `package test

Vec :: struct($T: typeid) {
	x: T,
}
`}},
	}
	test.expect_definition_locations(
		t,
		&source,
		{{uri = "file://test/a.odin", range = {start = {line = 3, character = 1}, end = {line = 3, character = 2}}}},
	)
}

// Review of the comp literal fix: the literal inside the call is the innermost one, an outer literal is not.
@(test)
references_enum_in_comp_lit_inside_comp_lit_argument :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Kind :: enum { A, B{*} }
Item :: struct { kind: Kind }
Outer :: struct { n: Kind }
take :: proc(it: Item) -> Kind { return it.kind }
main :: proc() {
	_ = Outer{n = take(Item{kind = .B})}
}
`,
	}
	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 2, character = 18}, end = {line = 2, character = 19}}},
			{range = {start = {line = 7, character = 33}, end = {line = 7, character = 34}}},
		},
	)
}

// Review of the poly name fix: a value parameter keeps its type, only a typeid parameter names a type.
@(test)
hover_local_from_poly_value_param_shows_its_type :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

f :: proc($N: int) {
	y{*} := N
	_ = y
}
`,
	}
	test.expect_hover(t, &source, "test.y: int")
}

// Review of the pointer guard: a literal does not match a pointer parameter.
@(test)
hover_overload_literal_skips_pointer_parameter :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

by_ptr :: proc(x: ^int) {}
by_val :: proc(x: int) {}
g :: proc{by_ptr, by_val}
main :: proc() {
	g{*}(1)
}
`,
	}
	test.expect_hover(t, &source, "test.g :: proc(x: int)")
}

// Corpus: tina src/wall_clock_darwin.odin, reduced, see docs/corpus-validation.md.
@(test)
document_symbols_list_when_not_imported_flag :: proc(t: ^testing.T) {
	source := test.Source {
		main        = `package test

import "core:cfg"

when !cfg.FLAG {
	a{*} :: proc() {}
}
`,
		packages    = {{pkg = "cfg", source = "package cfg\n\nFLAG :: #config(FLAG, false)\n"}},
		collections = {"core" = "test"},
	}
	test.with_document(t, &source, proc(t: ^testing.T, src: ^test.Source, _: common.Range) {
		names := document_symbol_names(server.get_document_symbols(src.document))
		found := false
		for name in names do found ||= name == "a"
		testing.expectf(t, found, "\nExpected `a` among %v", names)
	})
}

// Corpus: core/net socket_linux.odin saved on darwin, see docs/corpus-validation.md.
@(test)
index_file_skips_file_for_other_platform :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

h{*} :: proc() {}
`,
	}
	test.with_document(t, &source, proc(t: ^testing.T, src: ^test.Source, _: common.Range) {
		server.collect_symbols(&server.indexer.index.collection, src.document.ast, src.document.uri.uri)
		// `_orca` is excluded on every host the tests run on.
		uri := common.create_uri("test/x_orca.odin", context.temp_allocator)
		server.index_file(uri, "package test\n\nonly_there :: proc() {}\n")

		for _, pkg in server.indexer.index.collection.packages {
			for name, symbol in pkg.symbols {
				testing.expectf(t, symbol.uri != uri.uri, "the excluded file indexed %s", name)
			}
		}
	})
}

@(test)
config_directive_reads_define_before_default :: proc(t: ^testing.T) {
	file := ast.File {
		fullpath = "x.odin",
		src      = "package x\nFLAG :: #config(FLAG, false)\n",
	}
	p := parser.default_parser()
	context.allocator = context.temp_allocator
	if !testing.expect(t, parser.parse_file(&p, &file)) do return
	decl := file.decls[0].derived.(^ast.Value_Decl)
	call := decl.values[0].derived.(^ast.Call_Expr)

	value, ok := server.resolve_config_directive({}, call, {})
	testing.expect(t, ok && value == false, "the default applies without a define")
	defines := map[string]string{"FLAG" = "true"}
	value, ok = server.resolve_config_directive({}, call, defines)
	testing.expect(t, ok && value == true, "the define wins over the default")
}

// An untyped literal as a later argument takes its type from its parameter, so its implicit selector does too.
@(test)
references_enum_in_untyped_comp_lit_later_argument :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Kind :: enum { A, B{*} }
Item :: struct { kind: Kind }
take :: proc(n: int, it: Item) -> Kind { return it.kind }
main :: proc() {
	_ = take(1, {kind = .B})
}
`,
	}
	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 2, character = 18}, end = {line = 2, character = 19}}},
			{range = {start = {line = 6, character = 22}, end = {line = 6, character = 23}}},
		},
	)
}

// A literal nested in the argument's literal resolves its implicit selector against the inner field's type.
@(test)
references_enum_in_nested_comp_lit_argument :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Kind :: enum { A, B{*} }
Inner :: struct { kind: Kind }
Item :: struct { n: int, inner: Inner }
take :: proc(it: Item) -> Kind { return it.inner.kind }
main :: proc() {
	_ = take(Item{n = 1, inner = {kind = .B}})
}
`,
	}
	test.expect_reference_locations(
		t,
		&source,
		{
			{range = {start = {line = 2, character = 18}, end = {line = 2, character = 19}}},
			{range = {start = {line = 7, character = 39}, end = {line = 7, character = 40}}},
		},
	)
}

// Two members tie on score but return different types, so the hover must not claim either result.
@(test)
hover_overload_tie_with_different_results :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

Tag :: distinct u16
T1 :: Tag(0x40)
a :: proc($tag: Tag, p: []u8) -> int { return 0 }
b :: proc($tag: Tag, p: ^int) -> f32 { return 0 }
ab :: proc{a, b}
g :: proc() {
	r1{*} := ab(T1, nil)
	_ = r1
}
`,
	}
	test.expect_no_hover(t, &source)
}

// The group call inside max resolves against its own arguments, not against the arguments of max.
@(test)
hover_max_of_group_call :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

one :: proc(a: int) -> f32 { return 0 }
two :: proc(a: int, b: f32) -> i64 { return 0 }
grp :: proc{one, two}
f :: proc(a: int) {
	x{*} := max(0, grp(a))
	_ = x
}
`,
	}
	test.expect_hover(t, &source, "test.x: f32")
}

// A tie between members whose results agree still resolves when a member's result type is written in its own
// package, where `Result` is not the document's `Result`.
@(test)
hover_overload_tie_in_other_package_with_same_result :: proc(t: ^testing.T) {
	source := test.Source {
		main     = `package test

import "other"

Result :: int
b :: proc(p: ^int) -> other.Result { return {} }
g :: proc{other.a, b}
f :: proc() {
	r{*} := g(nil)
	_ = r
}
`,
		packages = {
			{
				pkg = "other",
				source = `package other

Result :: struct { x: int }
a :: proc(p: []u8) -> Result { return {} }
`,
			},
		},
	}
	test.expect_hover(t, &source, "test.r: other.Result")
}

// The callee of a call that ties between members with different results shows the group.
@(test)
hover_callee_of_tied_call_shows_group :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

a :: proc(p: []u8) -> int { return 0 }
b :: proc(p: ^int) -> f32 { return 0 }
ab :: proc{a, b}
g :: proc() {
	r1 := a{*}b(nil)
	_ = r1
}
`,
	}
	test.expect_hover(t, &source, "test.ab :: proc {\n\ta :: proc(p: []u8) -> int,\n\tb :: proc(p: ^int) -> f32,\n}")
}

// Every call of the chain ties between members with different results, so it fails, and each level passes the
// previous result twice. Resolving a failed call again on every use would take 2^30 resolutions.
@(test)
hover_deep_chain_of_failed_overloads_finishes :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

add_i :: proc(a, b: int) -> int { return a + b }
add_f :: proc(a, b: int) -> f32 { return 0 }
add :: proc{add_i, add_f}
f :: proc() {
	v0: int
	v1 := add(v0, v0)
	v2 := add(v1, v1)
	v3 := add(v2, v2)
	v4 := add(v3, v3)
	v5 := add(v4, v4)
	v6 := add(v5, v5)
	v7 := add(v6, v6)
	v8 := add(v7, v7)
	v9 := add(v8, v8)
	v10 := add(v9, v9)
	v11 := add(v10, v10)
	v12 := add(v11, v11)
	v13 := add(v12, v12)
	v14 := add(v13, v13)
	v15 := add(v14, v14)
	v16 := add(v15, v15)
	v17 := add(v16, v16)
	v18 := add(v17, v17)
	v19 := add(v18, v18)
	v20 := add(v19, v19)
	v21 := add(v20, v20)
	v22 := add(v21, v21)
	v23 := add(v22, v22)
	v24 := add(v23, v23)
	v25 := add(v24, v24)
	v26 := add(v25, v25)
	v27 := add(v26, v26)
	v28 := add(v27, v27)
	v29 := add(v28, v28)
	v30 := add(v29, v29)
	_ = v3{*}0
}
`,
	}
	test.expect_no_hover(t, &source)
}
