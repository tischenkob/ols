#+private file

package server

import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"

@(private = "package")
add_rewrite_expression_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_rewrite_expression {
		return
	}

	roots := ctx.document.ast.decls[:]
	if function := ctx.position_context.function; function != nil && function.body != nil {
		roots = []^ast.Stmt{function.body}
	}
	nodes := nodes_at(roots, ctx.range.start)

	add_flip_comparison(ctx, nodes)
	add_de_morgan(ctx, nodes)
	add_compound_assignment(ctx, nodes)
}

add_flip_comparison :: proc(ctx: ^ActionContext, nodes: []Node_At) {
	src := ctx.document.ast.src
	#reverse for at in nodes {
		bin, ok := at.node.derived.(^ast.Binary_Expr)
		if !ok {
			continue
		}
		mirrored: string
		#partial switch bin.op.kind {
		case .Lt:
			mirrored = ">"
		case .Gt:
			mirrored = "<"
		case .Lt_Eq:
			mirrored = ">="
		case .Gt_Eq:
			mirrored = "<="
		case .Cmp_Eq, .Not_Eq:
			mirrored = bin.op.text
		case:
			continue
		}
		text := strings.concatenate(
			{node_text(src, bin.right), " ", mirrored, " ", node_text(src, bin.left)},
			context.temp_allocator,
		)
		append_replace_range(ctx, bin.left.pos.offset, bin.right.end.offset, "Flip comparison", text)
		return
	}
}

add_de_morgan :: proc(ctx: ^ActionContext, nodes: []Node_At) {
	src := ctx.document.ast.src
	#reverse for at in nodes {
		#partial switch n in at.node.derived {
		case ^ast.Unary_Expr:
			if n.op.kind != .Not || n.expr == nil {
				continue
			}
			bin, ok := unparen(n.expr).derived.(^ast.Binary_Expr)
			if !ok || (bin.op.kind != .Cmp_And && bin.op.kind != .Cmp_Or) {
				continue
			}
			sb := strings.builder_make(context.temp_allocator)
			for leaf, i in chain_leaves(bin, bin.op.kind) {
				if i > 0 {
					strings.write_string(&sb, " || " if bin.op.kind == .Cmp_And else " && ")
				}
				inverted, _ := invert_condition(src, leaf)
				strings.write_string(&sb, inverted)
			}
			text := strings.to_string(sb)
			if at.parent != nil {
				#partial switch _ in at.parent.derived {
				case ^ast.Binary_Expr, ^ast.Unary_Expr:
					text = strings.concatenate({"(", text, ")"}, context.temp_allocator)
				}
			}
			append_replace_range(ctx, n.pos.offset, n.end.offset, "Apply De Morgan's law", text)
			return

		case ^ast.Binary_Expr:
			if n.op.kind != .Cmp_And && n.op.kind != .Cmp_Or {
				continue
			}
			leaves := chain_leaves(n, n.op.kind)
			all_negated := true
			for leaf in leaves {
				not, ok := leaf.derived.(^ast.Unary_Expr)
				all_negated &&= ok && not.op.kind == .Not
			}
			if !all_negated {
				continue
			}
			sb := strings.builder_make(context.temp_allocator)
			strings.write_string(&sb, "!(")
			for leaf, i in leaves {
				if i > 0 {
					strings.write_string(&sb, " || " if n.op.kind == .Cmp_And else " && ")
				}
				strings.write_string(&sb, node_text(src, leaf.derived.(^ast.Unary_Expr).expr))
			}
			strings.write_byte(&sb, ')')
			append_replace_range(ctx, n.pos.offset, n.end.offset, "Apply De Morgan's law", strings.to_string(sb))
			return
		}
	}
}

