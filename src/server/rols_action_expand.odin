#+private file

package server

import "core:odin/ast"
import "core:strconv"
import "core:strings"

@(private = "package")
add_expand_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_expand {
		return
	}
	nodes := nodes_at(ctx.document.ast.decls[:], ctx.range.start)
	add_expand_array(ctx, nodes)
	add_expand_or_else(ctx, nodes)
	add_expand_or_return(ctx, nodes)
	add_c_style_for(ctx, nodes)
}

add_expand_array :: proc(ctx: ^ActionContext, nodes: []Node_At) {
	src := ctx.document.ast.src
	#reverse for at in nodes {
		type, value: ^ast.Expr
		#partial switch n in at.node.derived {
		case ^ast.Value_Decl:
			if len(n.names) != 1 || len(n.values) != 1 {
				return
			}
			type, value = n.type, n.values[0]
		case ^ast.Field:
			if len(n.names) != 1 {
				return
			}
			type, value = n.type, n.default_value
		case:
			continue
		}
		count, sized := array_len(type)
		if !sized || value == nil || !is_number_lit(value) {
			return
		}
		elem := node_text(src, value)
		sb := strings.builder_make(context.temp_allocator)
		strings.write_byte(&sb, '{')
		for i in 0 ..< count {
			strings.write_string(&sb, i == 0 ? "" : ", ")
			strings.write_string(&sb, elem)
		}
		strings.write_byte(&sb, '}')
		append_replace_range(ctx, value.pos.offset, value.end.offset, "Expand array literal", strings.to_string(sb))
		return
	}
}

// Length of `[N]T` for a literal N of at most 32 elements.
array_len :: proc(type: ^ast.Expr) -> (int, bool) {
	if type == nil {
		return 0, false
	}
	array, ok := type.derived.(^ast.Array_Type)
	if !ok || array.len == nil {
		return 0, false
	}
	lit, is_lit := array.len.derived.(^ast.Basic_Lit)
	if !is_lit || lit.tok.kind != .Integer {
		return 0, false
	}
	n, parsed := strconv.parse_int(lit.tok.text, 0)
	return n, parsed && 1 <= n && n <= 32
}

add_expand_or_else :: proc(ctx: ^ActionContext, nodes: []Node_At) {
	src := ctx.document.ast.src
	#reverse for at in nodes {
		fallback, ok := at.node.derived.(^ast.Or_Else_Expr)
		if !ok {
			continue
		}
		stmt := at.parent
		if stmt == nil {
			return
		}
		ind := get_line_indentation(src, stmt.pos.offset)
		unit := indent_unit(src, ind, nil)
		e := node_text(src, fallback.x)
		d := node_text(src, fallback.y)
		flag := fresh_name(ctx, "ok", stmt.pos)
		text: string
		#partial switch s in stmt.derived {
		case ^ast.Value_Decl:
			if !s.is_mutable || s.type != nil || len(s.names) != 1 || len(s.values) != 1 {
				return
			}
			x := node_text(src, s.names[0])
			text = strings.concatenate(
				{x, ", ", flag, " := ", e, "\n", ind, "if !", flag, " {\n", ind, unit, x, " = ", d, "\n", ind, "}"},
				context.temp_allocator,
			)
		case ^ast.Return_Stmt:
			if len(s.results) != 1 {
				return
			}
			v := fresh_name(ctx, "v", stmt.pos)
			text = strings.concatenate(
				{
					"if ",
					v,
					", ",
					flag,
					" := ",
					e,
					"; ",
					flag,
					" {\n",
					ind,
					unit,
					"return ",
					v,
					"\n",
					ind,
					"}\n",
					ind,
					"return ",
					d,
				},
				context.temp_allocator,
			)
		case ^ast.Assign_Stmt:
			if s.op.kind != .Eq || len(s.lhs) != 1 || len(s.rhs) != 1 {
				return
			}
			x := node_text(src, s.lhs[0])
			v := fresh_name(ctx, "v", stmt.pos)
			text = strings.concatenate(
				{
					"if ",
					v,
					", ",
					flag,
					" := ",
					e,
					"; ",
					flag,
					" {\n",
					ind,
					unit,
					x,
					" = ",
					v,
					"\n",
					ind,
					"} else {\n",
					ind,
					unit,
					x,
					" = ",
					d,
					"\n",
					ind,
					"}",
				},
				context.temp_allocator,
			)
		case:
			return
		}
		append_replace_range(ctx, stmt.pos.offset, stmt.end.offset, "Expand or_else", text)
		return
	}
}

