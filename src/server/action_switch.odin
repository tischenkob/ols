#+private file

package server

import "core:odin/ast"
import "core:strings"

Branch :: struct {
	values: []^ast.Expr,
	body:   ^ast.Block_Stmt,
}

@(private = "package")
add_if_to_switch_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_if_to_switch {
		return
	}
	if_stmt := find_if_stmt_at_position(ctx.document.ast.decls[:], ctx.range.start)
	if if_stmt == nil {
		return
	}
	src := ctx.document.ast.src

	branches := make([dynamic]Branch, context.temp_allocator)
	else_body: ^ast.Block_Stmt
	subject: ^ast.Expr
	end := if_stmt.end.offset
	for cur := if_stmt; cur != nil; {
		if cur.init != nil || cur.label != nil {
			return
		}
		body, is_block := cur.body.derived.(^ast.Block_Stmt)
		if !is_block || body.uses_do {
			return
		}
		pairs := make([dynamic][2]^ast.Expr, context.temp_allocator)
		if !collect_eq_pairs(cur.cond, &pairs) {
			return
		}
		if subject == nil {
			subject = pairs[0][0]
			if !pairs_share_subject(src, pairs[:], subject) {
				subject = pairs[0][1]
			}
		}
		values := make([]^ast.Expr, len(pairs), context.temp_allocator)
		for pair, i in pairs {
			value, ok := pair_value(src, pair, subject)
			if !ok {
				return
			}
			values[i] = value
		}
		append(&branches, Branch{values = values, body = body})
		end = cur.end.offset

		if cur.else_stmt == nil {
			break
		}
		#partial switch e in cur.else_stmt.derived {
		case ^ast.If_Stmt:
			cur = e
			continue
		case ^ast.Block_Stmt:
			if e.uses_do {
				return
			}
			else_body = e
			end = e.end.offset
		case:
			return
		}
		break
	}

	ind := get_line_indentation(src, if_stmt.pos.offset)
	sb := strings.builder_make(context.temp_allocator)
	if else_body == nil && is_enum_or_union(ctx, subject) {
		strings.write_string(&sb, "#partial ")
	}
	strings.write_string(&sb, "switch ")
	strings.write_string(&sb, node_text(src, subject))
	strings.write_string(&sb, " {")
	for branch in branches {
		strings.write_byte(&sb, '\n')
		strings.write_string(&sb, ind)
		strings.write_string(&sb, "case ")
		for value, i in branch.values {
			if i > 0 {
				strings.write_string(&sb, ", ")
			}
			strings.write_string(&sb, node_text(src, value))
		}
		strings.write_byte(&sb, ':')
		write_case_body(&sb, src, branch.body)
	}
	if else_body != nil {
		strings.write_byte(&sb, '\n')
		strings.write_string(&sb, ind)
		strings.write_string(&sb, "case:")
		write_case_body(&sb, src, else_body)
	}
	strings.write_byte(&sb, '\n')
	strings.write_string(&sb, ind)
	strings.write_byte(&sb, '}')

	append_replace_range(ctx, if_stmt.pos.offset, end, "Convert to switch", strings.to_string(sb))
}

// Statements of an if body sit one level below the if, which is where case statements sit too.
write_case_body :: proc(sb: ^strings.Builder, src: string, body: ^ast.Block_Stmt) {
	if inner := block_inner_text(src, body); len(inner) > 0 {
		strings.write_byte(sb, '\n')
		strings.write_string(sb, inner)
	}
}

// Splits `a == x || a == y` into its comparisons, through parentheses.
collect_eq_pairs :: proc(expr: ^ast.Expr, pairs: ^[dynamic][2]^ast.Expr) -> bool {
	expr := expr
	for {
		paren, is_paren := expr.derived.(^ast.Paren_Expr)
		if !is_paren {
			break
		}
		expr = paren.expr
	}
	bin, is_binary := expr.derived.(^ast.Binary_Expr)
	if !is_binary {
		return false
	}
	#partial switch bin.op.kind {
	case .Cmp_Eq:
		append(pairs, [2]^ast.Expr{bin.left, bin.right})
		return true
	case .Cmp_Or:
		return collect_eq_pairs(bin.left, pairs) && collect_eq_pairs(bin.right, pairs)
	}
	return false
}

pairs_share_subject :: proc(src: string, pairs: [][2]^ast.Expr, subject: ^ast.Expr) -> bool {
	for pair in pairs {
		if _, ok := pair_value(src, pair, subject); !ok {
			return false
		}
	}
	return true
}

// The side of the comparison that is not the subject. Both sides being the subject is refused.
pair_value :: proc(src: string, pair: [2]^ast.Expr, subject: ^ast.Expr) -> (^ast.Expr, bool) {
	want := strip_space(node_text(src, subject))
	left_is := strip_space(node_text(src, pair[0])) == want
	right_is := strip_space(node_text(src, pair[1])) == want
	if left_is == right_is {
		return nil, false
	}
	return left_is ? pair[1] : pair[0], true
}

is_enum_or_union :: proc(ctx: ^ActionContext, subject: ^ast.Expr) -> bool {
	// Resolving a global type turns locals off and leaves them off.
	ctx.ast_context.use_locals = true
	symbol, ok := resolve_type_expression(ctx.ast_context, subject)
	if !ok {
		return false
	}
	#partial switch _ in symbol.value {
	case SymbolEnumValue, SymbolUnionValue:
		return true
	}
	return false
}
