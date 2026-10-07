package odin_printer

import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"

// The pairing of an `else` block with the then-block before it.
// `id` names the then-block's group, and `target` is the `else` block that breaks with it.
Else_Chain :: struct {
	id:     string,
	target: ^ast.Stmt,
}

// The group id of a one-line block of `;` joined statements, which opens a normal block when it does not fit.
// It is "" for a block that keeps its layout: a `do` body, a multi-line block, a switch body,
// or one statement outside a paired `if` and `else` chain.
@(private)
chain_block_id :: proc(p: ^Printer, stmt: ^ast.Stmt, block_type: Block_Type) -> string {
	v, ok := one_line_block(p, stmt)
	if !ok || block_type == .Switch_Stmt {
		return ""
	}
	if len(v.stmts) == 1 && stmt != p.chain_then && stmt != p.else_chain.target {
		return ""
	}
	return fmt.aprintf("chain@%d", v.pos.offset, allocator = p.allocator)
}

// A one-line brace block that holds at least one statement.
@(private)
one_line_block :: proc(p: ^Printer, stmt: ^ast.Stmt) -> (^ast.Block_Stmt, bool) {
	if stmt == nil {
		return nil, false
	}
	v, ok := stmt.derived.(^ast.Block_Stmt)
	if !ok || (v.uses_do && !p.config.convert_do) || v.open.line != v.end.line || len(v.stmts) == 0 {
		return nil, false
	}
	return v, true
}

// The block that an `else` opens: the `else` block itself, or the body of an `else if` or `else when`.
@(private)
else_block :: proc(else_stmt: ^ast.Stmt) -> ^ast.Stmt {
	#partial switch v in else_stmt.derived {
	case ^ast.Block_Stmt:
		return v
	case ^ast.If_Stmt:
		return v.body
	case ^ast.When_Stmt:
		return v.body
	}
	return nil
}

// Reports whether the then-block `body` breaks together with the `else` block after it.
// Both blocks are one-line brace blocks on the line where `body` ends.
// A pair of one-statement blocks keeps upstream's layout and pairs only inside a longer chain:
// when `chained` reports that `body` already breaks with the block before it,
// or when a later `else` block of the chain pairs.
@(private)
pairs_with_else :: proc(p: ^Printer, body: ^ast.Stmt, else_stmt: ^ast.Stmt, chained := false) -> bool {
	if else_stmt == nil || p.config.brace_style == .Allman || p.config.brace_style == .Stroustrup {
		return false
	}
	target := else_block(else_stmt)
	then_block, then_ok := one_line_block(p, body)
	next_block, next_ok := one_line_block(p, target)
	if !then_ok || !next_ok || else_stmt.pos.line != body.end.line || target.pos.line != body.end.line {
		return false
	}
	if chained || len(then_block.stmts) > 1 || len(next_block.stmts) > 1 {
		return true
	}
	#partial switch v in else_stmt.derived {
	case ^ast.If_Stmt:
		return pairs_with_else(p, v.body, v.else_stmt)
	case ^ast.When_Stmt:
		return pairs_with_else(p, v.body, v.else_stmt)
	}
	return false
}

// Pairs the `else` block with the then-block `body` when `paired` is set, and returns the pairing it replaces.
// The Block_Stmt visit of the `else` block reads and clears `else_chain`, so both blocks break together.
// The caller restores the returned pairing after the `else` visit,
// so an `if` inside an `else if` header does not clear the pairing of the block after that header.
@(private)
pair_else_chain :: proc(p: ^Printer, paired: bool, body: ^ast.Stmt, else_stmt: ^ast.Stmt) -> Else_Chain {
	saved := p.else_chain
	p.else_chain = {}
	if paired {
		p.else_chain = {
			id     = fmt.aprintf("chain@%d", body.pos.offset, allocator = p.allocator),
			target = else_block(else_stmt),
		}
	}
	return saved
}

// The mode in which a fit check measures an `If_Break_Or` of group `group_id` inside a group of mode `mode`.
// A paired `else` block follows the then-block group named `chain@<offset>`, which lays out before the `else` header.
// Once format decides that group's mode, a fit check inside the header measures the paired block in that mode.
@(private)
chain_fit_mode :: proc(
	modes: ^map[string]Document_Group_Mode,
	group_id: string,
	mode: Document_Group_Mode,
) -> Document_Group_Mode {
	if modes != nil && strings.has_prefix(group_id, "chain@") {
		if decided, ok := modes[group_id]; ok {
			return decided
		}
	}
	return mode
}

// Where a statement's text starts: its first attribute for an attributed declaration.
@(private)
stmt_start :: proc(stmt: ^ast.Stmt) -> tokenizer.Pos {
	if d, ok := stmt.derived.(^ast.Value_Decl); ok && len(d.attributes) > 0 {
		return d.attributes[0].pos
	}
	return stmt.pos
}
