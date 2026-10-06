package odin_printer

// rols: fmt builds the group id of a one-line block
import "core:fmt"
import "core:log"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:slice"
import "core:strconv"
import "core:strings"

@(private)
comment_before_position :: proc(p: ^Printer, pos: tokenizer.Pos) -> bool {
	if len(p.comments) <= p.latest_comment_index {
		return false
	}

	comment := p.comments[p.latest_comment_index]

	return comment.pos.offset < pos.offset
}

@(private)
comment_before_or_in_line :: proc(p: ^Printer, line: int) -> bool {
	if len(p.comments) <= p.latest_comment_index {
		return false
	}

	comment := p.comments[p.latest_comment_index]

	return comment.pos.line < line
}

@(private)
next_comment_group :: proc(p: ^Printer) {
	p.latest_comment_index += 1
}

@(private)
text_token :: proc(p: ^Printer, token: tokenizer.Token) -> ^Document {
	document, _ := visit_comments(p, token.pos)
	return cons(document, text(token.text))
}

@(private)
text_position :: proc(p: ^Printer, value: string, pos: tokenizer.Pos) -> ^Document {
	document, _ := visit_comments(p, pos)
	return cons(document, text(value))
}

@(private)
newline_position :: proc(p: ^Printer, amount: int, pos: tokenizer.Pos) -> ^Document {
	document, _ := visit_comments(p, pos)
	return cons(document, newline(amount))
}

@(private)
set_source_position :: proc(p: ^Printer, pos: tokenizer.Pos) {
	p.source_position = pos
}

@(private)
move_line :: proc(p: ^Printer, pos: tokenizer.Pos) -> ^Document {
	// rols: a block comment before the node on its line prints before it with a space (rols_comments.odin)
	return move_line_leading(p, pos)
}

@(private)
move_line_limit :: proc(p: ^Printer, pos: tokenizer.Pos, limit: int) -> (^Document, bool) {
	lines := pos.line - p.source_position.line

	if lines < 0 {
		return empty(), false
	}

	document, comments_newlined := visit_comments(p, pos)

	p.source_position = pos

	return cons(document, newline(max(min(lines - comments_newlined, limit), 0))), lines > 0
}

@(private)
visit_comment :: proc(p: ^Printer, comment: tokenizer.Token) -> (int, ^Document) {
	document := empty()
	if len(comment.text) == 0 {
		return 0, document
	}

	newlines_before_comment := comment.pos.line - p.source_position.line
	newlines_before_comment_limited := min(newlines_before_comment, p.config.newline_limit + 1)

	document = cons(document, newline(newlines_before_comment_limited))

	if comment.text[:2] != "/*" {
		if info, is_disabled := p.disabled_lines[comment.pos.line]; is_disabled {
			p.source_position = comment.pos
			if info.start_line == comment.pos.line && info.empty {
				return info.end_line - info.start_line, cons(escape_nest(document), text(info.text))
			}
			return 1, empty()
		} else if comment.pos.line == p.source_position.line && p.source_position.column != 1 {
			p.source_position = comment.pos
			if comment_option, exist := p.comments_option[comment.pos.line]; exist && comment_option == .Indent {
				// rols: a comment after the closing brace does not take the option of the opening line
				limit, has_limit := p.comments_option_limit[comment.pos.line]
				if has_limit && comment.pos.offset >= limit {
					return newlines_before_comment, cons_with_nopl(document, line_suffix(comment.text, alignable = true))
				}
				delete_key(&p.comments_option, comment.pos.line)
				return newlines_before_comment, cons_with_nopl(
					document,
					cons(text(p.indentation), line_suffix(comment.text, alignable = true)),
				)
			} else {
				return newlines_before_comment, cons_with_nopl(document, line_suffix(comment.text, alignable = true))
			}
		} else {
			p.source_position = comment.pos
			return newlines_before_comment, cons(document, line_suffix(comment.text))
		}
	} else {
		newlines := strings.count(comment.text, "\n")

		if comment.pos.line in p.disabled_lines {
			p.source_position = comment.pos
			p.source_position.line += newlines
			return 1, empty()
		} else if comment.pos.line == p.source_position.line && p.source_position.column != 1 {
			p.source_position = comment.pos
			p.source_position.line += newlines
			return newlines_before_comment + newlines, cons_with_opl(document, text(comment.text))
		} else {
			p.source_position = comment.pos
			p.source_position.line += newlines
			return newlines_before_comment + newlines, cons(document, text(comment.text))
		}

		return 0, document
	}
}

@(private)
visit_comments :: proc(p: ^Printer, pos: tokenizer.Pos) -> (^Document, int) {
	document := empty()
	lines := 0

	for comment_before_position(p, pos) {
		comment_group := p.comments[p.latest_comment_index]

		for comment in comment_group.list {
			newlined, tmp_document := visit_comment(p, comment)
			lines += newlined
			document = cons(document, tmp_document)
		}

		next_comment_group(p)
	}

	return document, lines
}

// rols: the text of a disabled region as emitted for a node at `node_pos`
@(private)
disabled_region_text :: proc(p: ^Printer, info: Disabled_Info, node_pos: tokenizer.Pos) -> string {
	// code before the comment ends a statement that began on an earlier line, which the printer already emitted
	code_before := strings.trim_space(p.src[info.begin:info.comment_offset]) != ""
	if code_before && node_pos.offset > info.comment_offset {
		line_start := node_pos.offset - (node_pos.column - 1)
		return strings.concatenate(
			{p.src[line_start:node_pos.offset], info.text[info.comment_offset - info.begin:]},
			p.allocator,
		)
	}
	return info.text
}

@(private)
visit_disabled :: proc(p: ^Printer, node: ^ast.Node) -> ^Document {
	if node.pos.line not_in p.disabled_lines {
		return empty()
	}

	disabled_info := p.disabled_lines[node.pos.line]

	if disabled_info.text == "" {
		return empty()
	}

	if p.disabled_until_line > node.pos.line {
		return empty()
	}

	node_pos := node.pos

	#partial switch v in node.derived {
	case ^ast.Value_Decl:
		if len(v.attributes) > 0 {
			node_pos = v.attributes[0].pos
		}
	}

	pos_one_line_before := node_pos
	pos_one_line_before.line -= 1

	move := cons(move_line(p, pos_one_line_before), escape_nest(move_line(p, node_pos)))

	p.disabled_until_line = disabled_info.end_line
	p.source_position = node.end
	p.source_position.line = disabled_info.end_line

	// Attributes are part of the declaration but sit above the directive, so they fall outside
	// `text` and outside ordinary visiting. Dropping them silently un-privatises a declaration.
	prefix := empty()
	if node_pos.offset < disabled_info.begin {
		prefix = text(p.src[node_pos.offset:disabled_info.begin])
	}

	// rols: the region rule is shared with visit_struct_field_list
	region_text := disabled_region_text(p, disabled_info, node_pos)

	document := cons(move, prefix, text(region_text))

	for comment_before_or_in_line(p, disabled_info.end_line + 1) {
		// we need to handle the rest of the comment group
		comment_group := p.comments[p.latest_comment_index]
		for comment in comment_group.list {
			if comment.pos.line <= disabled_info.end_line {
				continue
			}
			newlined, tmp_document := visit_comment(p, comment)
			document = cons(document, tmp_document)
		}
		next_comment_group(p)
	}

	return document
}

@(private)
visit_decl :: proc(p: ^Printer, decl: ^ast.Decl, called_in_stmt := false) -> ^Document {
	if decl == nil {
		return empty()
	}

	if decl.pos.line in p.disabled_lines {
		return visit_disabled(p, decl)
	}

	defer {
		set_source_position(p, decl.end)
	}

	#partial switch v in decl.derived {
	case ^ast.Assign_Stmt:
		return visit_stmt(p, v)
	case ^ast.Expr_Stmt:
		document := move_line(p, decl.pos)
		return cons(document, visit_expr(p, v.expr))
	case ^ast.When_Stmt:
		return visit_stmt(p, cast(^ast.Stmt)decl)
	case ^ast.Foreign_Import_Decl:
		document := empty()
		if len(v.attributes) > 0 {
			document = cons(document, visit_attributes(p, &v.attributes, v.pos))
		}

		document = cons(document, move_line(p, decl.pos))
		document = cons(document, cons_with_opl(text(v.foreign_tok.text), text(v.import_tok.text)))

		if v.name != nil {
			document = cons_with_opl(document, text_position(p, v.name.name, v.pos))
		}

		if len(v.fullpaths) > 1 {
			document = cons_with_nopl(document, text("{"))
			for path, i in v.fullpaths {
				document = cons(document, visit_expr(p, path))
				if i != len(v.fullpaths) - 1 {
					document = cons(document, text(","), break_with_space())
				}
			}
			document = cons(document, text("}"))
		} else if len(v.fullpaths) == 1 {
			if _, ok := v.fullpaths[0].derived.(^ast.Basic_Lit); ok {
				document = cons_with_nopl(document, visit_expr(p, v.fullpaths[0]))
			} else {
				document = cons_with_nopl(document, text("{"))
				document = cons(document, visit_expr(p, v.fullpaths[0]))
				document = cons(document, text("}"))
			}
		}

		return document
	case ^ast.Foreign_Block_Decl:
		document := empty()
		if len(v.attributes) > 0 {
			document = cons(document, visit_attributes(p, &v.attributes, v.pos))
		}

		document = cons(document, move_line(p, decl.pos))
		document = cons(document, cons_with_opl(text("foreign"), visit_expr(p, v.foreign_library)))

		if v.body != nil && is_foreign_block_only_procedures(v.body) {
			p.force_statement_fit = true
			document = cons_with_nopl(document, visit_stmt(p, v.body))
			p.force_statement_fit = false
		} else {
			document = cons_with_nopl(document, visit_stmt(p, v.body))
		}

		return document
	case ^ast.Import_Decl:
		document := empty()
		if len(v.attributes) > 0 {
			document = cons(document, visit_attributes(p, &v.attributes, v.pos))
		}

		document = cons(document, move_line(p, decl.pos))

		if v.name.text != "" {
			document = cons(
				document,
				text_token(p, v.import_tok),
				break_with_space(),
				text_token(p, v.name),
				break_with_space(),
				text(v.fullpath),
			)
		} else {
			document = cons(document, text_token(p, v.import_tok), break_with_space(), text(v.fullpath))
		}
		return document
	case ^ast.Value_Decl:
		document := empty()
		if len(v.attributes) > 0 {
			document = cons(document, visit_attributes(p, &v.attributes, v.pos))
		}

		document = cons(document, move_line(p, decl.pos), visit_state_flags(p, v.state_flags))

		lhs := empty()
		rhs := empty()

		if v.is_using {
			lhs = cons(lhs, text("using"), break_with_no_newline())
		}

		lhs = cons(lhs, visit_exprs(p, v.names, {.Add_Comma, .Glue}))

		if v.type != nil {
			// Typed constant/variable: pad before the colon so it lines up
			type_colon := text(" :" if p.config.spaces_around_colons else ":")
			padding := p.constant_alignment[decl.pos.offset]
			lhs = cons(lhs, repeat_space(padding), type_colon)
			lhs = cons_with_nopl(lhs, visit_expr(p, v.type))
		} else {
			if !v.is_mutable {
				// Constant (::): pad before the colons so it lines up
				double_colon := cons(text(":"), text(":"))
				padding := p.constant_alignment[decl.pos.offset]
				lhs = cons_with_nopl(lhs, cons(repeat_space(padding), double_colon))
			} else {
				lhs = cons_with_nopl(lhs, text(":"))
			}
		}

		if len(v.values) > 0 && v.is_mutable {
			if v.type != nil {
				lhs = cons_with_nopl(lhs, text("="))
			} else {
				lhs = cons(lhs, text("="))
			}

			rhs = cons_with_nopl(rhs, visit_exprs(p, v.values, {.Add_Comma}, .Value_Decl))
		} else if len(v.values) > 0 && v.type != nil {
			if v.type != nil {
				lhs = cons_with_nopl(lhs, text(":"))
			} else {
				lhs = cons(lhs, text(":"))
			}
			rhs = cons_with_nopl(rhs, visit_exprs(p, v.values, {.Add_Comma}))
		} else {
			rhs = cons_with_nopl(rhs, visit_exprs(p, v.values, {.Add_Comma}, .Value_Decl))
		}

		if len(v.values) > 0 {
			if is_values_nestable_assign(v.values) {
				return cons(document, group(nest(cons_with_opl(lhs, group(rhs)))))
			} else if is_values_nestable_if_break_assign(v.values) {
				assignments := cons(lhs, group(nest(break_with_space()), Document_Group_Options{id = "assignments"}))
				assignments = cons(assignments, nest_if_break(group(rhs), "assignments"))
				return cons(document, group(assignments))
			} else {
				return cons(document, group(cons_with_nopl(group(lhs), group(rhs))))
			}
		} else {
			return cons(document, group(lhs))
		}
	case:
		log.error(decl.derived)
		p.errored_out = true
		return nil
	}

	return empty()
}

