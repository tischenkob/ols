#+private file

package server

import "core:odin/ast"
import "core:strings"

import "src:common"

@(private = "package")
add_inline_variable_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_inline_variable {
		return
	}

	function := ctx.position_context.function
	decl := ctx.position_context.value_decl
	if function == nil || function.body == nil || decl == nil {
		return
	}
	if decl.pos.offset < function.body.pos.offset || function.body.end.offset < decl.end.offset {
		return
	}
	if len(decl.names) != 1 || len(decl.values) != 1 || decl.is_using || decl.type != nil {
		return
	}
	name, is_ident := decl.names[0].derived.(^ast.Ident)
	if !is_ident || name.name == "_" {
		return
	}
	if ctx.range.start < name.pos.offset || name.end.offset < ctx.range.start {
		return
	}
	value := decl.values[0]
	if _, is_proc := value.derived.(^ast.Proc_Lit); is_proc {
		return
	}

	src := ctx.document.ast.src
	if !alone_on_line(src, decl) {
		return
	}

	symbols := resolve_entire_file_for_references(ctx.document, context.temp_allocator, .Identifier, "")
	all_uses := collect_ident_uses(function.body)

	uses := make([dynamic]IdentUse, context.temp_allocator)
	for use in all_uses {
		if use.ident == name || use.ident.name != name.name {
			continue
		}
		if offset, ok := local_decl_offset(ctx, symbols, use.ident); ok && offset == name.pos.offset {
			if is_write(use) {
				return
			}
			append(&uses, use)
		}
	}
	if len(uses) == 0 {
		return
	}
	last_use := uses[len(uses) - 1].ident

	if has_side_effect(value) {
		if len(uses) != 1 {
			return
		}
		decl_list, _ := find_stmt_list_at(function.body, decl.pos.offset, decl.end.offset)
		use_list, _ := find_stmt_list_at(function.body, last_use.pos.offset, last_use.end.offset)
		if raw_data(decl_list.stmts) != raw_data(use_list.stmts) {
			return
		}
	}

	// A local read by the initializer must keep its value up to the last use.
	for read in collect_ident_uses(value) {
		read_decl, ok := local_decl_offset(ctx, symbols, read.ident)
		if !ok {
			continue
		}
		for use in all_uses {
			if use.ident.pos.offset < decl.end.offset || last_use.end.offset < use.ident.pos.offset {
				continue
			}
			if offset, ok := local_decl_offset(ctx, symbols, use.ident); ok && offset == read_decl && is_write(use) {
				return
			}
		}
	}

	text := src[value.pos.offset:value.end.offset]
	paren_text := strings.concatenate({"(", text, ")"}, context.temp_allocator)

	edits := make([dynamic]TextEdit, 0, len(uses) + 1, context.temp_allocator)
	append(&edits, delete_lines_edit(ctx, decl.pos.line - 1, decl.end.line - 1))
	for use in uses {
		append(
			&edits,
			TextEdit {
				range = range_of(ctx, use.ident.pos.offset, use.ident.end.offset),
				newText = needs_parens(value, use) ? paren_text : text,
			},
		)
	}

	append(ctx.actions, make_code_action(ctx, "Inline variable", "refactor.inline", edits[:]))
}

@(private = "package")
alone_on_line :: proc(src: string, decl: ^ast.Value_Decl) -> bool {
	for i := decl.pos.offset - 1; i >= 0 && src[i] != '\n'; i -= 1 {
		if src[i] != ' ' && src[i] != '\t' {
			return false
		}
	}
	for i := decl.end.offset; i < len(src) && src[i] != '\n'; i += 1 {
		if src[i] != ' ' && src[i] != '\t' {
			return strings.has_prefix(src[i:], "//")
		}
	}
	return true
}

@(private = "package")
has_side_effect :: proc(value: ^ast.Expr) -> bool {
	found: bool
	visitor := ast.Visitor {
		data = &found,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			#partial switch n in node.derived {
			case ^ast.Call_Expr, ^ast.Or_Return_Expr, ^ast.Or_Else_Expr, ^ast.Or_Branch_Expr:
				(^bool)(visitor.data)^ = true
				return nil
			}
			return visitor
		},
	}
	ast.walk(&visitor, value)
	return found
}

needs_parens :: proc(value: ^ast.Expr, use: IdentUse) -> bool {
	#partial switch v in value.derived {
	case ^ast.Binary_Expr,
	     ^ast.Ternary_If_Expr,
	     ^ast.Ternary_When_Expr,
	     ^ast.Or_Else_Expr,
	     ^ast.Unary_Expr,
	     ^ast.Type_Cast,
	     ^ast.Auto_Cast:
	case:
		return false
	}
	if len(use.parents) == 0 {
		return false
	}
	#partial switch p in use.parents[len(use.parents) - 1].derived {
	case ^ast.Binary_Expr,
	     ^ast.Unary_Expr,
	     ^ast.Selector_Expr,
	     ^ast.Index_Expr,
	     ^ast.Slice_Expr,
	     ^ast.Deref_Expr,
	     ^ast.Matrix_Index_Expr,
	     ^ast.Type_Assertion,
	     ^ast.Or_Return_Expr:
		return true
	case ^ast.Call_Expr:
		return p.expr == use.ident
	}
	return false
}
