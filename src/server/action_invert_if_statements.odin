#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"

import "src:common"

/*
 * The general idea behind inverting if statements is to allow 
 * if statements to be inverted without changing their behavior.
 * The examples of these changes are provided in the tests.
 * We should be careful to only allow this code action when it is safe to do so.
 * So for now, we only support only one level of if statements without else-if chains.
 */

@(private="package")
add_invert_if_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_invert_if {
		return
	}

	if_stmt := find_if_stmt_at_position(ctx.document.ast.decls[:], ctx.range.start)
	if if_stmt == nil {
		return
	}

	new_text, ok := generate_inverted_if(ctx.document, if_stmt)
	if !ok {
		return
	}

	range := common.get_token_range(if_stmt^, ctx.document.ast.src)

	edits := make([]TextEdit, 1, context.temp_allocator)
	edits[0] = TextEdit{range = range, newText = new_text}

	append(ctx.actions, make_code_action(ctx, "Invert if", "refactor.more", edits))

	add_early_return_action(ctx, if_stmt)
}

// Offered only for an if that is a direct child of a proc body without results, so the added bare
// `return` leaves the proc and cannot be captured by a loop or switch.
add_early_return_action :: proc(ctx: ^ActionContext, if_stmt: ^ast.If_Stmt) {
	if if_stmt.else_stmt != nil || if_stmt.init != nil || if_stmt.label != nil || if_stmt.body == nil {
		return
	}
	body, is_block := if_stmt.body.derived.(^ast.Block_Stmt)
	if !is_block || len(body.stmts) == 0 {
		return
	}

	function := ctx.position_context.function
	if function == nil || function.body == nil {
		return
	}
	if function.type != nil && function.type.results != nil && len(function.type.results.list) > 0 {
		return
	}
	proc_body, proc_body_is_block := function.body.derived.(^ast.Block_Stmt)
	if !proc_body_is_block {
		return
	}
	list, found := find_stmt_list_at(function.body, if_stmt.pos.offset, if_stmt.end.offset)
	if !found ||
	   raw_data(list.stmts) != raw_data(proc_body.stmts) ||
	   len(list.stmts) != len(proc_body.stmts) ||
	   list.first > list.last ||
	   list.stmts[list.first] != if_stmt {
		return
	}

	src := ctx.document.ast.src
	cond, ok := invert_condition(src, if_stmt.cond)
	if !ok {
		return
	}
	ind := get_line_indentation(src, if_stmt.pos.offset)
	following := list.stmts[list.first + 1:]

	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "if ")
	strings.write_string(&sb, cond)
	strings.write_string(&sb, " {\n")

	replace_end := if_stmt.end.offset
	body_end := body.close.offset

	if len(following) == 0 {
		strings.write_string(&sb, ind)
		strings.write_string(&sb, "\treturn\n")
		strings.write_string(&sb, ind)
		strings.write_string(&sb, "}\n")
	} else {
		last_body := body.stmts[len(body.stmts) - 1]
		ret, is_return := last_body.derived.(^ast.Return_Stmt)
		if !is_return || len(ret.results) > 0 {
			return
		}
		for stmt in following {
			if _, is_defer := stmt.derived.(^ast.Defer_Stmt); is_defer {
				return
			}
		}
		body_end = ret.pos.offset

		following_text, following_end := source_lines(src, following[0].pos.offset, proc_body.close.offset)
		replace_end = following_end
		strings.write_string(&sb, reindent(following_text, ind, strings.concatenate({ind, "\t"}, context.temp_allocator)))
		strings.write_byte(&sb, '\n')
		if _, ends_with_return := following[len(following) - 1].derived.(^ast.Return_Stmt); !ends_with_return {
			strings.write_string(&sb, ind)
			strings.write_string(&sb, "\treturn\n")
		}
		strings.write_string(&sb, ind)
		strings.write_string(&sb, "}\n")
	}

	body_text, _ := source_lines(src, body.stmts[0].pos.offset, body_end)
	strings.write_string(&sb, reindent(body_text, strings.concatenate({ind, "\t"}, context.temp_allocator), ind))

	edits := make([]TextEdit, 1, context.temp_allocator)
	edits[0] = TextEdit {
		range   = range_of(ctx, if_stmt.pos.offset, replace_end),
		newText = strings.trim_right_space(strings.to_string(sb)),
	}
	append(ctx.actions, make_code_action(ctx, "Invert if (early return)", "refactor.rewrite", edits))
}

// Source from the start of the line holding `from` up to `to`, trailing whitespace removed, so
// comments and blank lines between statements survive. Returns the text and its end offset.
source_lines :: proc(src: string, from, to: int) -> (string, int) {
	start := from
	for start > 0 && src[start - 1] != '\n' {
		start -= 1
	}
	text := strings.trim_right_space(src[start:to])
	return text, start + len(text)
}