@(private)
exprs_contain_empty_idents :: proc(list: []^ast.Expr) -> bool {
	for expr in list {
		if ident, ok := expr.derived.(^ast.Ident); ok && ident.name == "_" {
			continue
		}
		return false
	}
	return true
}

@(private)
is_call_expr_nestable :: proc(list: []^ast.Expr) -> bool {
	if len(list) == 0 {
		return true
	}

	#partial switch v in list[len(list) - 1].derived {
	case ^ast.Comp_Lit, ^ast.Proc_Type, ^ast.Proc_Lit:
		return false
	}

	return true
}

@(private)
is_foreign_block_only_procedures :: proc(stmt: ^ast.Stmt) -> bool {
	return true
}

@(private)
is_value_decl_statement_ending_with_call :: proc(stmt: ^ast.Stmt) -> bool {
	if value_decl, ok := stmt.derived.(^ast.Value_Decl); ok {
		if len(value_decl.values) == 0 {
			return false
		}

		#partial switch v in value_decl.values[len(value_decl.values) - 1].derived {
		case ^ast.Call_Expr, ^ast.Selector_Call_Expr:
			return true
		}
	}

	return false
}

@(private)
is_assign_statement_ending_with_call :: proc(stmt: ^ast.Stmt) -> bool {
	if assign_stmt, ok := stmt.derived.(^ast.Assign_Stmt); ok {
		if len(assign_stmt.rhs) == 0 {
			return false
		}

		#partial switch v in assign_stmt.rhs[len(assign_stmt.rhs) - 1].derived {
		case ^ast.Call_Expr, ^ast.Selector_Call_Expr:
			return true
		}
	}

	return false
}

@(private)
is_value_expression_call :: proc(expr: ^ast.Expr) -> bool {
	#partial switch v in expr.derived {
	case ^ast.Call_Expr, ^ast.Selector_Call_Expr:
		return true
	case ^ast.Unary_Expr:
		#partial switch v2 in v.expr.derived {
		case ^ast.Call_Expr, ^ast.Selector_Call_Expr:
			return true
		}
	}

	return false
}


@(private)
is_values_nestable_assign :: proc(list: []^ast.Expr) -> bool {
	if len(list) > 1 {
		return true
	}

	for expr in list {
		#partial switch v in expr.derived {
		case ^ast.Ident,
		     ^ast.Binary_Expr,
		     ^ast.Index_Expr,
		     ^ast.Selector_Expr,
		     ^ast.Paren_Expr,
		     ^ast.Ternary_If_Expr,
		     ^ast.Ternary_When_Expr,
		     ^ast.Or_Else_Expr:
			return true
		}
	}
	return false
}

//Should the return stmt list behave like a call expression.
@(private)
is_values_return_stmt_callable :: proc(list: []^ast.Expr) -> bool {
	if len(list) > 1 {
		return false
	}

	for expr in list {
		result := expr
		if paren, is_paren := expr.derived.(^ast.Paren_Expr); is_paren {
			result = paren.expr
		}

		#partial switch v in result.derived {
		case ^ast.Call_Expr, ^ast.Comp_Lit:
			return false
		}
	}
	return true
}

@(private)
is_return_stmt_ending_with_call_expr :: proc(list: []^ast.Expr) -> bool {
	if len(list) == 0 {
		return false
	}

	if _, is_call := list[len(list) - 1].derived.(^ast.Call_Expr); is_call {
		return true
	}


	return false
}

@(private)
is_return_stmt_ending_with_comp_lit_expr :: proc(list: []^ast.Expr) -> bool {
	if len(list) == 0 {
		return false
	}

	if _, is_cmp := list[len(list) - 1].derived.(^ast.Comp_Lit); is_cmp {
		return true
	}

	return false
}


@(private)
is_values_nestable_if_break_assign :: proc(list: []^ast.Expr) -> bool {
	for expr in list {
		#partial switch v in expr.derived {
		case ^ast.Call_Expr, ^ast.Comp_Lit, ^ast.Or_Return_Expr:
			return true
		case ^ast.Unary_Expr:
			#partial switch v2 in v.expr.derived {
			case ^ast.Call_Expr:
				return true
			}
		}
	}
	return false
}

@(private)
visit_exprs :: proc(
	p: ^Printer,
	list: []^ast.Expr,
	options := List_Options{},
	called_from: Expr_Called_Type = .Generic,
) -> ^Document {
	if len(list) == 0 {
		return empty()
	}

	document := empty()

	for expr, i in list {
		p.source_position = expr.pos

		if .Enforce_Newline in options {
			document = cons(
				document,
				.Group in options ? group(visit_expr(p, expr, called_from, options)) : visit_expr(p, expr, called_from, options),
			)
		} else if .Glue in options {
			document = cons_with_nopl(
				document,
				.Group in options ? group(visit_expr(p, expr, called_from, options)) : visit_expr(p, expr, called_from, options),
			)
		} else {
			document = cons_with_opl(
				document,
				.Group in options ? group(visit_expr(p, expr, called_from, options)) : visit_expr(p, expr, called_from, options),
			)
		}

		if (i != len(list) - 1 || .Trailing in options) && .Add_Comma in options {
			document = cons(document, text(","))
		}

		if (i != len(list) - 1 && .Enforce_Newline in options) {
			// rols: a block comment before the next item on its line leads that item
			above, leading, _ := visit_comments_split(p, list[i + 1].pos)
			document = cons(document, above, newline(1), leading)
		} else if .Enforce_Newline in options {
			comment, _ := visit_comments(p, list[i].end)
			document = cons(document, comment)
		}
	}

	return document
}

@(private)
visit_enum_exprs :: proc(p: ^Printer, enum_type: ast.Enum_Type, options := List_Options{}) -> ^Document {
	if len(enum_type.fields) == 0 {
		return empty()
	}

	document := empty()

	// rols: compute the alignment once instead of once per field
	alignment := 0
	if .Enforce_Newline in options {
		alignment = get_possible_enum_alignment(enum_type.fields)
	}

	// rols: the width of the block comments that lead the current item, which its alignment takes away
	leading_width := 0

	for expr, i in enum_type.fields {
		if i == 0 && .Enforce_Newline in options {
			// rols: a block comment before the first item on its line leads the item
			comment, leading: ^Document
			comment, leading, leading_width = visit_comments_split(p, enum_type.fields[i].pos)
			if _, is_nil := comment.(Document_Nil); !is_nil {
				comment = cons(comment, newline(1))
			}
			document = cons(comment, document, leading)
		}

		if (.Enforce_Newline in options) {
			// rols: the alignment is computed once before the loop
			if value, ok := expr.derived.(^ast.Field_Value); ok && alignment > 0 {
				document = cons(
					document,
					cons_with_nopl(
						visit_expr(p, value.field),
						cons_with_nopl(
							cons(
								// rols: a leading block comment counts toward the name's width
								repeat_space(alignment - get_node_length(value.field) - leading_width),
								text_position(p, "=", value.sep),
							),
							visit_expr(p, value.value),
						),
					),
				)
			} else {
				document = group(cons(document, visit_expr(p, expr, .Generic, options)))
			}
		} else {
			document = group(cons_with_opl(document, visit_expr(p, expr, .Generic, options)))
		}

		if (i != len(enum_type.fields) - 1 || .Trailing in options) && .Add_Comma in options {
			document = cons(document, text(","))
		}

		if (i != len(enum_type.fields) - 1 && .Enforce_Newline in options) {
			// rols: a block comment before the next item on its line leads that item
			comment, leading: ^Document
			comment, leading, leading_width = visit_comments_split(p, enum_type.fields[i + 1].pos)
			document = cons(document, comment, newline(1), leading)
		} else if .Enforce_Newline in options {
			comment, _ := visit_comments(p, enum_type.end)
			document = cons(document, comment)
		}
	}

	return document
}

@(private)
visit_bit_field_fields :: proc(
	p: ^Printer,
	bit_field_type: ast.Bit_Field_Type,
	options := List_Options{},
) -> ^Document {
	if len(bit_field_type.fields) == 0 {
		return empty()
	}

	document := empty()

	name_alignment, type_alignment := get_possible_bit_field_alignment(bit_field_type.fields)

	// rols: the width of the block comments that lead the current item, which its alignment takes away
	leading_width := 0

	for field, i in bit_field_type.fields {
		if i == 0 && .Enforce_Newline in options {
			// rols: a block comment before the first item on its line leads the item
			comment, leading: ^Document
			comment, leading, leading_width = visit_comments_split(p, bit_field_type.fields[i].pos)
			if _, is_nil := comment.(Document_Nil); !is_nil {
				comment = cons(comment, newline(1))
			}
			document = cons(comment, document, leading)
		}

		if (.Enforce_Newline in options) {
			document = cons(
				document,
				cons_with_nopl(
					cons(visit_expr(p, field.name), text_position(p, ":", field.name.end)),
					cons_with_nopl(
						// rols: a leading block comment counts toward the name's width
						cons(
							repeat_space(name_alignment - get_node_length(field.name) - leading_width),
							visit_expr(p, field.type),
						),
						cons_with_nopl(
							cons(
								repeat_space(type_alignment - get_node_length(field.type)),
								text_position(p, "|", field.type.end),
							),
							visit_expr(p, field.bit_size),
						),
					),
				),
			)
		} else {
			document = group(
				cons_with_opl(
					document,
					cons_with_nopl(
						cons(visit_expr(p, field.name), text_position(p, ":", field.name.end)),
						cons_with_nopl(
							cons_with_nopl(visit_expr(p, field.type), text_position(p, "|", field.type.end)),
							visit_expr(p, field.bit_size),
						),
					),
				),
			)
		}


		if field.tag.text != "" {
			document = cons_with_nopl(document, text_token(p, field.tag))
		}


		if (i != len(bit_field_type.fields) - 1 || .Trailing in options) && .Add_Comma in options {
			document = cons(document, text(","))
		}

		if (i != len(bit_field_type.fields) - 1 && .Enforce_Newline in options) {
			// rols: a block comment before the next item on its line leads that item
			comment, leading: ^Document
			comment, leading, leading_width = visit_comments_split(p, bit_field_type.fields[i + 1].pos)
			document = cons(document, comment, newline(1), leading)
		} else if .Enforce_Newline in options {
			comment, _ := visit_comments(p, bit_field_type.end)
			document = cons(document, comment)
		}
	}

	return document
}

