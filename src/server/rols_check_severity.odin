package server

import "core:odin/ast"
import "core:odin/parser"
import "core:os"
import "core:slice"
import "core:strings"

// The byte offsets of the names that odin reports as a hard error when unused, by file path. Filled on
// first use in one check, in temp memory.
Hard_Unused_Cache :: map[string]Hard_Unused

Hard_Unused :: struct {
	offsets: []int,
	parsed:  bool,
}

// The severity of a checker error. A `declared but not used` message is a hard error for the only
// declaration of an `if`, `else`, `for` body, and a -vet-unused-variables finding anywhere else, so the
// source decides. A file that cannot be read or parsed keeps the error.
check_error_severity :: proc(error: Json_Error, message: string, cache: ^Hard_Unused_Cache) -> DiagnosticSeverity {
	// A style Syntax Error of the first run that the rerun without the style flags did not report.
	if error.type == STYLE_ERROR_TYPE {
		return .Warning
	}
	severity := map_diagnostic_severity(error.type, message)
	if severity != .Error || !strings.has_suffix(message, UNUSED_SUFFIX) {
		return severity
	}
	hard, found := cache[error.pos.file]
	if !found {
		if data, err := os.read_entire_file(error.pos.file, context.temp_allocator); err == nil {
			hard.offsets, hard.parsed = hard_unused_offsets(string(data))
		}
		cache[error.pos.file] = hard
	}
	return .Error if !hard.parsed || slice.contains(hard.offsets, error.pos.offset) else .Warning
}

@(private = "file")
UNUSED_SUFFIX :: " declared but not used"

// The offsets of the names that odin 'declared but not used' reports as an error without any vet flag: the
// names of a declaration that is the only statement of the body of an `if`, `else`, `for` or `for … in`.
// Verified with odin: a bare block, a `when` or `switch` case body, a procedure body and a body with
// two statements only report with -vet-unused-variables. parsed is false when src does not parse.
hard_unused_offsets :: proc(src: string) -> (offsets: []int, parsed: bool) {
	context.allocator = context.temp_allocator
	p := parser.Parser {
		flags = {.Optional_Semicolons},
	}
	file := ast.File {
		src = src,
	}
	if !parser.parse_file(&p, &file) {
		return nil, false
	}
	found := make([dynamic]int, context.temp_allocator)
	visitor := ast.Visitor {
		data = &found,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			offsets := (^[dynamic]int)(visitor.data)
			#partial switch n in node.derived {
			case ^ast.If_Stmt:
				add_only_decl_names(offsets, n.body)
				add_only_decl_names(offsets, n.else_stmt)
			case ^ast.For_Stmt:
				add_only_decl_names(offsets, n.body)
			case ^ast.Range_Stmt:
				add_only_decl_names(offsets, n.body)
			case ^ast.Unroll_Range_Stmt:
				add_only_decl_names(offsets, n.body)
			}
			return visitor
		},
	}
	for decl in file.decls {
		ast.walk(&visitor, decl)
	}
	return found[:], true
}

@(private = "file")
add_only_decl_names :: proc(offsets: ^[dynamic]int, body: ^ast.Stmt) {
	if body == nil {
		return
	}
	block, is_block := body.derived.(^ast.Block_Stmt)
	if !is_block || len(block.stmts) != 1 {
		return
	}
	decl, is_decl := block.stmts[0].derived.(^ast.Value_Decl)
	if !is_decl {
		return
	}
	for name in decl.names {
		append(offsets, name.pos.offset)
	}
}
