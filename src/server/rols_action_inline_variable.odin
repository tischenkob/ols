#+private file

package server

import "core:odin/ast"
import "core:slice"
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

	// Inlining keeps behaviour only when the initializer still runs once, at the same point, or
	// when it has no side effects and reads nothing the code it moves past can change.
	typed := resolve_entire_file(ctx.document)
	if !evaluated_in_place(typed, function.body, decl, uses[:]) && !is_stable(typed, value) {
		return
	}

	// A use inside a loop that starts after the declaration sees writes made anywhere in that loop.
	check_end := last_use.end.offset
	for use in uses {
		for parent in use.parents {
			#partial switch _ in parent.derived {
			case ^ast.For_Stmt, ^ast.Range_Stmt, ^ast.Unroll_Range_Stmt:
				if decl.end.offset <= parent.pos.offset {
					check_end = max(check_end, parent.end.offset)
				}
			}
		}
	}

	// A local read by the initializer must keep its value up to the last use, and no pointer to it
	// may exist.
	for read in collect_ident_uses(value) {
		read_decl, ok := local_decl_offset(ctx, symbols, read.ident)
		if !ok {
			continue
		}
		for use in all_uses {
			offset, ok := local_decl_offset(ctx, symbols, use.ident)
			if !ok || offset != read_decl || !is_write(use) {
				continue
			}
			between := decl.end.offset <= use.ident.pos.offset && use.ident.pos.offset <= check_end
			if between || takes_address(use) {
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

// The single use sits in the statement right after the declaration, runs exactly once whenever
// that statement runs, and nothing evaluated before it in that statement calls or reads a variable.
evaluated_in_place :: proc(typed: SymbolAndNodeMap, body: ^ast.Stmt, decl: ^ast.Value_Decl, uses: []IdentUse) -> bool {
	if len(uses) != 1 {
		return false
	}
	use := uses[0]
	list, found := find_stmt_list_at(body, decl.pos.offset, decl.end.offset)
	if !found || list.first != list.last || len(list.stmts) <= list.first + 1 {
		return false
	}
	next := list.stmts[list.first + 1]
	#partial switch _ in next.derived {
	case ^ast.For_Stmt, ^ast.Range_Stmt, ^ast.Unroll_Range_Stmt, ^ast.Defer_Stmt:
		return false
	}

	inside_next := false
	for parent, i in use.parents {
		if parent == next {
			inside_next = true
			continue
		}
		if !inside_next {
			continue
		}
		child: ^ast.Node = i + 1 < len(use.parents) ? use.parents[i + 1] : use.ident
		#partial switch p in parent.derived {
		case ^ast.Block_Stmt,
		     ^ast.Case_Clause,
		     ^ast.If_Stmt,
		     ^ast.When_Stmt,
		     ^ast.Switch_Stmt,
		     ^ast.Type_Switch_Stmt,
		     ^ast.For_Stmt,
		     ^ast.Range_Stmt,
		     ^ast.Unroll_Range_Stmt,
		     ^ast.Defer_Stmt,
		     ^ast.Proc_Lit,
		     ^ast.Ternary_If_Expr,
		     ^ast.Ternary_When_Expr:
			return false
		case ^ast.Or_Else_Expr:
			if child == p.y {
				return false
			}
		case ^ast.Binary_Expr:
			if (p.op.kind == .Cmp_And || p.op.kind == .Cmp_Or) && child == p.right {
				return false
			}
		}
	}
	return inside_next && !reads_state(typed, next, use.ident.pos.offset, false)
}

// The initializer has no side effects and reads only locals, so the local write check covers
// every way the code it moves past could change its value.
is_stable :: proc(typed: SymbolAndNodeMap, value: ^ast.Expr) -> bool {
	return !reads_state(typed, value, max(int), true)
}

// Whether the part of root before offset limit calls, reads through an indirection, or reads a
// global variable. Locals count too unless allow_locals is set, except plain assignment targets.
reads_state :: proc(typed: SymbolAndNodeMap, root: ^ast.Node, limit: int, allow_locals: bool) -> bool {
	Data :: struct {
		typed: SymbolAndNodeMap,
		limit: int,
		found: bool,
	}

	data := Data {
		typed = typed,
		limit = limit,
	}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil || data.found || data.limit <= node.pos.offset {
				return nil
			}
			if data.limit < node.end.offset {
				return visitor
			}
			#partial switch n in node.derived {
			case ^ast.Call_Expr,
			     ^ast.Or_Return_Expr,
			     ^ast.Or_Else_Expr,
			     ^ast.Or_Branch_Expr,
			     ^ast.Deref_Expr,
			     ^ast.Index_Expr,
			     ^ast.Slice_Expr,
			     ^ast.Matrix_Index_Expr:
				data.found = true
				return nil
			case ^ast.Selector_Expr:
				base, is_ident := n.expr.derived.(^ast.Ident)
				if is_ident && is_variable(data.typed, base) || is_variable(data.typed, n) {
					data.found = true
					return nil
				}
			}
			return visitor
		},
	}
	ast.walk(&visitor, root)
	if data.found {
		return true
	}

	for use in collect_ident_uses(root) {
		if limit <= use.ident.pos.offset || !is_variable(typed, use.ident) {
			continue
		}
		if .Local not_in typed[uintptr(use.ident)].symbol.flags {
			return true
		}
		if !allow_locals && !is_plain_target(use) {
			return true
		}
	}
	return false
}

// Parameters count: one can be a pointer, and reads through it see writes made elsewhere.
is_variable :: proc(typed: SymbolAndNodeMap, node: ^ast.Node) -> bool {
	resolved, ok := typed[uintptr(node)]
	return ok && (.Mutable in resolved.symbol.flags || .Parameter in resolved.symbol.flags)
}

is_plain_target :: proc(use: IdentUse) -> bool {
	if len(use.parents) == 0 {
		return false
	}
	#partial switch p in use.parents[len(use.parents) - 1].derived {
	case ^ast.Assign_Stmt:
		return p.op.kind == .Eq && slice.contains(p.lhs, use.ident)
	case ^ast.Value_Decl:
		return slice.contains(p.names, use.ident)
	}
	return false
}

// `&x`, `&x.y` or `&x[i]`: a pointer to x can change it from anywhere.
takes_address :: proc(use: IdentUse) -> bool {
	target: rawptr = use.ident
	#reverse for parent in use.parents {
		base: rawptr
		#partial switch p in parent.derived {
		case ^ast.Selector_Expr:
			base = p.expr
		case ^ast.Index_Expr:
			base = p.expr
		case ^ast.Slice_Expr:
			base = p.expr
		case ^ast.Unary_Expr:
			return p.op.kind == .And && p.expr == target
		case ^ast.Using_Stmt:
			return true
		}
		if base != target {
			return false
		}
		target = parent
	}
	return false
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