@(private)
visit_union_exprs :: proc(p: ^Printer, union_type: ast.Union_Type, options := List_Options{}) -> ^Document {
	if len(union_type.variants) == 0 {
		return empty()
	}

	document := empty()

	// rols: compute the alignment once instead of once per variant
	alignment := 0
	if .Enforce_Newline in options {
		alignment = get_possible_enum_alignment(union_type.variants)
	}

	// rols: the width of the block comments that lead the current item, which its alignment takes away
	leading_width := 0

	for expr, i in union_type.variants {
		if i == 0 && .Enforce_Newline in options {
			// rols: a block comment before the first item on its line leads the item
			comment, leading: ^Document
			comment, leading, leading_width = visit_comments_split(p, union_type.variants[i].pos)
			if _, is_nil := comment.(Document_Nil); !is_nil {
				comment = cons(comment, newline(1))
			}
			document = cons(comment, document, leading)
		}

		if (.Enforce_Newline in options) {
			// rols: the alignment is computed once before the loop
			if value, ok := expr.derived.(^ast.Field_Value); ok && alignment > 0 {
				document = cons(
					document,
					cons_with_nopl(
						visit_expr(p, value.field),
						cons_with_nopl(
							cons(
								// rols: a leading block comment counts toward the name's width
								repeat_space(alignment - get_node_length(value.field) - leading_width),
								text_position(p, "=", value.sep),
							),
							visit_expr(p, value.value),
						),
					),
				)
			} else {
				document = group(cons(document, visit_expr(p, expr, .Generic, options)))
			}
		} else {
			document = group(cons_with_opl(document, visit_expr(p, expr, .Generic, options)))
		}

		if (i != len(union_type.variants) - 1 || .Trailing in options) && .Add_Comma in options {
			document = cons(document, text(","))
		}

		if (i != len(union_type.variants) - 1 && .Enforce_Newline in options) {
			// rols: a block comment before the next item on its line leads that item
			comment, leading: ^Document
			comment, leading, leading_width = visit_comments_split(p, union_type.variants[i + 1].pos)
			document = cons(document, comment, newline(1), leading)
		} else if .Enforce_Newline in options {
			comment, _ := visit_comments(p, union_type.end)
			document = cons(document, comment)
		}
	}

	return document
}

@(private)
// rols: first_leading_width is the width of the block comments that lead the first element, which the caller visited
visit_comp_lit_exprs :: proc(
	p: ^Printer,
	comp_lit: ast.Comp_Lit,
	options := List_Options{},
	first_leading_width := 0,
) -> ^Document {
	if len(comp_lit.elems) == 0 {
		return empty()
	}

	document := empty()

	// rols: alignment depends on every element, so compute it once instead of once per element
	alignment := 0
	align_values := false
	if .Enforce_Newline in options {
		alignment = get_possible_comp_lit_alignment(comp_lit.elems)
		align_values = alignment > 0 && should_align_comp_lit(p, comp_lit) && p.config.align_struct_values
	}

	// rols: the width of the block comments that lead the current element, which its alignment takes away
	leading_width := first_leading_width

	for expr, i in comp_lit.elems {
		if i == 0 && .Enforce_Newline in options {
			comment, _ := visit_comments(p, comp_lit.elems[i].pos)
			if _, is_nil := comment.(Document_Nil); !is_nil {
				comment = cons(comment, newline(1))
			}
			document = cons(comment, document)
		}

		if (.Enforce_Newline in options) {
			// rols: the alignment is computed once before the loop
			if value, ok := expr.derived.(^ast.Field_Value); ok && alignment > 0 {
				align := empty()
				// rols: the flag was computed once before the loop
				if align_values {
					// rols: a leading block comment counts toward the name's width
					align = repeat_space(alignment - get_node_length(value.field) - leading_width)
				}
				document = cons(
					document,
					cons_with_nopl(
						visit_expr(p, value.field),
						cons_with_nopl(cons(align, text_position(p, "=", value.sep)), visit_expr(p, value.value)),
					),
				)
			} else {
				document = group(cons(document, visit_expr(p, expr, .Generic, options)))
			}
		} else {
			document = group(cons_with_nopl(document, visit_expr(p, expr, .Generic, options)))
		}

		if (i != len(comp_lit.elems) - 1 || .Trailing in options) && .Add_Comma in options {
			document = cons(document, text(","))
		}

		if (i != len(comp_lit.elems) - 1 && .Enforce_Newline in options) {
			// rols: a block comment before the next item on its line leads that item
			comment, leading: ^Document
			comment, leading, leading_width = visit_comments_split(p, comp_lit.elems[i + 1].pos)
			document = cons(document, comment, newline(1), leading)
		} else if .Enforce_Newline in options {
			comment, _ := visit_comments(p, comp_lit.end)
			document = cons(document, comment)
		}
	}

	return document
}

@(private)
visit_attributes :: proc(p: ^Printer, attributes: ^[dynamic]^ast.Attribute, pos: tokenizer.Pos) -> ^Document {
	document := empty()
	if len(attributes) == 0 {
		return document
	}

	slice.sort_by(attributes[:], proc(i, j: ^ast.Attribute) -> bool {
		return i.pos.offset < j.pos.offset
	})

	document = cons(document, move_line(p, attributes[0].pos))

	//Ensure static is not forced newline, but until if the width is full
	if len(attributes) == 1 && len(attributes[0].elems) == 1 {
		if ident, ok := attributes[0].elems[0].derived.(^ast.Ident);
		   ok && (ident.name == "static" || ident.name == "require") {
			document = cons(
				document,
				text("@"),
				text("("),
				visit_expr(p, attributes[0].elems[0]),
				text(")"),
				break_with_no_newline(),
			)
			set_source_position(p, pos)
			return document
		}
	}

	for attribute, i in attributes {
		document = cons(document, text("@"), text("("), visit_exprs(p, attribute.elems, {.Add_Comma}), text(")"))

		if i != len(attributes) - 1 {
			document = cons(document, newline(1))
		} else if pos.line == attributes[0].pos.line {
			document = cons(document, newline(1))
		}
	}

	return document
}

@(private)
visit_state_flags :: proc(p: ^Printer, flags: ast.Node_State_Flags) -> ^Document {
	if .No_Bounds_Check in flags {
		return cons(text("#no_bounds_check"), break_with_no_newline())
	}
	if .Bounds_Check in flags {
		return cons(text("#bounds_check"), break_with_no_newline())
	}
	if .No_Type_Assert in flags {
		return cons(text("#no_type_assert"), break_with_no_newline())
	}
	if .Type_Assert in flags {
		return cons(text("#type_assert"), break_with_no_newline())
	}
	return empty()
}

@(private)
enforce_fit_if_do :: proc(stmt: ^ast.Stmt, document: ^Document) -> ^Document {
	if block_uses_do(stmt) {
		return enforce_fit(document)
	}

	return document
}

block_uses_do :: proc(stmt: ^ast.Stmt) -> bool {
	if v, ok := stmt.derived.(^ast.Block_Stmt); ok {
		return v.uses_do
	}

	return false
}

