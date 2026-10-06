package odin_printer

import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"

// The group id of a one-line block of `;` joined statements, which opens a normal block when it does not fit.
// It is "" for a block that keeps its layout: a `do` body, a multi-line block, one statement, or a switch body.
@(private)
chain_block_id :: proc(p: ^Printer, stmt: ^ast.Stmt, block_type: Block_Type) -> string {
	v, ok := stmt.derived.(^ast.Block_Stmt)
	if !ok || (v.uses_do && !p.config.convert_do) || v.open.line != v.end.line {
		return ""
	}
	if len(v.stmts) <= 1 || block_type == .Switch_Stmt {
		return ""
	}
	return fmt.aprintf("chain@%d", v.pos.offset, allocator = p.allocator)
}

// Pairs the `else` block with the then-block when both are one-line chain blocks on one source line.
// The Block_Stmt visit of the `else` block reads and clears `else_chain_id`, so both blocks break together.
@(private)
pair_else_chain :: proc(p: ^Printer, body: ^ast.Stmt, body_type: Block_Type, else_stmt: ^ast.Stmt) {
	paired := else_stmt.pos.line == body.end.line && chain_block_id(p, else_stmt, .Generic) != ""
	p.else_chain_id = paired ? chain_block_id(p, body, body_type) : ""
}

// Where a statement's text starts: its first attribute for an attributed declaration.
@(private)
stmt_start :: proc(stmt: ^ast.Stmt) -> tokenizer.Pos {
	if d, ok := stmt.derived.(^ast.Value_Decl); ok && len(d.attributes) > 0 {
		return d.attributes[0].pos
	}
	return stmt.pos
}
