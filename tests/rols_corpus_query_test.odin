package tests

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
	// The server always sets the profile os to the host, darwin here, before it indexes.
	previous := common.config.profile.os
	common.config.profile.os = "darwin"
	defer common.config.profile.os = previous

	testing.expectf(t, !server.skip_file("a_bsd.odin"), "odin builds *_bsd.odin on darwin, but skip_file rejects it")
}

// Corpus: reduced, see docs/corpus-validation.md.
@(test)
document_symbols_list_build_excluded_file :: proc(t: ^testing.T) {
	source := test.Source {
		main = `#+build windows
package test

foo :: proc() {}
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
	a :: proc() {}
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

FLAG :: #config(FLAG, false)
`,
	}
	test.with_document(t, &source, proc(t: ^testing.T, src: ^test.Source, _: common.Range) {
		symbols := server.get_document_symbols(src.document)
		if !testing.expectf(t, len(symbols) == 1, "\nExpected one symbol but received %v", symbols) do return
		testing.expect_value(t, symbols[0].kind, server.SymbolKind.Constant)
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
	test.expect_hover(t, &source, "lib.send_typed :: proc(x: ^$T)")
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