@(private)
visit_stmt :: proc(
	p: ^Printer,
	stmt: ^ast.Stmt,
	block_type: Block_Type = .Generic,
	empty_block := false,
	block_stmt := false,
) -> ^Document {
	if stmt == nil {
		return empty()
	}

	if stmt.pos.line in p.disabled_lines {
		return visit_disabled(p, stmt)
	}

	#partial switch v in stmt.derived {
	case ^ast.Import_Decl:
		return visit_decl(p, cast(^ast.Decl)stmt, true)
	case ^ast.Value_Decl:
		return visit_decl(p, cast(^ast.Decl)stmt, true)
	case ^ast.Foreign_Import_Decl:
		return visit_decl(p, cast(^ast.Decl)stmt, true)
	case ^ast.Foreign_Block_Decl:
		return visit_decl(p, cast(^ast.Decl)stmt, true)
	}

	document := visit_state_flags(p, stmt.state_flags)
	comments := move_line(p, stmt.pos)

	#partial switch v in stmt.derived {
	case ^ast.Tag_Stmt:
		//Hack to fix a bug in the odin parser
		v.end = v.stmt.end

		document = cons(document, text(v.op.text), text(v.name), break_with_no_newline(), visit_stmt(p, v.stmt))
	case ^ast.Using_Stmt:
		document = cons(document, cons_with_nopl(text("using"), visit_exprs(p, v.list, {.Add_Comma})))
	case ^ast.Block_Stmt:
		uses_do := v.uses_do && !p.config.convert_do
		is_single_line := v.open.line == v.end.line

		if v.label != nil {
			document = cons(document, visit_expr(p, v.label), text(":"), break_with_space())
		}

		// rols: a one-line block of `;` joined statements opens a normal block when it does not fit; a switch body keeps its layout
		chain_id := chain_block_id(p, v, block_type)
		then_chain_id := ""
		// rols: only the paired `else` block takes the pairing, not a block in an `else if` header
		if stmt == p.else_chain.target {
			then_chain_id = p.else_chain.id
			p.else_chain = {}
		}

		if !uses_do {
			// rols: pass the closing brace so the Indent option stays inside the braces
			document = cons(document, visit_begin_brace(p, v.pos, block_type, v.end))
			// rols: a block that may break takes its edge breaks from the group below
			if p.config.space_single_line_blocks && is_single_line && chain_id == "" {
				document = cons(document, break_with_no_newline())
			}
		} else {
			document = cons(document, text("do"), break_with(" ", false))
		}

		set_source_position(p, v.pos)

		if p.config.align_constant_definitions {
			compute_constant_alignment(p, v.stmts)
		}

		// rols: the group below breaks the `;` joins into lines and the braces onto lines of their own
		block := visit_block_stmts(p, v.stmts, chain_id)

		comment_end, _ := visit_comments(p, tokenizer.Pos{line = v.end.line, offset = v.end.offset})

		if chain_id != "" && then_chain_id != "" {
			// rols: an `else` chain block breaks when its then-block breaks, and the then-block's fit check measures it flat
			edge := break_with(p.config.space_single_line_blocks ? " " : "", true)
			content := cons(nest(cons(edge, block, comment_end)), edge, visit_end_brace(p, v.end))
			paired := if_break_or(
				enforce_break(content, Document_Group_Options{id = chain_id, measure = true}),
				group(content, Document_Group_Options{id = chain_id}),
				then_chain_id,
			)
			document = cons(document, group(paired, Document_Group_Options{rest_flat = true}))
		} else if chain_id != "" {
			edge := break_with(p.config.space_single_line_blocks ? " " : "", true)
			document = cons(
				document,
				group(
					cons(nest(cons(edge, block, comment_end)), edge, visit_end_brace(p, v.end)),
					Document_Group_Options{id = chain_id, measure = true},
				),
			)
		} else if block_type == .Switch_Stmt && !p.config.indent_cases {
			document = cons(document, block, comment_end)
		} else if uses_do {
			document = cons(document, cons(block, comment_end))
		} else {
			document = cons(document, nest(cons(block, comment_end)))
		}

		// rols: the chain group already holds the closing brace
		if !uses_do && chain_id == "" {
			if p.config.space_single_line_blocks && is_single_line {
				document = cons(document, break_with_no_newline())
			}
			document = cons(document, visit_end_brace(p, v.end))
		}
	case ^ast.If_Stmt:
		// rols: the body of a paired `else if` breaks with the block before it
		chained := v.body == p.else_chain.target

		if v.label != nil {
			document = cons(document, visit_expr(p, v.label), text(":"), break_with_space())
		}

		begin_document := text("if")
		end_document := empty()

		if v.init != nil {
			begin_document = cons_with_nopl(
				begin_document,
				cons(group(visit_stmt(p, v.init), Document_Group_Options{id = "init"}), text(";")),
			)
		}

		if v.cond != nil && v.init != nil {
			end_document = cons(group(cons(break_with_space(), group(visit_expr(p, v.cond)))))
		} else if v.cond != nil {
			end_document = cons(break_with_no_newline(), group(visit_expr(p, v.cond)))
		}

		//Special case for when the if statement ends with a call expression
		/*
		  if my_function(

		  ) {
		  }
		*/
		if v.init != nil && is_value_decl_statement_ending_with_call(v.init) ||
		   v.init != nil && is_assign_statement_ending_with_call(v.init) ||
		   v.cond != nil && v.init == nil && is_value_expression_call(v.cond) {
			break_end_document := hang(3, end_document) if v.init != nil else end_document
			document = cons(
				document,
				group(cons(begin_document, if_break_or(end_document, break_end_document, "init"))),
			)
		} else {
			document = cons(document, group(hang(3, cons(begin_document, end_document))))
		}

		// rols: the fit check of the block before a paired `else if` measures this header flat
		if chained {
			document = group(document, Document_Group_Options{rest_flat = true})
		}

		set_source_position(p, v.body.pos)

		// rols: a one-line then-block that pairs with its `else` block takes a chain group, even with one statement
		paired := pairs_with_else(p, v.body, v.else_stmt, chained)
		if paired {
			p.chain_then = v.body
		}

		document = cons_with_nopl(document, visit_stmt(p, v.body, .If_Stmt))

		set_source_position(p, v.body.end)

		if v.else_stmt != nil {
			else_on_newline :=
				p.config.brace_style == .Allman ||
				p.config.brace_style == .Stroustrup ||
				(!p.config.convert_do && block_uses_do(v.body))
			if else_on_newline {
				document = cons(document, newline(1))
			}

			set_source_position(p, v.else_stmt.pos)

			if else_on_newline {
				document = cons(document, cons_with_nopl(text("else"), visit_stmt(p, v.else_stmt)))
			} else {
				// rols: a one-line `else` chain block breaks with the then-block
				saved := pair_else_chain(p, paired, v.body, v.else_stmt)
				document = cons_with_opl(document, cons_with_nopl(text("else"), visit_stmt(p, v.else_stmt)))
				p.else_chain = saved
			}


		}
		if !p.config.convert_do {
			document = enforce_fit_if_do(v.body, document)
		}
	case ^ast.Switch_Stmt:
		if v.partial {
			document = cons(document, text("#partial"), break_with_no_newline())
		}

		if v.label != nil {
			document = cons(document, visit_expr(p, v.label), text(":"), break_with_space())
		}

		document = cons(document, text("switch"))

		if v.init != nil {
			document = cons_with_opl(document, visit_stmt(p, v.init))
			document = cons(document, text(";"))
		}

		document = cons_with_opl(document, visit_expr(p, v.cond))
		set_source_position(p, v.body.pos)
		document = cons_with_nopl(document, visit_stmt(p, v.body, .Switch_Stmt))
		set_source_position(p, v.body.end)
	case ^ast.Case_Clause:
		document = cons(document, text("case"))


		if v.list != nil && len(v.list) > 0 {
			options: List_Options = {.Add_Comma}

			// rols: a comment that starts where the last expression ends belongs to the terminator, not the list
			list_end := v.list[len(v.list) - 1].end
			list_end.offset -= 1
			if contains_comments_in_range(p, v.list[0].pos, list_end) {
				options |= {.Enforce_Newline}
			}

			document = cons_with_nopl(document, align(group(visit_exprs(p, v.list, options))))
			// rols: a block comment between the last expression and the terminator stays on the clause line
			trailing_comment, _ := visit_comments(p, v.terminator.pos)
			document = cons(document, trailing_comment)
		}

		document = cons(document, text(v.terminator.text))

		if count := len(v.body); count > 0 {
			set_source_position(p, v.body[0].pos)
			if count == 1 && p.config.inline_single_stmt_case {
				document = group(nest(cons_with_opl(document, nest(visit_stmt(p, v.body[0])))))
			} else {
				document = cons(document, nest(cons(newline(1), visit_block_stmts(p, v.body))))
			}
		}
	case ^ast.Type_Switch_Stmt:
		if v.partial {
			document = cons(document, text("#partial"), break_with_no_newline())
		}

		if v.label != nil {
			document = cons(document, visit_expr(p, v.label), text(":"), break_with_space())
		}

		document = cons(document, text("switch"))
		document = cons_with_nopl(document, visit_stmt(p, v.tag, .Switch_Stmt))
		document = cons_with_nopl(document, visit_stmt(p, v.body, .Switch_Stmt))
	case ^ast.Assign_Stmt:
		assign_document: ^Document

		//If the switch contains `switch in v`
		if exprs_contain_empty_idents(v.lhs) && block_type == .Switch_Stmt {
			assign_document = cons(document, text("_"), break_with_space(), text(v.op.text))
		} else {
			assign_document = cons(
				document,
				group(cons(visit_exprs(p, v.lhs, {.Add_Comma, .Glue}), cons(text(" "), text(v.op.text)))),
			)
		}

		rhs := visit_exprs(p, v.rhs, {.Add_Comma}, .Assignment_Stmt)
		if is_values_nestable_assign(v.rhs) {
			document = group(nest(cons_with_opl(assign_document, group(rhs))))
		} else if is_values_nestable_if_break_assign(v.rhs) {
			document = cons(
				assign_document,
				group(nest(break_with_space()), Document_Group_Options{id = "assignments"}),
			)
			document = cons(document, nest_if_break(group(rhs), "assignments"))
			document = group(document)
		} else {
			document = group(cons_with_nopl(assign_document, group(rhs)))
		}
	case ^ast.Expr_Stmt:
		document = cons(document, visit_expr(p, v.expr))
	case ^ast.For_Stmt:
		if v.label != nil {
			document = cons(document, visit_expr(p, v.label), text(":"), break_with_space())
		}

		for_document := text("for")

		if v.init != nil {
			set_source_position(p, v.init.pos)
			for_document = cons_with_nopl(for_document, cons(group(visit_stmt(p, v.init)), text(";")))
		} else if v.post != nil {
			for_document = cons_with_nopl(for_document, text(";"))
		}

		if v.cond != nil {
			set_source_position(p, v.cond.pos)
			for_document = cons(
				for_document,
				v.init != nil ? break_with_space() : break_with_no_newline(),
				group(visit_expr(p, v.cond)),
			)
		}

		if v.post != nil {
			set_source_position(p, v.post.pos)
			for_document = cons(for_document, text(";"))
			// rols: a block comment before the post statement on its line leads it, since the `;` before it is already printed
			above, leading, _ := visit_comments_split(p, v.post.pos, code_between = true)
			for_document = cons_with_opl(for_document, cons(above, leading, group(visit_stmt(p, v.post))))
		} else if v.post == nil && v.cond != nil && v.init != nil {
			for_document = cons(for_document, text(";"))
		}

		document = cons(document, group(hang(4, for_document)))

		set_source_position(p, v.body.pos)
		document = cons_with_nopl(document, visit_stmt(p, v.body))
		set_source_position(p, v.body.end)

		if !p.config.convert_do {
			document = enforce_fit_if_do(v.body, document)
		}
	case ^ast.Unroll_Range_Stmt:
		if v.label != nil {
			document = cons(document, visit_expr(p, v.label), text(":"), break_with_space())
		}

		document = cons(document, text("#unroll"))
		document = cons_with_nopl(document, text("for"))

		document = cons_with_nopl(document, visit_expr(p, v.val0))

		if v.val1 != nil {
			document = cons(document, cons_with_opl(text(","), visit_expr(p, v.val1)))
		}

		document = cons_with_nopl(document, text("in"))

		document = cons_with_nopl(document, visit_expr(p, v.expr))

		set_source_position(p, v.body.pos)
		document = cons_with_nopl(document, visit_stmt(p, v.body))
		set_source_position(p, v.body.end)

		if !p.config.convert_do {
			document = enforce_fit_if_do(v.body, document)
		}
	case ^ast.Range_Stmt:
		if v.label != nil {
			document = cons(document, visit_expr(p, v.label), text(":"), break_with_space())
		}

		if v.reverse {
			document = cons(document, text("#reverse"), break_with_no_newline())
		}

		range_document := text("for")

		if v.init != nil {
			range_document = cons(range_document, break_with_space(), visit_stmt(p, v.init), text(";"))
		}

		if len(v.vals) >= 1 {
			range_document = cons_with_opl(range_document, visit_expr(p, v.vals[0]))
		}

		if len(v.vals) >= 2 {
			for val in v.vals[1:] {
				range_document = cons(range_document, cons_with_opl(text(","), visit_expr(p, val)))
			}
		}

		range_document = cons_with_opl(range_document, text("in"))

		range_document = cons_with_opl(range_document, visit_expr(p, v.expr))

		// Newlines in a range-loop header trigger semicolon insertion and turn the
		// header into invalid Odin, so it must remain on one physical line.
		document = cons(document, enforce_fit(range_document))

		set_source_position(p, v.body.pos)
		document = cons_with_nopl(document, visit_stmt(p, v.body))
		set_source_position(p, v.body.end)

		if !p.config.convert_do {
			document = enforce_fit_if_do(v.body, document)
		}
	case ^ast.Return_Stmt:
		if v.results == nil {
			document = cons(document, text("return"))
			break
		}

		if is_values_return_stmt_callable(v.results) {
			result := v.results[0]

			if paren, is_paren := result.derived.(^ast.Paren_Expr); is_paren {
				result = paren.expr
			}

			document = cons(text("return"), if_break("("), break_with(" "), visit_expr(p, result))

			document = nest(document)
			document = group(cons(document, if_break(" \\"), break_with(""), if_break(")")))
		} else {
			document = cons(document, text("return"))

			if is_return_stmt_ending_with_comp_lit_expr(v.results) {
				document = cons(
					document,
					text(" "),
					visit_exprs(p, v.results, {.Add_Comma}),
				)
			} else if !is_return_stmt_ending_with_call_expr(v.results) {
				document = cons_with_nopl(document, group(nest(visit_exprs(p, v.results, {.Add_Comma, .Group}))))
			} else {
				document = cons_with_nopl(document, visit_exprs(p, v.results, {.Add_Comma}))
			}
		}
	case ^ast.Defer_Stmt:
		document = cons(document, text("defer"))
		document = cons_with_nopl(document, visit_stmt(p, v.stmt))
	case ^ast.When_Stmt:
		// rols: the body of a paired `else when` breaks with the block before it
		chained := v.body == p.else_chain.target
		document = cons(document, cons_with_nopl(text("when"), visit_expr(p, v.cond)))
		// rols: the fit check of the block before a paired `else when` measures this header flat
		if chained {
			document = group(document, Document_Group_Options{rest_flat = true})
		}

		set_source_position(p, v.body.pos)
		// rols: a one-line then-block that pairs with its `else` block takes a chain group, even with one statement
		paired := pairs_with_else(p, v.body, v.else_stmt, chained)
		if paired {
			p.chain_then = v.body
		}
		document = cons_with_nopl(document, visit_stmt(p, v.body))
		set_source_position(p, v.body.end)

		if v.else_stmt != nil {
			// A `do` body has no closing brace, so an `else` on the same line is not valid Odin.
			// If_Stmt already does this.
			else_on_newline :=
				p.config.brace_style == .Allman ||
				p.config.brace_style == .Stroustrup ||
				(!p.config.convert_do && block_uses_do(v.body))
			if else_on_newline {
				document = cons(document, newline(1))
			}

			set_source_position(p, v.else_stmt.pos)

			if else_on_newline {
				document = cons(document, cons_with_nopl(text("else"), visit_stmt(p, v.else_stmt)))
			} else {
				// rols: a one-line `else` chain block breaks with the then-block
				saved := pair_else_chain(p, paired, v.body, v.else_stmt)
				document = cons_with_nopl(document, cons_with_nopl(text("else"), visit_stmt(p, v.else_stmt)))
				p.else_chain = saved
			}
		}

		if !p.config.convert_do {
			document = enforce_fit_if_do(v.body, document)
		}
	case ^ast.Branch_Stmt:
		document = cons(document, text(v.tok.text))

		if v.label != nil {
			document = cons_with_nopl(document, visit_expr(p, v.label))
		}
	case:
		log.error(stmt.derived)
		p.errored_out = true
		return nil
	}

	set_source_position(p, stmt.end)

	return cons(comments, document)
}

@(private)
should_align_comp_lit :: proc(p: ^Printer, comp_lit: ast.Comp_Lit) -> bool {
	if len(comp_lit.elems) == 0 {
		return false
	}

	for expr in comp_lit.elems {
		if field, ok := expr.derived.(^ast.Field_Value); ok {
			#partial switch v in field.value.derived {
			case ^ast.Proc_Type, ^ast.Proc_Lit:
				return false
			}
		}
	}

	return true
}

