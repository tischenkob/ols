#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"

import "src:common"

// rols: takes an ActionContext and offers the early-exit variant
@(private = "package")
add_invert_if_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_invert_if {
		return
	}

	if_stmt := find_if_stmt_at_position(ctx.document.ast.decls[:], ctx.range.start)
	if if_stmt == nil || if_stmt.body == nil {
		return
	}
	body, is_block := if_stmt.body.derived.(^ast.Block_Stmt)
	if !is_block {
		return
	}

	new_text, ok := generate_inverted_if(ctx.document.ast.src, if_stmt, body)
	if !ok {
		return
	}

	edits := make([]TextEdit, 1, context.temp_allocator)
	edits[0] = TextEdit {
		range   = range_of(ctx, if_stmt.pos.offset, if_stmt.end.offset),
		newText = match_line_endings(ctx.document.ast.src, new_text),
	}
	append(ctx.actions, make_code_action(ctx, "Invert if", "refactor.more", edits))

	add_early_exit_action(ctx, if_stmt, body)
}

// rols: rewrite an if into a guard with a bare exit
Exit :: enum {
	Return,
	Continue,
	Break,
}

exit_text := [Exit]string {
	.Return   = "return",
	.Continue = "continue",
	.Break    = "break",
}

// The if must be a direct child of a proc body without results, a loop body or a case body, so
// the added bare exit leaves that construct.
add_early_exit_action :: proc(ctx: ^ActionContext, if_stmt: ^ast.If_Stmt, body: ^ast.Block_Stmt) {
	if if_stmt.else_stmt != nil || if_stmt.init != nil || if_stmt.label != nil || len(body.stmts) == 0 {
		return
	}

	function := ctx.position_context.function
	if function == nil || function.body == nil {
		return
	}

	stmts, exit, close, ok := enclosing_list(function, if_stmt)
	if !ok {
		return
	}
	index := -1
	for stmt, i in stmts {
		if stmt == if_stmt {
			index = i
		}
	}
	if index < 0 {
		return
	}
	following := stmts[index + 1:]
	for stmt in following {
		#partial switch s in stmt.derived {
		case ^ast.Defer_Stmt:
			return
		case ^ast.Branch_Stmt:
			if s.tok.kind == .Fallthrough {
				return
			}
		}
	}

	src := ctx.document.ast.src
	cond, cond_ok := invert_condition(src, if_stmt.cond)
	if !cond_ok {
		return
	}
	ind := get_line_indentation(src, if_stmt.pos.offset)
	unit := indent_unit(src, ind, body.uses_do ? nil : body.stmts[0])
	deeper := strings.concatenate({ind, unit}, context.temp_allocator)

	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "if ")
	strings.write_string(&sb, cond)
	strings.write_string(&sb, " {\n")

	replace_end := if_stmt.end.offset
	body_text: string

	if len(following) == 0 {
		strings.write_string(&sb, deeper)
		strings.write_string(&sb, exit_text[exit])
		strings.write_byte(&sb, '\n')
		body_text = block_lines(src, body, ind, unit)
	} else {
		last := body.stmts[len(body.stmts) - 1]
		if !is_bare_exit(last, exit) {
			return
		}
		// Lines after the if, blank lines at both ends dropped.
		start := if_stmt.end.offset
		for start < len(src) && src[start] != '\n' {
			start += 1
		}
		end := close
		for end > start && strings.is_space(rune(src[end - 1])) {
			end -= 1
		}
		replace_end = end
		strings.write_string(&sb, reindent(strings.trim_left(src[start:end], "\r\n"), ind, deeper))
		strings.write_byte(&sb, '\n')
		body_text = strings.trim_left(strings.trim_right_space(src[body.open.offset + 1:last.pos.offset]), "\r\n")
		// Nothing follows the new if when the old body was only the exit, so the exit is dead.
		if len(body_text) > 0 && !is_bare_exit(following[len(following) - 1], exit) {
			strings.write_string(&sb, deeper)
			strings.write_string(&sb, exit_text[exit])
			strings.write_byte(&sb, '\n')
		}
	}
	strings.write_string(&sb, ind)
	strings.write_string(&sb, "}\n")
	strings.write_string(&sb, reindent(body_text, deeper, ind))

	edits := make([]TextEdit, 1, context.temp_allocator)
	edits[0] = TextEdit {
		range   = range_of(ctx, if_stmt.pos.offset, replace_end),
		newText = match_line_endings(src, strings.trim_right_space(strings.to_string(sb))),
	}
	title := fmt.tprintf("Invert if (early %s)", exit_text[exit])
	append(ctx.actions, make_code_action(ctx, title, "refactor.rewrite", edits))
}