add_compound_assignment :: proc(ctx: ^ActionContext, nodes: []Node_At) {
	src := ctx.document.ast.src
	#reverse for at in nodes {
		assign, ok := at.node.derived.(^ast.Assign_Stmt)
		if !ok {
			continue
		}
		if len(assign.lhs) != 1 || len(assign.rhs) != 1 || contains_call(assign.lhs[0]) {
			return
		}
		lhs := node_text(src, assign.lhs[0])
		rhs := assign.rhs[0]

		if assign.op.kind == .Eq {
			text, has_text := compound_assignment_text(src, assign)
			if !has_text {
				return
			}
			append_replace_range(ctx, assign.pos.offset, assign.end.offset, "Use compound assignment", text)
			return
		}

		if !(.B_Assign_Op_Begin < assign.op.kind && assign.op.kind < .B_Assign_Op_End) {
			return
		}
		op := strings.trim_suffix(assign.op.text, "=")
		// The tokenizer lists Add_Eq..Cmp_Or_Eq in the same order as Add..Cmp_Or.
		op_kind := tokenizer.Token_Kind(int(assign.op.kind) - int(tokenizer.Token_Kind.Add_Eq) + int(tokenizer.Token_Kind.Add))
		rhs_text := node_text(src, rhs)
		wrap := false
		#partial switch r in rhs.derived {
		case ^ast.Binary_Expr:
			wrap = binary_precedence(r.op.kind) <= binary_precedence(op_kind)
		case ^ast.Ternary_If_Expr, ^ast.Ternary_When_Expr, ^ast.Or_Else_Expr:
			wrap = true
		}
		if wrap {
			rhs_text = strings.concatenate({"(", rhs_text, ")"}, context.temp_allocator)
		}
		text := strings.concatenate({lhs, " = ", lhs, " ", op, " ", rhs_text}, context.temp_allocator)
		append_replace_range(ctx, assign.pos.offset, assign.end.offset, "Expand compound assignment", text)
		return
	}
}

@(private = "package")
compound_assignment_text :: proc(src: string, assign: ^ast.Assign_Stmt) -> (string, bool) {
	if assign.op.kind != .Eq || len(assign.lhs) != 1 || len(assign.rhs) != 1 || contains_call(assign.lhs[0]) {
		return "", false
	}
	bin, is_binary := assign.rhs[0].derived.(^ast.Binary_Expr)
	if !is_binary {
		return "", false
	}
	#partial switch bin.op.kind {
	case .Add, .Sub, .Mul, .Quo, .Mod, .Mod_Mod, .And, .Or, .Xor, .And_Not, .Shl, .Shr:
	case:
		return "", false
	}
	if _, is_paren := bin.left.derived.(^ast.Paren_Expr); is_paren {
		return "", false
	}
	lhs := node_text(src, assign.lhs[0])
	if strip_space(node_text(src, bin.left)) != strip_space(lhs) {
		return "", false
	}
	// A compound assignment applies the operator to the whole right side, so its parentheses go.
	right := node_text(src, unparen(bin.right))
	return strings.concatenate({lhs, " ", bin.op.text, "= ", right}, context.temp_allocator), true
}

// Operands of a chain of `op`, parentheses removed, in source order.
chain_leaves :: proc(expr: ^ast.Expr, op: tokenizer.Token_Kind, allocator := context.temp_allocator) -> []^ast.Expr {
	collect :: proc(expr: ^ast.Expr, op: tokenizer.Token_Kind, out: ^[dynamic]^ast.Expr) {
		e := unparen(expr)
		if bin, ok := e.derived.(^ast.Binary_Expr); ok && bin.op.kind == op {
			collect(bin.left, op, out)
			collect(bin.right, op, out)
			return
		}
		append(out, e)
	}
	out := make([dynamic]^ast.Expr, allocator)
	collect(expr, op, &out)
	return out[:]
}

@(private = "package")
unparen :: proc(expr: ^ast.Expr) -> ^ast.Expr {
	expr := expr
	for {
		paren, ok := expr.derived.(^ast.Paren_Expr)
		if !ok {
			return expr
		}
		expr = paren.expr
	}
}

// Mirrors token_precedence in core:odin/parser, which needs parser state.
binary_precedence :: proc(kind: tokenizer.Token_Kind) -> int {
	#partial switch kind {
	case .Question, .If, .When, .Or_Else:
		return 1
	case .Ellipsis, .Range_Half, .Range_Full:
		return 2
	case .Cmp_Or:
		return 3
	case .Cmp_And:
		return 4
	case .Cmp_Eq, .Not_Eq, .Lt, .Gt, .Lt_Eq, .Gt_Eq:
		return 5
	case .In, .Not_In, .Add, .Sub, .Or, .Xor:
		return 6
	case .Mul, .Quo, .Mod, .Mod_Mod, .And, .And_Not, .Shl, .Shr:
		return 7
	}
	return 0
}

@(private = "package")
contains_call :: proc(node: ^ast.Node) -> bool {
	found: bool
	visitor := ast.Visitor {
		data = &found,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			#partial switch _ in node.derived {
			case ^ast.Call_Expr, ^ast.Selector_Call_Expr:
				(^bool)(visitor.data)^ = true
				return nil
			}
			return visitor
		},
	}
	ast.walk(&visitor, node)
	return found
}