@(private)
comp_lit_contains_fields :: proc(comp_lit: ast.Comp_Lit) -> bool {

	if len(comp_lit.elems) == 0 {
		return false
	}

	for expr in comp_lit.elems {
		if _, ok := expr.derived.(^ast.Field_Value); ok {
			return true
		}
	}

	return false
}

@(private)
comp_lit_contains_blocks :: proc(p: ^Printer, comp_lit: ast.Comp_Lit) -> bool {
	if len(comp_lit.elems) == 0 {
		return false
	}

	for expr in comp_lit.elems {
		if field, ok := expr.derived.(^ast.Field_Value); ok {
			#partial switch v in field.value.derived {
			case ^ast.Proc_Type, ^ast.Proc_Lit:
				return true
			}
		}
	}

	return false
}

@(private)
contains_comments_in_range :: proc(p: ^Printer, pos: tokenizer.Pos, end: tokenizer.Pos) -> bool {
	for i := p.latest_comment_index; i < len(p.comments); i += 1 {
		for c in p.comments[i].list {
			if pos.offset <= c.pos.offset && c.pos.offset <= end.offset {
				return true
			}
		}
	}
	return false
}

@(private)
contains_do_in_expression :: proc(p: ^Printer, expr: ^ast.Expr) -> bool {
	found_do := false

	visit_fn :: proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
		if node == nil {
			return nil
		}

		found_do := cast(^bool)visitor.data
		if block, ok := node.derived.(^ast.Block_Stmt); ok {
			if block.uses_do == true {
				found_do^ = true
			}
		}

		return visitor
	}

	visit := ast.Visitor {
		data  = &found_do,
		visit = visit_fn,
	}

	ast.walk(&visit, expr)

	return found_do
}

@(private)
visit_where_clauses :: proc(p: ^Printer, clauses: []^ast.Expr) -> ^Document {
	if len(clauses) == 0 {
		return empty()
	}

	return nest(cons_with_nopl(text("where"), visit_exprs(p, clauses, {.Add_Comma, .Enforce_Newline})))
}

@(private)
visit_poly_params :: proc(p: ^Printer, poly_params: ^ast.Field_List) -> ^Document {
	if poly_params != nil {
		return cons(text("("), visit_signature_list(p, poly_params, true, false), text(")"))
	} else {
		return empty()
	}
}