// The statement list holding the if, the exit that leaves its owner, and the offset up to which
// following statements extend.
enclosing_list :: proc(
	function: ^ast.Proc_Lit,
	if_stmt: ^ast.If_Stmt,
) -> (
	stmts: []^ast.Stmt,
	exit: Exit,
	close: int,
	ok: bool,
) {
	chain := nodes_at({function.body}, if_stmt.pos.offset)
	parent, owner: ^ast.Node
	for at in chain {
		if at.node == if_stmt {
			parent = at.parent
		}
	}
	for at in chain {
		if at.node == parent {
			owner = at.parent
		}
	}
	if parent == nil {
		return
	}

	#partial switch p in parent.derived {
	case ^ast.Block_Stmt:
		if p.uses_do {
			return
		}
		stmts = p.stmts
		close = p.close.offset
		if owner == nil {
			exit = .Return
			if function.type != nil && function.type.results != nil && len(function.type.results.list) > 0 {
				return
			}
		} else {
			#partial switch _ in owner.derived {
			case ^ast.For_Stmt, ^ast.Range_Stmt:
				exit = .Continue
			case:
				return
			}
		}
	case ^ast.Case_Clause:
		if len(p.body) == 0 {
			return
		}
		stmts = p.body
		close = p.body[len(p.body) - 1].end.offset
		exit = .Break
	case:
		return
	}
	return stmts, exit, close, true
}

is_bare_exit :: proc(stmt: ^ast.Stmt, exit: Exit) -> bool {
	#partial switch s in stmt.derived {
	case ^ast.Return_Stmt:
		return exit == .Return && len(s.results) == 0
	case ^ast.Branch_Stmt:
		if s.label != nil {
			return false
		}
		return (exit == .Continue && s.tok.kind == .Continue) || (exit == .Break && s.tok.kind == .Break)
	}
	return false
}

// Find the innermost if statement that contains the given position
// This will NOT return else-if statements, only top-level if statements
// Also will not return an if statement if the position is in its else clause
// rols: other fork actions look up the if at the cursor
@(private = "package")
find_if_stmt_at_position :: proc(stmts: []^ast.Stmt, position: common.AbsolutePosition) -> ^ast.If_Stmt {
	for stmt in stmts {
		if stmt == nil {
			continue
		}
		if result := find_if_stmt_in_node(stmt, position, false); result != nil {
			return result
		}
	}
	return nil
}

