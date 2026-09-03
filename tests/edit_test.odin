package tests

import "core:odin/ast"
import "core:strings"
import "core:testing"

import "src:common"
import "src:server"
import test "src:testing"

@(private = "file")
document_text :: proc(src: ^test.Source) -> string {
	return string(src.document.text[:src.document.used_text])
}

@(private = "file")
absolute :: proc(src: ^test.Source, range: common.Range) -> common.AbsoluteRange {
	abs, ok := common.get_absolute_range(range, src.document.text[:src.document.used_text])
	assert(ok)
	return abs
}

@(test)
edit_find_stmt_list_at_nested_block :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	a := 1
	if a > 0 {
		b := 2
		{[c := 3
		d := 4]}
		e := 5
	}
}
`,
	}

	test.with_document(t, &source, proc(t: ^testing.T, src: ^test.Source, range: common.Range) {
		abs := absolute(src, range)
		list, ok := server.find_stmt_list_at(src.document.ast.decls[0], abs.start, abs.end)
		testing.expect(t, ok)
		testing.expect_value(t, len(list.stmts), 4)
		testing.expect_value(t, list.first, 1)
		testing.expect_value(t, list.last, 2)
	})
}

@(test)
edit_ident_uses_and_writes :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	x := 0
	x = 1
	p := &x
	x += 1
	using x
	y := x{*}
}
`,
	}

	test.with_document(t, &source, proc(t: ^testing.T, src: ^test.Source, range: common.Range) {
		writes := make([dynamic]bool, context.temp_allocator)
		for use in server.collect_ident_uses(src.document.ast.decls[0]) {
			if use.ident.name == "x" {
				append(&writes, server.is_write(use))
			}
		}
		expected := []bool{false, true, true, true, true, false}
		testing.expect_value(t, len(writes), len(expected))
		for w, i in expected {
			testing.expectf(t, writes[i] == w, "use %d: expected is_write %v", i, w)
		}
	})
}

@(test)
edit_local_decl_offset_shadowing_and_parameter :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc(p: int) {
	x := 1
	{
		x := 2
		y := x{*}
	}
	z := p
}
`,
	}

	test.with_document(t, &source, proc(t: ^testing.T, src: ^test.Source, range: common.Range) {
		ctx := server.ActionContext{document = src.document}
		symbols := server.resolve_entire_file_for_references(src.document, context.temp_allocator, .Identifier, "")
		text := document_text(src)

		use_of :: proc(root: ^ast.Node, text: string, before: string) -> ^ast.Ident {
			offset := strings.index(text, before)
			for use in server.collect_ident_uses(root) {
				if use.ident.pos.offset == offset {
					return use.ident
				}
			}
			return nil
		}

		root := src.document.ast.decls[0]

		x := use_of(root, text, "x\n\t}")
		offset, ok := server.local_decl_offset(&ctx, symbols, x)
		testing.expect(t, ok)
		testing.expect_value(t, offset, strings.index(text, "x := 2"))

		p := use_of(root, text, "p\n}")
		offset, ok = server.local_decl_offset(&ctx, symbols, p)
		testing.expect(t, ok)
		testing.expect_value(t, offset, strings.index(text, "p: int"))

		main := use_of(root, text, "main")
		_, ok = server.local_decl_offset(&ctx, symbols, main)
		testing.expect(t, !ok)
	})
}

@(test)
edit_reindent :: proc(t: ^testing.T) {
	testing.expect_value(t, server.reindent("\ta\n\n\t\tb\nc\n", "\t", "  "), "  a\n\n  \tb\n  c\n")
}

@(test)
edit_trim_range :: proc(t: ^testing.T) {
	start, end := server.trim_range("  \n\tx := 1 \n", 0, 12)
	testing.expect_value(t, start, 4)
	testing.expect_value(t, end, 10)
}

@(test)
edit_range_of_non_ascii :: proc(t: ^testing.T) {
	source := test.Source {
		main = `package test

main :: proc() {
	s := "é"; {[x := 1]}
}
`,
	}

	test.with_document(t, &source, proc(t: ^testing.T, src: ^test.Source, range: common.Range) {
		ctx := server.ActionContext{document = src.document}
		start := strings.index(document_text(src), "x := 1")
		expected := common.Range{{3, 11}, {3, 17}}
		testing.expect_value(t, server.range_of(&ctx, start, start + len("x := 1")), expected)
		testing.expect_value(t, range, expected)
	})
}