@(private)
visit_expr :: proc(
	p: ^Printer,
	expr: ^ast.Expr,
	called_from: Expr_Called_Type = .Generic,
	options := List_Options{},
) -> ^Document {
	if expr == nil {
		return empty()
	}

	set_source_position(p, expr.pos)

	defer {
		set_source_position(p, expr.end)
	}

	// rols: a block comment before the expression on its line leads it, since nothing prints between them
	above, leading, _ := visit_comments_split(p, expr.pos, code_between = true)
	comments := cons(above, leading)
	document := empty()

	#partial switch v in expr.derived {
	case ^ast.Asm_Template:
		// TODO: new `asm` syntax support
		document = text(p.src[v.pos.offset:v.end.offset])
	case ^ast.Undef:
		document = text("---")
	case ^ast.Auto_Cast:
		document = cons_with_nopl(text_token(p, v.op), visit_expr(p, v.expr))
	case ^ast.Ternary_If_Expr:
		if v.op1.text == "if" {
			document = cons(
				group(visit_expr(p, v.x)),
				if_break(" \\"),
				break_with_space(),
				text_token(p, v.op1),
				break_with_no_newline(),
				group(visit_expr(p, v.cond)),
				if_break(" \\"),
				break_with_space(),
				text_token(p, v.op2),
				break_with_no_newline(),
				group(visit_expr(p, v.y)),
			)
		} else {
			document = cons(
				group(visit_expr(p, v.cond)),
				if_break(" \\"),
				break_with_space(),
				text_token(p, v.op1),
				break_with_no_newline(),
				group(visit_expr(p, v.x)),
				if_break(" \\"),
				break_with_space(),
				text_token(p, v.op2),
				break_with_no_newline(),
				group(visit_expr(p, v.y)),
			)
		}
		//Temp enforce fit until we figure out whether the issue is with Odin's parser.
		document = enforce_fit(group(document))
	case ^ast.Ternary_When_Expr:
		document = visit_expr(p, v.x)
		document = cons_with_nopl(document, text_token(p, v.op1))
		document = cons_with_nopl(document, visit_expr(p, v.cond))
		document = cons_with_nopl(document, text_token(p, v.op2))
		document = cons_with_nopl(document, visit_expr(p, v.y))
	case ^ast.Or_Else_Expr:
		document = visit_expr(p, v.x)
		document = cons_with_nopl(document, text_token(p, v.token))
		document = cons_with_nopl(document, visit_expr(p, v.y))
	case ^ast.Or_Branch_Expr:
		document = visit_expr(p, v.expr)
		document = cons_with_nopl(document, text_token(p, v.token))
		document = cons_with_nopl(document, visit_expr(p, v.label))
	case ^ast.Or_Return_Expr:
		document = cons_with_nopl(visit_expr(p, v.expr), text_token(p, v.token))
	case ^ast.Selector_Call_Expr:
		document = visit_expr(p, v.call)
	case ^ast.Ellipsis:
		document = cons(text(".."), visit_expr(p, v.expr))
	case ^ast.Relative_Type:
		document = cons_with_opl(visit_expr(p, v.tag), visit_expr(p, v.type))
	case ^ast.Slice_Expr:
		document = visit_expr(p, v.expr)
		document = cons(visit_expr(p, v.expr), text("["), visit_expr(p, v.low), text(v.interval.text))

		if v.high != nil {
			document = cons(document, visit_expr(p, v.high))
		}
		document = cons(document, text("]"))
	case ^ast.Ident:
		document = text_position(p, v.name, v.pos)
	case ^ast.Deref_Expr:
		document = cons(visit_expr(p, v.expr), text_token(p, v.op))
	case ^ast.Type_Cast:
		document = cons(text_token(p, v.tok), text("("), visit_expr(p, v.type), text(")"), visit_expr(p, v.expr))
	case ^ast.Basic_Directive:
		document = cons(text_token(p, v.tok), text_position(p, v.name, v.pos))
	case ^ast.Distinct_Type:
		document = cons_with_opl(text_position(p, "distinct", v.pos), visit_expr(p, v.type))
	case ^ast.Dynamic_Array_Type:
		document = cons(visit_expr(p, v.tag), document, text("["), text("dynamic"), text("]"), visit_expr(p, v.elem))
	case ^ast.Fixed_Capacity_Dynamic_Array_Type:
		document = cons(visit_expr(p, v.tag), document, text("["), text("dynamic"), text(";"))
		document = cons_with_opl(document, visit_expr(p, v.capacity))
		document = cons(document, text("]"), visit_expr(p, v.elem))
	case ^ast.Bit_Set_Type:
		document = cons(text_position(p, "bit_set", v.pos), document, text("["), visit_expr(p, v.elem))

		if v.underlying != nil {
			document = cons(document, cons(text(";"), visit_expr(p, v.underlying)))
		}

		document = cons(document, text("]"))
	case ^ast.Union_Type:
		document = cons(text_position(p, "union", v.pos), visit_poly_params(p, v.poly_params))

		#partial switch v.kind {
		case .no_nil:
			document = cons_with_opl(document, text("#no_nil"))
		case .shared_nil:
			document = cons_with_opl(document, text("#shared_nil"))
		}

		if v.align != nil {
			document = cons_with_nopl(document, text("#align"))
			document = cons(document, visit_expr(p, v.align))
		}

		document = cons_with_nopl(document, visit_where_clauses(p, v.where_clauses))

		if len(v.variants) == 0 {
			document = cons_with_nopl(document, text("{"))
			document = cons(document, text("}"))
		} else {
			// rols: pass the closing brace so the Indent option stays inside the braces
			document = cons_with_nopl(document, visit_begin_brace(p, v.pos, .Generic, v.end))
			set_source_position(p, v.variants[0].pos)
			document = cons(
				document,
				nest(
					cons(
						newline_position(p, 1, v.pos),
						visit_union_exprs(p, v^, {.Add_Comma, .Trailing, .Enforce_Newline}),
					),
				),
			)
			set_source_position(p, v.end)

			document = cons(document, newline(1), text_position(p, "}", v.end))
		}
	case ^ast.Enum_Type:
		document = text_position(p, "enum", v.pos)

		if v.base_type != nil {
			document = cons_with_nopl(document, visit_expr(p, v.base_type))
		}

		if len(v.fields) == 0 {
			document = cons_with_nopl(document, text("{"))
			document = cons(document, text("}"))
		} else {
			// rols: pass the closing brace so the Indent option stays inside the braces
			document = cons(document, break_with_space(), visit_begin_brace(p, v.pos, .Generic, v.end))
			set_source_position(p, v.fields[0].pos)
			document = cons(
				document,
				nest(
					cons(
						newline_position(p, 1, v.open),
						visit_enum_exprs(p, v^, {.Add_Comma, .Trailing, .Enforce_Newline}),
					),
				),
			)
			set_source_position(p, v.end)

			document = cons(document, newline(1), text_position(p, "}", v.end))
		}

		set_source_position(p, v.end)
	case ^ast.Struct_Type:
		document = text_position(p, "struct", v.pos)

		if v.poly_params != nil {
			document = cons(document, text("("))
			document = cons(
				document,
				nest(cons(break_with(""), visit_signature_list(p, v.poly_params, false, false, options))),
			)
			document = cons(document, break_with(""), text(")"))
		} else {
			document = cons(document, empty())
		}

		if v.is_packed {
			document = cons_with_nopl(document, text("#packed"))
		}

		if v.is_raw_union {
			document = cons_with_nopl(document, text("#raw_union"))
		}

		if v.is_no_copy {
			document = cons_with_nopl(document, text("#no_copy"))
		}

		if v.is_all_or_none {
			document = cons_with_nopl(document, text("#all_or_none"))
		}

		if v.is_simple {
			document = cons_with_nopl(document, text("#simple"))
		}

		if v.align != nil {
			document = cons_with_nopl(document, text("#align"))
			document = cons_with_nopl(document, visit_expr(p, v.align))
		}

		if v.max_field_align != nil {
			document = cons_with_nopl(document, text("#max_field_align"))
			document = cons(document, visit_expr(p, v.max_field_align))
		}

		if v.min_field_align != nil {
			document = cons_with_nopl(document, text("#min_field_align"))
			document = cons(document, visit_expr(p, v.min_field_align))
		}

		document = cons_with_nopl(document, visit_where_clauses(p, v.where_clauses))


		if v.fields != nil && len(v.fields.list) == 0 {
			if called_from == .Generic {
				document = cons(document, text("{"))
			} else {
				document = cons_with_nopl(document, text("{"))
			}

			if contains_comments_in_range(p, v.pos, v.end) {
				comments, _ := visit_comments(p, v.end)
				document = cons(document, nest(comments), newline(1), text("}"))
			} else {
				document = cons(document, visit_struct_field_list(p, v.fields, {.Add_Comma}), text("}"))
			}
		} else if v.fields != nil {
			// rols: pass the closing brace so the Indent option stays inside the braces
			document = cons(document, break_with_no_newline(), visit_begin_brace(p, v.pos, .Generic, v.end))

			set_source_position(p, v.fields.pos)
			document = cons(
				document,
				nest(
					cons(
						newline_position(p, 1, v.fields.open),
						group(visit_struct_field_list(p, v.fields, {.Add_Comma, .Trailing, .Enforce_Newline})),
					),
				),
			)
			set_source_position(p, v.fields.end)

			document = cons(document, newline(1), text_position(p, "}", v.end))
		}

		set_source_position(p, v.end)
	case ^ast.Bit_Field_Type:
		document = text_position(p, "bit_field", v.pos)

		document = cons_with_nopl(document, visit_expr(p, v.backing_type))

		if len(v.fields) == 0 {
			document = cons_with_nopl(document, text("{"))
			document = cons(document, text("}"))
		} else {
			// rols: pass the closing brace so the Indent option stays inside the braces
			document = cons(document, break_with_space(), visit_begin_brace(p, v.pos, .Generic, v.end))
			set_source_position(p, v.fields[0].pos)
			document = cons(
				document,
				nest(
					cons(
						newline_position(p, 1, v.open),
						visit_bit_field_fields(p, v^, {.Add_Comma, .Trailing, .Enforce_Newline}),
					),
				),
			)
			set_source_position(p, v.end)

			document = cons(document, newline(1), text_position(p, "}", v.end))
		}

		set_source_position(p, v.end)
	case ^ast.Proc_Lit:
		switch v.inlining {
		case .None:
		case .Inline:
			document = cons(document, text("#force_inline"))
		case .No_Inline:
			document = cons(document, text("#force_no_inline"))
		}

		document = cons_with_nopl(document, visit_proc_type(p, v.type^, v.body != nil, len(v.where_clauses) > 0))

		document = cons_with_nopl(document, visit_where_clauses(p, v.where_clauses))

		document = group(document)

		document = cons(document, visit_proc_tags(p, v.tags))

		if v.body != nil {
			set_source_position(p, v.body.pos)
			document = cons_with_nopl(document, group(visit_stmt(p, v.body, .Proc)))
		} else {
			document = cons_with_nopl(document, text("---"))
		}
	case ^ast.Proc_Type:
		document = group(visit_proc_type(p, v^, false, false))
	case ^ast.Basic_Lit:
		document = text_token(p, v.tok)
	case ^ast.Binary_Expr:
		document = visit_binary_expr(p, v^)
	case ^ast.Implicit_Selector_Expr:
		document = cons(text("."), text_position(p, v.field.name, v.field.pos))
	case ^ast.Call_Expr:
		switch v.inlining {
		case .None:
		case .Inline:
			document = cons(document, text("#force_inline"), break_with_no_newline())
		case .No_Inline:
			document = cons(document, text("#force_no_inline"), break_with_no_newline())
		}

		document = cons(document, visit_expr(p, v.expr), text("("))

		contains_comments := contains_comments_in_range(p, v.open, v.close)
		contains_do := false

		if !p.config.convert_do {
			for arg in v.args {
				contains_do |= contains_do_in_expression(p, arg)
			}
		}

		if is_call_expr_nestable(v.args) {
			document = cons(document, nest(cons(break_with(""), visit_call_exprs(p, v))))
		} else {
			document = cons(document, nest_if_break(cons(break_with(""), visit_call_exprs(p, v)), "call_expr"))
		}

		document = cons(document, break_with(""), text(")"))

		//Binary expression are nested on operators, and therefore undo the nesting in the call expression.
		if called_from == .Binary_Expr {
			document = escape_nest(document)
		}

		//We enforce a break if comments exists inside the call args
		if contains_comments {
			document = enforce_break(document, Document_Group_Options{id = "call_expr"})
		} else if contains_do {
			document = enforce_fit(document)
		} else {
			document = group(document, Document_Group_Options{id = "call_expr"})
		}
	case ^ast.Typeid_Type:
		document = text("typeid")

		if v.specialization != nil {
			document = cons(document, text("/"), visit_expr(p, v.specialization))
		}
	case ^ast.Selector_Expr:
		document = enforce_fit(cons(visit_expr(p, v.expr), text_token(p, v.op), visit_expr(p, v.field)))
	case ^ast.Paren_Expr:
		document = group(cons(text("("), nest(visit_expr(p, v.expr)), text(")")))
	case ^ast.Index_Expr:
		//Switch back to enforce fit, it just doesn't look good when breaking.
		document = enforce_fit(
			cons(
				visit_expr(p, v.expr),
				text("["),
				nest(cons(break_with("", true), group(visit_expr(p, v.index)), if_break(" \\"))),
				break_with("", true),
				text("]"),
			),
		)
	case ^ast.Proc_Group:
		document = text_token(p, v.tok)

		if len(v.args) != 0 {
			// rols: pass the closing brace so the Indent option stays inside the braces
			document = cons_with_nopl(document, visit_begin_brace(p, v.pos, .Generic, v.end))
			set_source_position(p, v.args[0].pos)
			document = cons(
				document,
				nest(
					cons(
						newline_position(p, 1, v.args[0].pos),
						visit_exprs(p, v.args, {.Add_Comma, .Trailing, .Enforce_Newline}),
					),
				),
			)
			document = cons(document, visit_end_brace(p, v.end, 1))
		} else {
			document = cons(document, text("{"), visit_exprs(p, v.args, {.Add_Comma}), text("}"))
		}
	case ^ast.Comp_Lit:
		if v.tag != nil {
			document = cons_with_nopl(document, visit_expr(p, v.tag))
		}

		if v.type != nil {
			document = cons_with_nopl(document, group(visit_expr(p, v.type)))

			if matrix_type, ok := v.type.derived.(^ast.Matrix_Type);
			   ok && is_matrix_type_constant(matrix_type) && is_matrix_filled_comp_lit(matrix_type, v) {
				// rols: as in the general case below, only a comment inside the braces takes the Indent option
				_, matrix_indent_was_set := p.comments_option[v.pos.line]
				// rols: pass the closing brace so the Indent option stays inside the braces
				document = cons(document, visit_begin_brace(p, v.pos, .Comp_Lit, v.end))

				set_source_position(p, v.open)
				document = cons(
					document,
					nest(cons(newline_position(p, 1, v.elems[0].pos), visit_matrix_comp_lit(p, matrix_type, v))),
				)
				set_source_position(p, v.end)

				document = cons(document, newline(1), text_position(p, "}", v.end))
				if !matrix_indent_was_set {
					delete_key(&p.comments_option, v.pos.line)
				}

				break
			}
		}

		should_newline := comp_lit_contains_fields(v^)

		should_newline &=
			(called_from == .Value_Decl ||
				called_from == .Assignment_Stmt ||
				(called_from == .Call_Expr && comp_lit_contains_blocks(p, v^)))
		should_newline &= len(v.elems) != 0

		should_newline |= contains_comments_in_range(p, v.pos, v.end)

		should_newline |= p.config.multiline_composite_literals && len(v.elems) > 0 && v.open.line != v.close.line

		if should_newline {
			// rols: only a comment inside the braces takes the Indent option, not one after the closing brace
			_, indent_was_set := p.comments_option[v.pos.line]
			// rols: pass the closing brace so the Indent option stays inside the braces
			document = cons_with_nopl(document, visit_begin_brace(p, v.pos, .Comp_Lit, v.end))
			inner_document := empty()
			if len(v.elems) > 0 {
				// rols: a block comment before the first element on its line leads it
				above, leading, width := visit_comments_split(p, v.elems[0].pos)
				inner_document = cons(
					above,
					newline(1),
					leading,
					visit_comp_lit_exprs(p, v^, {.Add_Comma, .Trailing, .Enforce_Newline}, width),
				)
			} else {
				inner_document, _ = visit_comments(p, v.end)
			}
			document = cons(document, nest(inner_document), newline(1), text_position(p, "}", v.end))
			// rols: drop the option when no comment inside the braces consumed it
			if !indent_was_set {
				delete_key(&p.comments_option, v.pos.line)
			}
		} else {
			break_string := " " if v.type != nil else ""
			if len(v.elems) > 0 {
				document = cons(
					document,
					group(
						cons(
							if_break(break_string),
							text("{"),
							nest(cons(break_with(""), visit_exprs(p, v.elems, {.Add_Comma, .Group}))),
							if_break(","),
							break_with(""),
							text("}"),
						),
					),
				)
			} else {
				document = cons(document, cons(text("{"), text("}")))
			}
			document = group(document)
		}
	case ^ast.Unary_Expr:
		document = cons(text_token(p, v.op), visit_expr(p, v.expr))
	case ^ast.Field_Value:
		document = cons_with_nopl(
			visit_expr(p, v.field),
			cons_with_nopl(text_position(p, "=", v.sep), visit_expr(p, v.value)),
		)
	case ^ast.Type_Assertion:
		document = visit_expr(p, v.expr)

		if unary, ok := v.type.derived.(^ast.Unary_Expr); ok && unary.op.text == "?" {
			document = cons(document, text("."), visit_expr(p, v.type))
		} else {
			document = cons(document, text("."), text("("), visit_expr(p, v.type), text(")"))
		}
	case ^ast.Pointer_Type:
		document = cons(visit_expr(p, v.tag), text("^"), visit_expr(p, v.elem))
	case ^ast.Multi_Pointer_Type:
		document = cons(text("[^]"), visit_expr(p, v.elem))
	case ^ast.Implicit:
		document = text_token(p, v.tok)
	case ^ast.Poly_Type:
		document = cons(text("$"), visit_expr(p, v.type))

		if v.specialization != nil {
			document = cons(document, text("/"), visit_expr(p, v.specialization))
		}
	case ^ast.Array_Type:
		document = cons(visit_expr(p, v.tag), text("["), visit_expr(p, v.len), text("]"), visit_expr(p, v.elem))
	case ^ast.Map_Type:
		document = cons(text("map"), text("["), visit_expr(p, v.key), text("]"), visit_expr(p, v.value))
	case ^ast.Helper_Type:
		if v.tok == .Hash {
			document = cons(document, text("#type"))
		}
		document = cons_with_nopl(document, visit_expr(p, v.type))
	case ^ast.Matrix_Type:
		document = cons(text_position(p, "matrix", v.pos), text("["), visit_expr(p, v.row_count), text(","))
		document = cons_with_opl(document, visit_expr(p, v.column_count))
		document = cons(document, text("]"))
		document = cons(group(document), visit_expr(p, v.elem))
	case ^ast.Tag_Expr:
		document = cons(text(v.op.text), text(v.name), break_with_no_newline(), visit_expr(p, v.expr))
	case ^ast.Matrix_Index_Expr:
		document = cons(visit_expr(p, v.expr), text("["), visit_expr(p, v.row_index), text(","))
		document = cons_with_opl(document, visit_expr(p, v.column_index))
		document = cons(document, text("]"))
	case:
		log.error(expr.derived)
		p.errored_out = true
		return nil
	}

	return cons(comments, document)
}

@(private)
is_matrix_type_constant :: proc(matrix_type: ^ast.Matrix_Type) -> bool {
	if row_count, is_lit := matrix_type.row_count.derived.(^ast.Basic_Lit); is_lit {
		_, ok := strconv.parse_int(row_count.tok.text)
		return ok
	}

	if column_count, is_lit := matrix_type.column_count.derived.(^ast.Basic_Lit); is_lit {
		_, ok := strconv.parse_int(column_count.tok.text)
		return ok
	}

	return false
}

@(private)
is_matrix_filled_comp_lit :: proc(matrix_type: ^ast.Matrix_Type, comp_lit: ^ast.Comp_Lit) -> bool {
	//these values have already been validated
	row_count, _ := strconv.parse_int(matrix_type.row_count.derived.(^ast.Basic_Lit).tok.text)
	column_count, _ := strconv.parse_int(matrix_type.column_count.derived.(^ast.Basic_Lit).tok.text)

	if row_count * column_count > len(comp_lit.elems) {
		return false
	}
	return true
}

@(private)
visit_matrix_comp_lit :: proc(p: ^Printer, matrix_type: ^ast.Matrix_Type, comp_lit: ^ast.Comp_Lit) -> ^Document {
	document := empty()
	row_count, _ := strconv.parse_int(matrix_type.row_count.derived.(^ast.Basic_Lit).tok.text)
	column_count, _ := strconv.parse_int(matrix_type.column_count.derived.(^ast.Basic_Lit).tok.text)

	if row_count * column_count > len(comp_lit.elems) {
		p.errored_out = true
		return document
	}

	for row := 0; row < row_count; row += 1 {
		for column := 0; column < column_count; column += 1 {
			document = cons(document, visit_expr(p, comp_lit.elems[column + row * column_count]))
			if column_count - 1 != column {
				document = cons(document, text(", "))
			} else {
				document = cons(document, text(","))
			}
		}

		if row_count - 1 != row {
			document = cons(document, newline(1))
		}
	}

	return document
}