find_if_stmt_in_node :: proc(node: ^ast.Node, position: common.AbsolutePosition, in_else_clause: bool) -> ^ast.If_Stmt {
	if node == nil {
		return nil
	}

	if !(node.pos.offset <= position && position <= node.end.offset) {
		return nil
	}

	#partial switch n in node.derived {
	case ^ast.If_Stmt:
		// First check if position is in the else clause
		if n.else_stmt != nil && position_in_node(n.else_stmt, position) {
			// Position is in the else clause - look for nested ifs inside it
			// but mark that we're in an else clause
			if nested := find_if_stmt_in_node(n.else_stmt, position, true); nested != nil {
				return nested
			}
			// Position is in else clause but not on a valid nested if
			// Don't return the current if statement
			return nil
		}

		if n.body != nil && position_in_node(n.body, position) {
			if nested := find_if_stmt_in_node(n.body, position, false); nested != nil {
				return nested
			}
			// Position is inside the body but no nested if found
			// Don't return the current if statement
			return nil
		}

		// Position is in the condition/init part or we're the closest if
		// Only return this if statement if we're NOT in an else clause
		// (i.e., this is not an else-if)
		if !in_else_clause {
			return n
		}
		return nil

	case ^ast.Block_Stmt:
		for stmt in n.stmts {
			if result := find_if_stmt_in_node(stmt, position, false); result != nil {
				return result
			}
		}

	case ^ast.Proc_Lit:
		if n.body != nil {
			return find_if_stmt_in_node(n.body, position, false)
		}

	case ^ast.Value_Decl:
		for value in n.values {
			if result := find_if_stmt_in_node(value, position, false); result != nil {
				return result
			}
		}

	case ^ast.For_Stmt:
		if n.body != nil {
			return find_if_stmt_in_node(n.body, position, false)
		}

	case ^ast.Range_Stmt:
		if n.body != nil {
			return find_if_stmt_in_node(n.body, position, false)
		}

	case ^ast.Switch_Stmt:
		if n.body != nil {
			return find_if_stmt_in_node(n.body, position, false)
		}

	case ^ast.Type_Switch_Stmt:
		if n.body != nil {
			return find_if_stmt_in_node(n.body, position, false)
		}

	case ^ast.Case_Clause:
		for stmt in n.body {
			if result := find_if_stmt_in_node(stmt, position, false); result != nil {
				return result
			}
		}

	case ^ast.When_Stmt:
		if n.body != nil {
			if result := find_if_stmt_in_node(n.body, position, false); result != nil {
				return result
			}
		}
		if n.else_stmt != nil {
			if result := find_if_stmt_in_node(n.else_stmt, position, false); result != nil {
				return result
			}
		}

	case ^ast.Defer_Stmt:
		if n.stmt != nil {
			return find_if_stmt_in_node(n.stmt, position, false)
		}
	}

	return nil
}

// rols: rewritten to keep labels, do-bodies and indentation
// The replacement starts at the `if`, so a label stays in place. Bodies keep their depth; a
// `do` body becomes a block. An empty else is dropped, so inverting twice gives the input back.
generate_inverted_if :: proc(src: string, if_stmt: ^ast.If_Stmt, body: ^ast.Block_Stmt) -> (string, bool) {
	cond, ok := invert_condition(src, if_stmt.cond)
	if !ok {
		return "", false
	}

	ind := get_line_indentation(src, if_stmt.pos.offset)
	unit := indent_unit(src, ind, first_own_line_stmt(if_stmt))
	deeper := strings.concatenate({ind, unit}, context.temp_allocator)

	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "if ")
	if if_stmt.init != nil {
		strings.write_string(&sb, node_text(src, if_stmt.init))
		strings.write_string(&sb, "; ")
	}
	strings.write_string(&sb, cond)
	strings.write_string(&sb, " {\n")

	new_else := block_lines(src, body, ind, unit)
	new_then: string
	chain: ^ast.If_Stmt
	if if_stmt.else_stmt != nil {
		#partial switch e in if_stmt.else_stmt.derived {
		case ^ast.Block_Stmt:
			new_then = block_lines(src, e, ind, unit)
		case ^ast.If_Stmt:
			// The else-if chain moves into the then block, one level deeper.
			new_then = reindent(strings.concatenate({ind, node_text(src, e)}, context.temp_allocator), ind, deeper)
		case:
			return "", false
		}
		// A then block holding only an if becomes the new else-if chain, which is what the
		// inversion of a chain produces.
		if !body.uses_do && len(body.stmts) == 1 {
			if inner, is_if := body.stmts[0].derived.(^ast.If_Stmt);
			   is_if && inner.label == nil && !has_comments_around(src, body, inner) {
				chain = inner
			}
		}
	}

	if len(new_then) > 0 {
		strings.write_string(&sb, new_then)
		strings.write_byte(&sb, '\n')
	}
	strings.write_string(&sb, ind)
	strings.write_byte(&sb, '}')
	if chain != nil {
		strings.write_string(&sb, " else ")
		text := reindent(strings.concatenate({deeper, node_text(src, chain)}, context.temp_allocator), deeper, ind)
		strings.write_string(&sb, strings.trim_prefix(text, ind))
	} else if len(new_else) > 0 {
		strings.write_string(&sb, " else {\n")
		strings.write_string(&sb, new_else)
		strings.write_byte(&sb, '\n')
		strings.write_string(&sb, ind)
		strings.write_byte(&sb, '}')
	}

	return strings.to_string(sb), true
}