add_expand_or_return :: proc(ctx: ^ActionContext, nodes: []Node_At) {
	function := ctx.position_context.function
	if function == nil {
		return
	}
	src := ctx.document.ast.src
	#reverse for at in nodes {
		wrap, ok := at.node.derived.(^ast.Or_Return_Expr)
		if !ok {
			continue
		}
		call, is_call := wrap.expr.derived.(^ast.Call_Expr)
		if !is_call || at.parent == nil {
			return
		}
		decl: ^ast.Value_Decl
		#partial switch s in at.parent.derived {
		case ^ast.Value_Decl:
			if !s.is_mutable || len(s.names) != 1 || len(s.values) != 1 {
				return
			}
			decl = s
		case ^ast.Expr_Stmt:
		case:
			return
		}

		resolved, is_resolved := resolve_entire_file(ctx.document)[uintptr(call.expr)]
		if !is_resolved {
			return
		}
		callee, is_proc := resolved.symbol.value.(SymbolProcedureValue)
		if !is_proc {
			return
		}
		results := field_types(callee.return_types)
		if len(results) == 0 {
			return
		}
		kind := result_kind(results[len(results) - 1])
		if kind == .Other {
			return
		}
		proc_results: []^ast.Expr
		if function.type != nil && function.type.results != nil {
			proc_results = field_types(function.type.results.list)
		}

		if decl == nil {
			stmt := at.parent
			name := fresh_name(ctx, kind == .Bool ? "ok" : "err", stmt.pos)
			ind := get_line_indentation(src, stmt.pos.offset)
			lhs := strings.builder_make(context.temp_allocator)
			for _ in 0 ..< len(results) - 1 {
				strings.write_string(&lhs, "_, ")
			}
			strings.write_string(&lhs, name)
			text := strings.concatenate(
				{
					strings.to_string(lhs),
					" := ",
					node_text(src, call),
					handle_result_if_text(ctx, name, kind, proc_results, true, ind),
				},
				context.temp_allocator,
			)
			append_replace_range(ctx, stmt.pos.offset, stmt.end.offset, "Expand or_return", text)
			return
		}

		edits := make([dynamic]TextEdit, context.temp_allocator)
		append(&edits, TextEdit{range = range_of(ctx, call.end.offset, wrap.end.offset)})
		more, _ := handle_result_edits(ctx, decl, kind, proc_results, true)
		append(&edits, ..more)
		append(ctx.actions, make_code_action(ctx, "Expand or_return", "refactor.rewrite", edits[:]))
		return
	}
}

add_c_style_for :: proc(ctx: ^ActionContext, nodes: []Node_At) {
	src := ctx.document.ast.src
	#reverse for at in nodes {
		loop, ok := at.node.derived.(^ast.Range_Stmt)
		if !ok {
			continue
		}
		if loop.reverse || loop.init != nil || loop.expr == nil || loop.body == nil || len(loop.vals) != 1 {
			return
		}
		name, is_ident := loop.vals[0].derived.(^ast.Ident)
		bounds, is_binary := loop.expr.derived.(^ast.Binary_Expr)
		if !is_ident || !is_binary {
			return
		}
		cmp: string
		#partial switch bounds.op.kind {
		case .Range_Half:
			cmp = "<"
		case .Range_Full:
			cmp = "<="
		case:
			return
		}
		lo, hi := node_text(src, bounds.left), node_text(src, bounds.right)
		text := strings.concatenate(
			{
				"for ",
				name.name,
				" := ",
				lo,
				"; ",
				name.name,
				" ",
				cmp,
				" ",
				hi,
				"; ",
				name.name,
				" += 1 ",
				do_keyword(loop.body),
			},
			context.temp_allocator,
		)
		append_replace_range(ctx, loop.for_pos.offset, loop.body.pos.offset, "Convert to C-style for", text)
		return
	}
}