@(private)
// rols: the closing brace position limits the Indent option
visit_begin_brace :: proc(p: ^Printer, begin: tokenizer.Pos, type: Block_Type, end := tokenizer.Pos{}) -> ^Document {
	set_source_position(p, begin)
	set_comment_option(p, begin.line, .Indent)
	// rols: the Indent option is for a comment inside the braces, so remember where the closing brace is
	if end.offset > 0 {
		p.comments_option_limit[begin.line] = max(p.comments_option_limit[begin.line], end.offset)
	}

	newline_braced := p.config.brace_style == .Allman
	newline_braced |= p.config.brace_style == .K_And_R && type == .Proc
	newline_braced &= p.config.brace_style != ._1TBS

	if newline_braced {
		if type == .Comp_Lit {
			return cons(text("\\"), newline(1), text("{"))
		}
		return cons(newline(1), text("{"))
	}

	return text("{")
}

@(private)
visit_end_brace :: proc(p: ^Printer, end: tokenizer.Pos, limit := 0) -> ^Document {
	if limit == 0 {
		// rols: a comment before `}` keeps upstream's placement, so it skips move_line_leading
		l, _ := move_line_limit(p, end, p.config.newline_limit + 1)
		return cons(l, text("}"))
	} else {
		document, newlined := move_line_limit(p, end, limit)
		if !newlined {
			return cons(document, newline(1), text("}"))
		} else {
			return cons(document, text("}"))
		}
	}
}

@(private)
// rols: chain_id names the group of a one-line block that may break
visit_block_stmts :: proc(p: ^Printer, stmts: []^ast.Stmt, chain_id := "") -> ^Document {
	document := empty()
	// rols: `run` holds the current source line of `;` joined statements, so a `; ` group never holds an earlier line
	run := empty()

	for stmt, i in stmts {
		last_index := max(0, i - 1)
		joined := stmts[last_index].end.line == stmt.pos.line && i != 0 && stmt.pos.line not_in p.disabled_lines
		// rols: a new line ends the run. The newline before a run of `;` joined statements stays outside its groups, so a fit check of its first `; ` measures the line
		next_on_line := i + 1 < len(stmts) && stmts[i + 1].pos.line == stmt.end.line
		if !joined {
			document = cons(document, run)
			run = empty()
			if chain_id == "" && next_on_line && stmt.pos.line not_in p.disabled_lines {
				document = cons(document, move_line(p, stmt_start(stmt)))
			}
		}
		// rols: adjacent backtick tokens with no `;` between them (the ``` raw string quirk) stay glued; inside a broken one-line block each statement gets its own line
		glued := joined && stmts[last_index].end.offset == stmt.pos.offset && p.src[stmt.pos.offset] == '`'
		// rols: the last one-line statement of a plain `;` chain sits inside the group of its `; ` break, see below
		fit_stmt := p.force_statement_fit && !contains_comments_in_range(p, stmt.pos, stmt.end)
		last_one_line := !fit_stmt && joined && stmt.pos.line == stmt.end.line && !next_on_line
		semi_id := ""
		if joined && !glued && chain_id != "" {
			run = cons(run, if_break_or(newline(1), text("; "), chain_id))
		} else if joined && !glued && last_one_line {
			semi_id = fmt.aprintf("semi@%d", stmt.pos.offset, allocator = p.allocator)
		} else if joined && !glued {
			run = group(cons(run, break_with("; ")))
		}

		stmt_document: ^Document
		// rols: a foreign procedure with a comment inside needs its own lines, so it cannot be forced onto one
		// the last one-line statement of a `;` chain stays in one piece, so the group before it measures all of it,
		// but in a broken one-line block or after a broken `; ` it may wrap, as it would on a line of its own
		if fit_stmt {
			stmt_document = enforce_fit(visit_stmt(p, stmt, .Generic, false, true))
		} else if last_one_line {
			stmt_document = visit_stmt(p, stmt, .Generic, false, true)
			if semi_id != "" {
				stmt_document = if_break_or(stmt_document, enforce_fit(stmt_document), semi_id)
				run = group(cons(run, break_with("; "), stmt_document), Document_Group_Options{id = semi_id})
				continue
			}
			stmt_document = chain_id != "" ? if_break_or(stmt_document, enforce_fit(stmt_document), chain_id) : enforce_fit(stmt_document)
		} else if joined && !glued && chain_id == "" && next_on_line {
			// rols: a middle statement of a `;` chain sits in the rest of the `; ` group before it, which measures it in full
			stmt_document = group(visit_stmt(p, stmt, .Generic, false, true), Document_Group_Options{rest_flat = true})
		} else {
			stmt_document = visit_stmt(p, stmt, .Generic, false, true)
		}

		run = cons(run, stmt_document)
	}

	return cons(document, run)
}

List_Option :: enum u8 {
	Add_Comma,
	Trailing,
	Enforce_Newline,
	Group,
	Glue,
}

List_Options :: distinct bit_set[List_Option]

@(private)
visit_struct_field_list :: proc(p: ^Printer, list: ^ast.Field_List, options := List_Options{}) -> ^Document {
	document := empty()
	if list.list == nil {
		return document
	}

	// Declaration alignment (align_struct_declarations) takes precedence: it pads before the colon,
	// while field-type alignment pads after it.
	align_declarations := p.config.align_struct_declarations
	align_field_types := p.config.align_struct_fields && !align_declarations

	multiline_alignment_enabled := .Enforce_Newline in options && (align_field_types || align_declarations)

	section_name_width := 0
	// section_end is exclusive. Reaching it starts the next alignment group.
	section_end := 0

	// rols: the width of the block comments that lead the current field, which its alignment takes away
	leading_width := 0

	for field, i in list.list {
		align := empty()
		declaration_align := empty()

		p.source_position = field.pos

		// Initialize alignment for the first section and update it at each section boundary.
		if multiline_alignment_enabled && i == section_end {
			section_end = get_struct_field_alignment_section_end(p, list.list, i)
			section_name_width = get_max_struct_field_name_width(list.list[i:section_end])
		}

		// A field is neither a Decl nor a Stmt, so it reaches neither place that consults
		// disabled_lines and the region has to be emitted here. Its text already carries the
		// source's indentation, hence escape_nest and the trim of the first line.
		if info, disabled := p.disabled_lines[field.pos.line]; disabled && info.text != "" {
			if p.disabled_until_line > field.pos.line {
				continue // already emitted by an earlier iteration
			}
			p.disabled_until_line = info.end_line
			p.source_position = field.end
			p.source_position.line = info.end_line
			// rols: the region can start on an earlier line than the field, as in visit_disabled
			document = cons(document, escape_nest(text(strings.trim_left(disabled_region_text(p, info, field.pos), " \t"))))
			if i != len(list.list) - 1 {
				document = cons(document, newline(1))
			}
			continue
		}

		if i == 0 && .Enforce_Newline in options {
			// rols: a block comment before the first field on its line leads the field and its flags
			comment, leading: ^Document
			comment, leading, leading_width = visit_comments_split(p, field_start(p, list.list[i]))
			if _, is_nil := comment.(Document_Nil); !is_nil {
				comment = cons(comment, newline(1))
			}
			document = cons(comment, document, leading)
		}

		if .Using in field.flags {
			document = cons(document, text("using"), break_with_no_newline())
		}

		if .Subtype in field.flags {
			document = cons(document, text("#subtype"), break_with_no_newline())
		}

		name_options := List_Options{.Add_Comma}

		if (.Enforce_Newline in options) {
			if align_field_types && section_name_width > 0 {
				// rols: a leading block comment counts toward the name's width
				align = repeat_space(section_name_width - get_struct_field_name_width(field) - leading_width)
			}

			if align_declarations && section_name_width > 0 {
				// rols: a leading block comment counts toward the name's width
				name_width := get_struct_field_name_width(field) + leading_width
				if name_width > 0 && name_width < section_name_width {
					declaration_align = repeat_space(section_name_width - name_width)
				}
			}

			document = cons(document, visit_exprs(p, field.names, name_options))
		} else {
			document = cons_with_opl(document, visit_exprs(p, field.names, name_options))
		}

		if field.type != nil {
			if len(field.names) != 0 {
				document = cons(
					document,
					declaration_align,
					text(" :" if p.config.spaces_around_colons else ":"),
					align,
				)
			}
			document = cons_with_nopl(document, visit_expr(p, field.type))
		} else {
			document = cons(document, declaration_align, text(":"), text("="))
			document = cons_with_opl(document, visit_expr(p, field.default_value))
		}

		if field.tag.text != "" {
			document = cons_with_nopl(document, text_token(p, field.tag))
		}

		if (i != len(list.list) - 1 || .Trailing in options) && .Add_Comma in options {
			document = cons(document, text(","))
		}

		if i != len(list.list) - 1 && .Enforce_Newline in options {
			if p.config.preserve_struct_blank_lines {
				// rols: the field starts at its first flag
				document = cons(document, move_line(p, field_start(p, list.list[i + 1])))
				leading_width = 0
			} else {
				// rols: a block comment before the next field on its line leads that field and its flags
				comment, leading: ^Document
				comment, leading, leading_width = visit_comments_split(p, field_start(p, list.list[i + 1]))
				document = cons(document, comment, newline(1), leading)
			}
		} else {
			comment, _ := visit_comments(p, list.end)
			document = cons(document, comment)
		}
	}
	return document
}

@(private)
visit_proc_tags :: proc(p: ^Printer, proc_tags: ast.Proc_Tags) -> ^Document {
	document := empty()

	if .Bounds_Check in proc_tags {
		document = cons_with_opl(document, text("#bounds_check"))
	}

	if .No_Bounds_Check in proc_tags {
		document = cons_with_opl(document, text("#no_bounds_check"))
	}

	if .Optional_Ok in proc_tags {
		document = cons_with_opl(document, text("#optional_ok"))
	}

	if .Optional_Allocator_Error in proc_tags {
		document = cons_with_opl(document, text("#optional_allocator_error"))
	}

	return group(cons_with_nopl(if_break("\\"), document))
}

@(private)
visit_proc_type :: proc(
	p: ^Printer,
	proc_type: ast.Proc_Type,
	contains_body: bool,
	contains_where_clauses: bool,
) -> ^Document {
	document := text("proc")

	explicit_calling := false

	if v, ok := proc_type.calling_convention.(string); ok {
		explicit_calling = true
		document = cons_with_nopl(document, text(v))
	}

	if explicit_calling {
		document = cons_with_nopl(document, text("("))
	} else {
		document = cons(document, text("("))
	}

	contain_comments := contains_comments_in_range(p, proc_type.pos, proc_type.end)

	options: List_Options

	if contain_comments {
		options |= {.Enforce_Newline}
	}

	document = cons(
		document,
		nest(
			cons(
				len(proc_type.params.list) > 0 ? break_with("") : empty(),
				visit_signature_list(p, proc_type.params, true, false, options),
			),
		),
	)
	document = cons(document, break_with(""), text(")"))

	if proc_type.results != nil && len(proc_type.results.list) > 0 {
		document = cons_with_nopl(document, text("-"))
		document = cons(document, text(">"))

		use_parens := false
		can_multiline_single := false

		if len(proc_type.results.list) > 1 {
			use_parens = true
		} else if len(proc_type.results.list) == 1 {
			for name in proc_type.results.list[0].names {
				if ident, ok := name.derived.(^ast.Ident); ok {
					if ident.name != "_" {
						use_parens = true
					}
				}
			}
			if proc_type.results.list[0].type != nil {
				if _, ok := proc_type.results.list[0].type.derived.(^ast.Proc_Type); ok {
					if contains_where_clauses {
						use_parens = true
					} else {
						can_multiline_single = true
					}
				}
			}
		}

		results_parens := text("(")
		results_parens = cons(
			results_parens,
			nest(cons(break_with(""), visit_signature_list(p, proc_type.results, true, true))),
		)
		results_parens = cons(results_parens, break_with(""), text(")"))

		if use_parens {
			document = cons_with_nopl(document, results_parens)
		} else {
			results_no_parens := nest(group(visit_signature_list(p, proc_type.results, contains_body, true)))
			if can_multiline_single {
				document = cons_with_nopl(document, if_break_or_document(results_parens, results_no_parens))
			} else {
				document = cons_with_nopl(document, results_no_parens)
			}
		}
	} else if proc_type.diverging {
		document = cons_with_nopl(document, text("-"))
		document = cons(document, text(">"))
		document = cons_with_nopl(document, text("!"))
	}

	if contain_comments {
		return enforce_break(document)
	}

	return document
}