// rols: measures the file's indentation unit
// A statement inside one of the if's blocks that sits on its own line, to measure the indentation
// unit from.
first_own_line_stmt :: proc(if_stmt: ^ast.If_Stmt) -> ^ast.Node {
	for stmt in ([]^ast.Stmt{if_stmt.body, if_stmt.else_stmt}) {
		if stmt == nil {
			continue
		}
		if block, is_block := stmt.derived.(^ast.Block_Stmt); is_block && !block.uses_do && len(block.stmts) > 0 {
			return block.stmts[0]
		}
	}
	return nil
}

// rols: the early-exit rewrite refuses to move comments
@(private = "package")
has_comments_around :: proc(src: string, block: ^ast.Block_Stmt, stmt: ^ast.Stmt) -> bool {
	before := strings.trim_space(src[block.open.offset + 1:stmt.pos.offset])
	after := strings.trim_space(src[stmt.end.offset:block.close.offset])
	return before != "" || after != ""
}

// rols: the generated text is written with "\n", a CRLF file needs its own endings back
match_line_endings :: proc(src, text: string) -> string {
	if !strings.contains(src, "\r\n") {
		return text
	}
	lf, _ := strings.replace_all(text, "\r\n", "\n", context.temp_allocator)
	crlf, _ := strings.replace_all(lf, "\n", "\r\n", context.temp_allocator)
	return crlf
}

// rols: handles parens and nested logical operators
// Invert a condition expression
@(private = "package")
invert_condition :: proc(src: string, cond: ^ast.Expr) -> (string, bool) {
	if cond == nil {
		return "", false
	}

	#partial switch c in cond.derived {
	case ^ast.Binary_Expr:
		inverted_op, can_invert := get_inverted_operator(c.op.kind)
		if can_invert {
			left_text := src[c.left.pos.offset:c.left.end.offset]
			right_text := src[c.right.pos.offset:c.right.end.offset]
			return fmt.tprintf("%s %s %s", left_text, inverted_op, right_text), true
		}

	case ^ast.Unary_Expr:
		if c.op.kind == .Not {
			// `!(a && b)` comes back as `a && b`, the form the inversion of `a && b` produced.
			if paren, is_paren := c.expr.derived.(^ast.Paren_Expr); is_paren && is_logical(paren.expr) {
				return node_text(src, paren.expr), true
			}
			return node_text(src, c.expr), true
		}

	case ^ast.Paren_Expr:
		if is_logical(c.expr) {
			return fmt.tprintf("!%s", node_text(src, cond)), true
		}
		inner_inverted, ok := invert_condition(src, c.expr)
		if ok {
			return fmt.tprintf("(%s)", inner_inverted), true
		}
	}

	// Default: wrap the whole condition with !()
	cond_text := src[cond.pos.offset:cond.end.offset]
	if is_simple_expr(cond) {
		return fmt.tprintf("!%s", cond_text), true
	}
	return fmt.tprintf("!(%s)", cond_text), true
}

// rols: && and || need parentheses when negated
is_logical :: proc(expr: ^ast.Expr) -> bool {
	bin, is_binary := expr.derived.(^ast.Binary_Expr)
	return is_binary && (bin.op.kind == .Cmp_And || bin.op.kind == .Cmp_Or)
}

// Check if an expression is simple (identifier, call, or already parenthesized)
is_simple_expr :: proc(expr: ^ast.Expr) -> bool {
	if expr == nil {
		return false
	}
	#partial switch e in expr.derived {
	case ^ast.Ident, ^ast.Paren_Expr, ^ast.Call_Expr, ^ast.Selector_Expr, ^ast.Index_Expr:
		return true
	}
	return false
}

// Get the inverted comparison operator
get_inverted_operator :: proc(op: tokenizer.Token_Kind) -> (string, bool) {
	#partial switch op {
	case .Cmp_Eq:
		return "!=", true
	case .Not_Eq:
		return "==", true
	case .Lt:
		return ">=", true
	case .Lt_Eq:
		return ">", true
	case .Gt:
		return "<=", true
	case .Gt_Eq:
		return "<", true
	// rols: invert set membership too
	case .In:
		return "not_in", true
	case .Not_In:
		return "in", true
	}
	return "", false
}