// Find the innermost if statement that contains the given position
// This will NOT return else-if statements, only top-level if statements
// Also will not return an if statement if the position is in its else clause
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

// Generate the inverted if statement text
generate_inverted_if :: proc(document: ^Document, if_stmt: ^ast.If_Stmt) -> (string, bool) {
	src := document.ast.src

	indent := get_line_indentation(src, if_stmt.pos.offset)

	sb := strings.builder_make(context.temp_allocator)

	if if_stmt.label != nil {
		label_text := src[if_stmt.label.pos.offset:if_stmt.label.end.offset]
		strings.write_string(&sb, label_text)
		strings.write_string(&sb, ": ")
	}

	strings.write_string(&sb, "if ")

	if if_stmt.init != nil {
		init_text := src[if_stmt.init.pos.offset:if_stmt.init.end.offset]
		strings.write_string(&sb, init_text)
		strings.write_string(&sb, "; ")
	}

	if if_stmt.cond != nil {
		inverted_cond, ok := invert_condition(src, if_stmt.cond)
		if !ok {
			return "", false
		}
		strings.write_string(&sb, inverted_cond)
	}

	strings.write_string(&sb, " ")

	// Now we need to swap the bodies

	if if_stmt.else_stmt != nil {
		else_body_text := get_block_body_text(src, if_stmt.else_stmt, indent)
		then_body_text := get_block_body_text(src, if_stmt.body, indent)

		strings.write_string(&sb, "{\n")
		strings.write_string(&sb, else_body_text)
		strings.write_string(&sb, indent)
		strings.write_string(&sb, "} else {\n")
		strings.write_string(&sb, then_body_text)
		strings.write_string(&sb, indent)
		strings.write_string(&sb, "}")
	} else {
		then_body_text := get_block_body_text(src, if_stmt.body, indent)

		strings.write_string(&sb, "{\n")
		strings.write_string(&sb, indent)
		strings.write_string(&sb, "} else {\n")
		strings.write_string(&sb, then_body_text)
		strings.write_string(&sb, indent)
		strings.write_string(&sb, "}")
	}

	return strings.to_string(sb), true
}

// Extract the body text from a block statement (without the braces)
get_block_body_text :: proc(src: string, stmt: ^ast.Stmt, base_indent: string) -> string {
	if stmt == nil {
		return ""
	}

	#partial switch block in stmt.derived {
	case ^ast.Block_Stmt:
		if len(block.stmts) == 0 {
			return ""
		}

		sb := strings.builder_make(context.temp_allocator)

		for s in block.stmts {
			if s == nil {
				continue
			}
			stmt_indent := get_line_indentation(src, s.pos.offset)
			stmt_text := src[s.pos.offset:s.end.offset]
			strings.write_string(&sb, stmt_indent)
			strings.write_string(&sb, stmt_text)
			strings.write_string(&sb, "\n")
		}

		return strings.to_string(sb)

	case ^ast.If_Stmt:
		// An else-if chain moves into the new then block, one level deeper than it sits now.
		chain_indent := get_line_indentation(src, block.pos.offset)
		chain := strings.concatenate({chain_indent, src[block.pos.offset:block.end.offset]}, context.temp_allocator)
		deeper := strings.concatenate({chain_indent, "\t"}, context.temp_allocator)
		return strings.concatenate({reindent(chain, chain_indent, deeper), "\n"}, context.temp_allocator)
	}

	// Fallback: just return the statement text
	stmt_text := src[stmt.pos.offset:stmt.end.offset]
	return fmt.tprintf("%s%s\n", base_indent, stmt_text)
}

// Invert a condition expression
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

		if c.op.kind == .Cmp_And || c.op.kind == .Cmp_Or {
			// Just wrap with !()
			cond_text := src[cond.pos.offset:cond.end.offset]
			return fmt.tprintf("!(%s)", cond_text), true
		}

	case ^ast.Unary_Expr:
		// If it's already negated with !, remove the negation
		if c.op.kind == .Not {
			inner_text := src[c.expr.pos.offset:c.expr.end.offset]
			return inner_text, true
		}

	case ^ast.Paren_Expr:
		inner_inverted, ok := invert_condition(src, c.expr)
		if ok {
			if needs_parentheses(inner_inverted) {
				return fmt.tprintf("(%s)", inner_inverted), true
			}
			return inner_inverted, true
		}
	}

	// Default: wrap the whole condition with !()
	cond_text := src[cond.pos.offset:cond.end.offset]
	if is_simple_expr(cond) {
		return fmt.tprintf("!%s", cond_text), true
	}
	return fmt.tprintf("!(%s)", cond_text), true
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

// Check if a string needs parentheses (simple heuristic)
needs_parentheses :: proc(s: string) -> bool {
	// If it starts with ! and is not wrapped in parens, it might need them
	// This is a simple heuristic
	return strings.contains(s, " && ") || strings.contains(s, " || ")
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
	}
	return "", false
}