@(private)
visit_binary_expr :: proc(p: ^Printer, binary: ast.Binary_Expr, nested := false) -> ^Document {
	document := empty()

	nest_expression := false

	if binary.left != nil {
		if b, ok := binary.left.derived.(^ast.Binary_Expr); ok {
			pa := parser.Parser {
				allow_in_expr = true,
			}
			nest_expression = parser.token_precedence(&pa, b.op.kind) != parser.token_precedence(&pa, binary.op.kind)
			document = cons(document, visit_binary_expr(p, b^, nest_expression))
		} else {
			document = cons(document, visit_expr(p, binary.left, nested ? .Binary_Expr : .Generic))
		}
	}

	if nest_expression {
		document = nest(document)
		document = group(document)
	}

	document = cons_with_nopl(document, text(binary.op.text))

	// rols: a line comment on the operator's line is the trailing comment of that line, not of the right operand's line
	if binary.right != nil && comment_before_position(p, binary.right.pos) {
		cg := p.comments[p.latest_comment_index]
		first := cg.list[0]
		if len(cg.list) == 1 &&
		   first.pos.line == binary.op.pos.line &&
		   strings.has_prefix(first.text, "//") &&
		   first.pos.line not_in p.disabled_lines {
			document = cons(document, line_suffix(first.text, alignable = true))
			p.source_position = first.pos
			next_comment_group(p)
		}
	}

	// rols: comments on their own lines between the operator and the right operand keep those lines
	if binary.right != nil && comment_before_position(p, binary.right.pos) &&
	   p.comments[p.latest_comment_index].pos.line > binary.op.pos.line {
		p.source_position = binary.op.pos
		comments, _ := visit_comments(p, binary.right.pos)
		right := binary.right
		if b, ok := right.derived.(^ast.Binary_Expr); ok {
			return cons(document, comments, newline(1), group(nest(visit_binary_expr(p, b^, true))))
		}
		return cons(document, comments, newline(1), group(nest(visit_expr(p, right, .Binary_Expr))))
	}

	if binary.right != nil {
		if b, ok := binary.right.derived.(^ast.Binary_Expr); ok {
			document = cons_with_opl(document, group(nest(visit_binary_expr(p, b^, true))))
		} else {
			document = cons_with_opl(document, group(nest(visit_expr(p, binary.right, .Binary_Expr))))
		}
	}

	return document
}

@(private)
visit_call_exprs :: proc(p: ^Printer, call_expr: ^ast.Call_Expr) -> ^Document {
	document := empty()

	ellipsis := call_expr.ellipsis.kind == .Ellipsis


	for expr, i in call_expr.args {
		if call_expr.ellipsis.pos.offset <= expr.pos.offset && ellipsis {
			document = cons(document, text(".."))
			ellipsis = false
		}

		// rols: comments above the first argument stay above it
		if i == 0 && comment_before_position(p, expr.pos) && p.comments[p.latest_comment_index].pos.line < expr.pos.line {
			// the break after the opening parenthesis already starts the line of the first comment
			p.source_position.line = p.comments[p.latest_comment_index].pos.line
			p.source_position.column = 1
			// rols: a block comment on the line of the first argument leads it
			comments, leading, _ := visit_comments_split(p, expr.pos)
			document = cons(document, comments, newline(1), leading)
		}

		document = cons(document, group(visit_expr(p, expr, .Call_Expr)))

		if i != len(call_expr.args) - 1 {
			document = cons(document, text(","))

			//need to look for comments before we write the comma with break
			// rols: a block comment before the next argument on its line leads that argument
			comments, leading, _ := visit_comments_split(p, call_expr.args[i + 1].pos)

			document = cons(document, comments, break_with_space(), leading)
		} else {
			comments, _ := visit_comments(p, call_expr.close)
			document = cons(document, if_break(","), comments)
		}

	}
	return document
}

@(private)
visit_signature_field_flag :: proc(p: ^Printer, flags: ast.Field_Flags) -> ^Document {
	document := empty()

	if .Any_Int in flags {
		document = cons_with_nopl(document, text("#any_int"))
	}

	if .C_Vararg in flags {
		document = cons_with_nopl(document, text("#c_vararg"))
	}

	if .No_Alias in flags {
		document = cons_with_nopl(document, text("#no_alias"))
	}

	if .Subtype in flags {
		document = cons_with_nopl(document, text("#subtype"))
	}

	if .By_Ptr in flags {
		document = cons_with_nopl(document, text("#by_ptr"))
	}

	if .Using in flags {
		document = cons_with_nopl(document, text("using"))
	}

	if .No_Broadcast in flags {
		document = cons_with_nopl(document, text("#no_broadcast"))
	}

	if .No_Capture in flags {
		document = cons_with_nopl(document, text("#no_capture"))
	}

	return document
}

@(private)
visit_signature_list :: proc(
	p: ^Printer,
	list: ^ast.Field_List,
	contains_body: bool,
	remove_blank: bool,
	options := List_Options{},
) -> ^Document {
	document := empty()

	for field, i in list.list {
		// rols: a comment above the first field stays above it, and a block comment on its line stays before it
		if i == 0 && .Enforce_Newline in options {
			// the caller already broke the line, so each comment starts on the current one
			for comment_before_position(p, field.pos) {
				for comment in p.comments[p.latest_comment_index].list {
					// only a block comment can sit before the field on its line
					above := comment.pos.line < field.pos.line
					document = cons(document, text(comment.text), above ? newline(1) : text(" "))
					p.source_position = comment.pos
					p.source_position.line += strings.count(comment.text, "\n")
				}
				next_comment_group(p)
			}
		}
		p.source_position = field.pos

		document = cons(document, visit_signature_field(p, field, remove_blank))

		if i != len(list.list) - 1 {
			if .Enforce_Newline in options {
				document = cons(document, text(","))
			} else {
				document = cons(document, text(","), break_with_space())
			}
		} else {
			if .Enforce_Newline not_in options {
				document = len(list.list) > 1 || contains_body ? cons(document, if_break(",")) : document
			} else {
				document = cons(document, text(","))
			}

		}

		if (i != len(list.list) - 1 && .Enforce_Newline in options) {
			// rols: a block comment before the next field on its line leads that field and its flags
			comment, leading, _ := visit_comments_split(p, field_start(p, list.list[i + 1]))
			document = cons(document, comment, newline(1), leading)
		} else if .Enforce_Newline in options {
			comment, _ := visit_comments(p, list.list[i].end)
			document = cons(document, comment)
		}
	}

	comment, _ := visit_comments(p, list.end)
	document = cons(document, comment)

	return document
}

@(private)
visit_signature_field :: proc(p: ^Printer, field: ^ast.Field, remove_blank := true) -> ^Document {
	document := empty()
	flag := visit_signature_field_flag(p, field.flags)

	named := false

	for name in field.names {
		if ident, ok := name.derived.(^ast.Ident); ok {
			//for some reason the parser uses _ to mean empty
			if ident.name != "_" || !remove_blank {
				named = true
			}
		} else {
			//alternative is poly names
			named = true
		}
	}

	if named {
		document = cons(document, cons_with_nopl(flag, visit_exprs(p, field.names, {.Add_Comma})))

		if len(field.names) != 0 && field.type != nil {
			document = cons(document, text(" :" if p.config.spaces_around_colons else ":"), break_with_no_newline())
		}
	}

	if field.type != nil && field.default_value != nil {
		document = cons(document, visit_expr(p, field.type))
		document = cons_with_nopl(document, text("="))
		document = cons_with_nopl(document, visit_expr(p, field.default_value))
	} else if field.type != nil {
		document = cons(document, visit_expr(p, field.type))
	} else {
		document = cons_with_nopl(document, text(":"))
		document = cons(document, text("="))
		document = cons_with_nopl(document, visit_expr(p, field.default_value))
	}
	return group(document)
}

@(private)
repeat_space :: proc(amount: int) -> ^Document {
	document := empty()
	for i := 0; i < amount; i += 1 {
		document = cons(document, break_with_no_newline())
	}
	return document
}

@(private)
get_node_length :: proc(node: ^ast.Node) -> int {
	#partial switch v in node.derived {
	case ^ast.Ident:
		return strings.rune_count(v.name)
	case ^ast.Basic_Lit:
		return strings.rune_count(v.tok.text)
	case ^ast.Implicit_Selector_Expr:
		return strings.rune_count(v.field.name) + 1
	case ^ast.Binary_Expr:
		return 0
	case ^ast.Paren_Expr:
		return 1 + get_node_length(v.expr) + 1
	case ^ast.Pointer_Type:
		return 1 + get_node_length(v.elem)
	case ^ast.Selector_Expr:
		return get_node_length(v.expr) + strings.rune_count(v.op.text) + strings.rune_count(v.field.name)
	case:
		return 0
	}
}

@(private)
struct_fields_have_blank_line_between :: proc(previous, next: ^ast.Field) -> bool {
	last_occupied_line := previous.end.line

	if previous.comment != nil {
		last_occupied_line = max(last_occupied_line, previous.comment.end.line)
	}

	if next.docs != nil {
		if next.docs.pos.line > last_occupied_line + 1 {
			return true
		}

		last_occupied_line = max(last_occupied_line, next.docs.end.line)
	}

	return next.pos.line > last_occupied_line + 1
}

@(private)
get_struct_field_alignment_section_end :: proc(p: ^Printer, fields: []^ast.Field, start: int) -> int {
	if !p.config.preserve_struct_blank_lines {
		return len(fields)
	}

	// With a zero limit, source blank lines are collapsed in the output. They must
	// not reset alignment when there is no visible section break.
	if p.config.newline_limit <= 0 {
		return len(fields)
	}

	end := start + 1
	for end < len(fields) && !struct_fields_have_blank_line_between(fields[end - 1], fields[end]) {
		end += 1
	}

	return end
}

@(private)
get_struct_field_name_width :: proc(field: ^ast.Field) -> int {
	width := 0
	for name, i in field.names {
		width += get_node_length(name)
		if i < len(field.names) - 1 {
			width += 2 // ", "
		}
	}

	if .Using in field.flags {
		width += 6 // "using "
	}
	if .Subtype in field.flags {
		width += 9 // "#subtype "
	}

	return width
}

@(private)
get_max_struct_field_name_width :: proc(fields: []^ast.Field) -> int {
	longest_name := 0

	for field in fields {
		longest_name = max(longest_name, get_struct_field_name_width(field))
	}

	return longest_name
}

@(private)
get_possible_comp_lit_alignment :: proc(exprs: []^ast.Expr) -> int {
	longest_name := 0

	for expr in exprs {
		value, is_field_value := expr.derived.(^ast.Field_Value)

		if !is_field_value {
			return 0
		}

		if comp, is_comp := value.value.derived.(^ast.Comp_Lit); is_comp {
			if comp_lit_contains_fields(comp^) {
				return 0
			}
		}

		longest_name = max(longest_name, get_node_length(value.field))
	}

	return longest_name
}

@(private)
get_possible_enum_alignment :: proc(exprs: []^ast.Expr) -> int {
	longest_name := 0

	for expr in exprs {
		value, ok := expr.derived.(^ast.Field_Value)

		if !ok {
			return 0
		}

		longest_name = max(longest_name, get_node_length(value.field))
	}

	return longest_name
}

@(private)
get_possible_bit_field_alignment :: proc(fields: []^ast.Bit_Field_Field) -> (longest_name: int, longest_type: int) {
	for field in fields {
		longest_name = max(longest_name, get_node_length(field.name))
		longest_type = max(longest_type, get_node_length(field.type))
	}

	return
}
