#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"

@(private = "package")
add_extract_variable_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_extract_variable {
		return
	}

	function := ctx.position_context.function
	if function == nil || function.body == nil {
		return
	}

	src := ctx.document.ast.src
	start, end := trim_range(src, ctx.range.start, ctx.range.end)

	list, found := find_stmt_list_at(function.body, start, end)
	if !found || list.first != list.last {
		return
	}
	stmt := list.stmts[list.first]
	if stmt.pos.offset > start || end > stmt.end.offset {
		return
	}

	expr, chain, ok := find_expr(stmt, start, end)
	if !ok || !extractable(stmt, expr, chain) {
		return
	}

	name := pick_name(ctx, expr)

	line_start := stmt.pos.offset
	for line_start > 0 && src[line_start - 1] != '\n' {
		line_start -= 1
	}

	edits := make([]TextEdit, 2, context.temp_allocator)
	edits[0] = TextEdit {
		range   = range_of(ctx, line_start, line_start),
		newText = strings.concatenate(
			{get_line_indentation(src, stmt.pos.offset), name, " := ", src[expr.pos.offset:expr.end.offset], "\n"},
			context.temp_allocator,
		),
	}
	edits[1] = TextEdit {
		range   = range_of(ctx, expr.pos.offset, expr.end.offset),
		newText = name,
	}

	append(ctx.actions, make_code_action(ctx, "Extract variable", "refactor.extract", edits))
}

// Expressions that produce a value on their own. Literals and parenthesized expressions only count
// when selected, since the cursor alone should pick the operation around them.
is_value_expr :: proc(node: ^ast.Node, selected: bool) -> bool {
	#partial switch n in node.derived {
	case ^ast.Call_Expr,
	     ^ast.Selector_Expr,
	     ^ast.Selector_Call_Expr,
	     ^ast.Binary_Expr,
	     ^ast.Index_Expr,
	     ^ast.Matrix_Index_Expr,
	     ^ast.Slice_Expr,
	     ^ast.Deref_Expr,
	     ^ast.Ternary_If_Expr,
	     ^ast.Or_Else_Expr,
	     ^ast.Type_Cast,
	     ^ast.Auto_Cast,
	     ^ast.Type_Assertion:
		return true
	case ^ast.Unary_Expr:
		return n.expr != nil
	case ^ast.Comp_Lit:
		return n.type != nil
	case ^ast.Paren_Expr, ^ast.Basic_Lit:
		return selected
	}
	return false
}

// The selected expression (exact match) or the innermost value expression under the cursor, with
// its ancestors from stmt down to its parent.
find_expr :: proc(stmt: ^ast.Stmt, start, end: int) -> (expr: ^ast.Expr, chain: []^ast.Node, ok: bool) {
	Data :: struct {
		start, end: int,
		stack:      [dynamic]^ast.Node,
		expr:       ^ast.Expr,
		chain:      []^ast.Node,
	}

	data := Data {
		start = start,
		end   = end,
		stack = make([dynamic]^ast.Node, context.temp_allocator),
	}

	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil {
				pop(&data.stack)
				return nil
			}
			if node.pos.offset > data.start || data.end > node.end.offset {
				return nil
			}

			selected := data.start != data.end
			if selected && data.expr != nil {
				return nil
			}
			exact := node.pos.offset == data.start && node.end.offset == data.end
			if (!selected || exact) && is_value_expr(node, selected) {
				data.expr = cast(^ast.Expr)node
				data.chain = slice.clone(data.stack[:], context.temp_allocator)
				if selected {
					return nil
				}
			}

			append(&data.stack, node)
			return visitor
		},
	}

	ast.walk(&visitor, stmt)
	return data.expr, data.chain, data.expr != nil
}

extractable :: proc(stmt: ^ast.Stmt, expr: ^ast.Expr, chain: []^ast.Node) -> bool {
	if len(chain) == 0 {
		return false
	}

	#partial switch p in chain[len(chain) - 1].derived {
	case ^ast.Value_Decl:
		if expr == p.type || slice.contains(p.names, expr) {
			return false
		}
		if len(p.values) == 1 && p.values[0] == expr {
			return false
		}
	case ^ast.Assign_Stmt:
		if slice.contains(p.lhs, expr) || (len(p.rhs) == 1 && p.rhs[0] == expr) {
			return false
		}
	case ^ast.Expr_Stmt, ^ast.Using_Stmt, ^ast.Selector_Call_Expr:
		return false
	case ^ast.Call_Expr:
		if expr == p.expr {
			return false
		}
	case ^ast.Comp_Lit:
		if expr == p.type {
			return false
		}
	case ^ast.Field_Value:
		if expr == p.field {
			return false
		}
	case ^ast.Type_Cast:
		if expr == p.type {
			return false
		}
	case ^ast.Type_Assertion:
		if expr == p.type {
			return false
		}
	case ^ast.Unary_Expr:
		if p.op.kind == .And {
			return false
		}
	}

	#partial switch s in stmt.derived {
	case ^ast.If_Stmt:
		if s.init != nil {
			return false
		}
	case ^ast.Switch_Stmt:
		if s.init != nil {
			return false
		}
	case ^ast.Value_Decl:
		if !s.is_mutable {
			return false
		}
	case ^ast.When_Stmt,
	     ^ast.Defer_Stmt,
	     ^ast.For_Stmt,
	     ^ast.Range_Stmt,
	     ^ast.Unroll_Range_Stmt,
	     ^ast.Type_Switch_Stmt,
	     ^ast.Using_Stmt:
		return false
	}

	// Below the statement, only the child on the path decides whether the expression is
	// evaluated conditionally. Any nested statement there is an else-if or a when branch.
	child: ^ast.Node = expr
	for i := len(chain) - 1; i > 0; i -= 1 {
		#partial switch p in chain[i].derived {
		case ^ast.Ternary_If_Expr:
			if child != p.cond {
				return false
			}
		case ^ast.Or_Else_Expr:
			if child == p.y {
				return false
			}
		case ^ast.Binary_Expr:
			if (p.op.kind == .Cmp_And || p.op.kind == .Cmp_Or) && child == p.right {
				return false
			}
		case ^ast.Ternary_When_Expr, ^ast.Proc_Lit, ^ast.If_Stmt, ^ast.Switch_Stmt, ^ast.When_Stmt:
			return false
		}
		child = chain[i]
	}
	return true
}

pick_name :: proc(ctx: ^ActionContext, expr: ^ast.Expr) -> string {
	base := "value"
	#partial switch e in expr.derived {
	case ^ast.Call_Expr:
		#partial switch callee in e.expr.derived {
		case ^ast.Ident:
			base = callee.name
		case ^ast.Selector_Expr:
			base = callee.field.name
		}
	case ^ast.Selector_Expr:
		base = e.field.name
	}

	probe: ast.Ident
	probe.pos = expr.pos
	probe.name = base
	for i := 2; is_taken(ctx, probe); i += 1 {
		probe.name = fmt.tprintf("%s%d", base, i)
	}
	return probe.name
}

is_taken :: proc(ctx: ^ActionContext, ident: ast.Ident) -> bool {
	if ident.name in ctx.ast_context.globals {
		return true
	}
	_, ok := get_local(ctx.ast_context^, ident)
	return ok
}
