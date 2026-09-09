#+private file

package server

import "core:odin/ast"
import "core:strings"

@(private = "package")
add_merge_cases_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_merge_cases {
		return
	}
	if ctx.position_context.switch_stmt == nil {
		return
	}
	block, is_block := ctx.position_context.switch_stmt.body.derived.(^ast.Block_Stmt)
	if !is_block {
		return
	}

	src := ctx.document.ast.src
	pos := ctx.range.start

	clauses := make([dynamic]^ast.Case_Clause, 0, len(block.stmts), context.temp_allocator)
	index := -1
	for stmt in block.stmts {
		clause, is_clause := stmt.derived.(^ast.Case_Clause)
		if !is_clause {
			return
		}
		if clause.pos.offset <= pos && pos <= clause.end.offset {
			index = len(clauses)
		}
		append(&clauses, clause)
	}
	if index < 0 {
		return
	}
	clause := clauses[index]

	// Either rewrite would move where the fallthrough lands.
	if len(clause.body) > 0 {
		if branch, is_branch := clause.body[len(clause.body) - 1].derived.(^ast.Branch_Stmt); is_branch {
			if branch.tok.kind == .Fallthrough {
				return
			}
		}
	}

	if len(clause.list) > 1 {
		append_replace_range(ctx, clause.pos.offset, clause_end(src, clause), "Split case", split_text(src, clause))
	}

	if index + 1 < len(clauses) {
		next := clauses[index + 1]
		if len(clause.list) > 0 && len(next.list) > 0 && body_key(src, clause) == body_key(src, next) {
			append_replace_range(
				ctx,
				clause.pos.offset,
				clause_end(src, next),
				"Merge with next case",
				merge_text(src, clause, next),
			)
		}
	}
}

// A clause ends on the newline before the next one; stop at the last non-space byte instead.
clause_end :: proc(src: string, clause: ^ast.Case_Clause) -> int {
	_, end := trim_range(src, clause.terminator.pos.offset, clause.end.offset)
	return end
}

// The clause body with all whitespace dropped, so two clauses at different indentation compare equal.
body_key :: proc(src: string, clause: ^ast.Case_Clause) -> string {
	sb := strings.builder_make(context.temp_allocator)
	for stmt in clause.body {
		for r in node_text(src, stmt) {
			if !strings.is_space(r) {
				strings.write_rune(&sb, r)
			}
		}
	}
	return strings.to_string(sb)
}

merge_text :: proc(src: string, clause, next: ^ast.Case_Clause) -> string {
	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, "case ")
	write_list(&sb, src, clause.list)
	strings.write_string(&sb, ", ")
	write_list(&sb, src, next.list)
	strings.write_string(&sb, src[clause.terminator.pos.offset:clause_end(src, clause)])
	return strings.to_string(sb)
}

split_text :: proc(src: string, clause: ^ast.Case_Clause) -> string {
	ind := get_line_indentation(src, clause.pos.offset)
	body := src[clause.terminator.pos.offset + 1:clause_end(src, clause)]

	sb := strings.builder_make(context.temp_allocator)
	for expr, i in clause.list {
		if i > 0 {
			strings.write_byte(&sb, '\n')
			strings.write_string(&sb, ind)
		}
		strings.write_string(&sb, "case ")
		strings.write_string(&sb, node_text(src, expr))
		strings.write_byte(&sb, ':')
		strings.write_string(&sb, body)
	}
	return strings.to_string(sb)
}

write_list :: proc(sb: ^strings.Builder, src: string, list: []^ast.Expr) {
	for expr, i in list {
		if i > 0 {
			strings.write_string(sb, ", ")
		}
		strings.write_string(sb, node_text(src, expr))
	}
}
