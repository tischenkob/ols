package server

import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:slice"

import "src:common"

// Operators for which `x op x` is a mistake rather than an idiom.
@(private = "file")
identical_ops := [?]tokenizer.Token_Kind {
	.Cmp_Eq,
	.Not_Eq,
	.Lt,
	.Lt_Eq,
	.Gt,
	.Gt_Eq,
	.Cmp_And,
	.Cmp_Or,
	.Sub,
	.Quo,
	.Mod,
	.Xor,
	.Or,
	.And,
}

lint_bool_logic :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_bool_logic do return
	if node in ctx.skip do return

	#partial switch n in node.derived {
	case ^ast.Binary_Expr:
		if n.op.kind == .Cmp_And || n.op.kind == .Cmp_Or {
			members := bool_chain(ctx, n)
			bool_duplicate_member(ctx, n, members, diags)
			bool_tautology(ctx, n, members, diags)
		} else {
			bool_identical_operands(ctx, n, diags)
		}
	case ^ast.If_Stmt:
		bool_duplicate_condition(ctx, n, diags)
	case ^ast.Switch_Stmt:
		bool_duplicate_case(ctx, n, diags)
	}
}

// Operands of a chain of the same operator. The nested binaries are marked skipped so the
// walker's later visit of them does not report the same chain again.
@(private = "file")
bool_chain :: proc(ctx: ^LintContext, root: ^ast.Binary_Expr) -> []^ast.Expr {
	collect :: proc(ctx: ^LintContext, expr: ^ast.Expr, op: tokenizer.Token_Kind, out: ^[dynamic]^ast.Expr) {
		e := unparen(expr)
		if bin, ok := e.derived.(^ast.Binary_Expr); ok && bin.op.kind == op {
			ctx.skip[bin] = {}
			collect(ctx, bin.left, op, out)
			collect(ctx, bin.right, op, out)
			return
		}
		append(out, e)
	}
	out := make([dynamic]^ast.Expr, context.temp_allocator)
	collect(ctx, root.left, root.op.kind, &out)
	collect(ctx, root.right, root.op.kind, &out)
	return out[:]
}

@(private = "file")
bool_identical_operands :: proc(ctx: ^LintContext, bin: ^ast.Binary_Expr, diags: ^[dynamic]Diagnostic) {
	if !slice.contains(identical_ops[:], bin.op.kind) do return
	left, right := unparen(bin.left), unparen(bin.right)
	if !side_effect_free(left) || !side_effect_free(right) do return
	if !same_text(ctx.src, left, right) do return

	#partial switch bin.op.kind {
	case .Sub, .Quo, .Xor:
		// `1 - 1`, `x ~ x`: literal folding, not a typo.
		if _, is_lit := left.derived.(^ast.Basic_Lit); is_lit do return
	case .Cmp_Eq, .Not_Eq:
		// `x != x` is the NaN test.
		if is_float_operand(ctx, left) do return
	}

	append(diags, identical_operands_diagnostic(ctx, bin))
}

@(private = "file")
bool_duplicate_member :: proc(
	ctx: ^LintContext,
	root: ^ast.Binary_Expr,
	members: []^ast.Expr,
	diags: ^[dynamic]Diagnostic,
) {
	for i in 1 ..< len(members) {
		if !side_effect_free(members[i]) do continue
		for j in 0 ..< i {
			if !same_text(ctx.src, members[i], members[j]) do continue
			append(diags, identical_operands_diagnostic(ctx, root))
			return
		}
	}
}

@(private = "file")
identical_operands_diagnostic :: proc(ctx: ^LintContext, bin: ^ast.Binary_Expr) -> Diagnostic {
	return Diagnostic {
		range = common.get_token_range(bin, ctx.src),
		severity = .Warning,
		code = "identical-operands",
		message = fmt.tprintf("both sides of '%s' are the same expression", bin.op.text),
	}
}

@(private = "file")
bool_tautology :: proc(ctx: ^LintContext, root: ^ast.Binary_Expr, members: []^ast.Expr, diags: ^[dynamic]Diagnostic) {
	any_branch := root.op.kind == .Cmp_Or
	// `x != A || x != B` cannot be false; `x == A && x == B` cannot be true.
	cmp := tokenizer.Token_Kind.Not_Eq if any_branch else tokenizer.Token_Kind.Cmp_Eq

	for i in 1 ..< len(members) {
		for j in 0 ..< i {
			if !negates(ctx.src, members[i], members[j]) && !excludes(ctx.src, cmp, members[i], members[j]) {
				continue
			}
			append(
				diags,
				Diagnostic {
					range = common.get_token_range(root, ctx.src),
					severity = .Warning,
					code = "bool-tautology",
					message = "this expression is always true" if any_branch else "this expression is always false",
				},
			)
			return
		}
	}
}

// Two comparisons of the same expression against literals that cannot both hold.
@(private = "file")
excludes :: proc(src: string, op: tokenizer.Token_Kind, a, b: ^ast.Expr) -> bool {
	a_expr, a_lit, a_ok := comparison_to_literal(a, op)
	b_expr, b_lit, b_ok := comparison_to_literal(b, op)
	if !a_ok || !b_ok do return false
	return same_text(src, a_expr, b_expr) && !same_text(src, a_lit, b_lit)
}

@(private = "file")
comparison_to_literal :: proc(
	expr: ^ast.Expr,
	op: tokenizer.Token_Kind,
) -> (
	operand: ^ast.Expr,
	literal: ^ast.Expr,
	ok: bool,
) {
	bin := expr.derived.(^ast.Binary_Expr) or_return
	if bin.op.kind != op do return
	left, right := unparen(bin.left), unparen(bin.right)
	if _, is_lit := right.derived.(^ast.Basic_Lit); is_lit {
		return left, right, side_effect_free(left)
	}
	if _, is_lit := left.derived.(^ast.Basic_Lit); is_lit {
		return right, left, side_effect_free(right)
	}
	return
}

// One expression is the negation of the other.
@(private = "file")
negates :: proc(src: string, a, b: ^ast.Expr) -> bool {
	inverts :: proc(src: string, a, b: ^ast.Expr) -> bool {
		unary, is_unary := a.derived.(^ast.Unary_Expr)
		if !is_unary || unary.op.kind != .Not do return false
		inner := unparen(unary.expr)
		return side_effect_free(inner) && same_text(src, inner, b)
	}
	return inverts(src, a, b) || inverts(src, b, a)
}

@(private = "file")
bool_duplicate_condition :: proc(ctx: ^LintContext, root: ^ast.If_Stmt, diags: ^[dynamic]Diagnostic) {
	conds := make([dynamic]^ast.Expr, context.temp_allocator)
	stmt := root
	for {
		if stmt.cond != nil do append(&conds, unparen(stmt.cond))
		if stmt.else_stmt == nil do break
		next, is_if := stmt.else_stmt.derived.(^ast.If_Stmt)
		if !is_if do break
		ctx.skip[next] = {}
		stmt = next
	}

	for i in 1 ..< len(conds) {
		if !side_effect_free(conds[i]) do continue
		for j in 0 ..< i {
			if !same_text(ctx.src, conds[i], conds[j]) do continue
			append(
				diags,
				Diagnostic {
					range = common.get_token_range(conds[i], ctx.src),
					severity = .Warning,
					code = "duplicate-condition",
					message = "condition repeats an earlier branch and can never run",
				},
			)
			break
		}
	}
}

@(private = "file")
bool_duplicate_case :: proc(ctx: ^LintContext, switch_stmt: ^ast.Switch_Stmt, diags: ^[dynamic]Diagnostic) {
	block, is_block := switch_stmt.body.derived.(^ast.Block_Stmt)
	if !is_block do return

	seen := make(map[string]struct{}, context.temp_allocator)
	for stmt in block.stmts {
		clause, is_clause := stmt.derived.(^ast.Case_Clause)
		if !is_clause do continue
		for expr in clause.list {
			text := strip_space(node_text(ctx.src, expr))
			if text not_in seen {
				seen[text] = {}
				continue
			}
			// The compiler already rejects duplicate constant cases.
			if is_constant_expr(ctx, expr) do continue
			append(
				diags,
				Diagnostic {
					range = common.get_token_range(expr, ctx.src),
					severity = .Warning,
					code = "duplicate-condition",
					message = "case repeats an earlier case and can never run",
				},
			)
		}
	}
}

@(private = "file")
is_constant_expr :: proc(ctx: ^LintContext, expr: ^ast.Expr) -> bool {
	#partial switch e in expr.derived {
	case ^ast.Basic_Lit, ^ast.Implicit_Selector_Expr:
		return true
	case ^ast.Paren_Expr:
		return is_constant_expr(ctx, e.expr)
	case ^ast.Unary_Expr:
		return is_constant_expr(ctx, e.expr)
	case ^ast.Binary_Expr:
		return is_constant_expr(ctx, e.left) && is_constant_expr(ctx, e.right)
	case ^ast.Ident, ^ast.Selector_Expr:
		resolved, is_resolved := lint_symbols(ctx)[uintptr(expr)]
		if !is_resolved || resolved.is_unresolved do return true
		return resolved.symbol.type == .Constant || resolved.symbol.type == .EnumMember
	}
	return false
}

@(private = "file")
same_text :: proc(src: string, a, b: ^ast.Expr) -> bool {
	return strip_space(node_text(src, a)) == strip_space(node_text(src, b))
}

// Evaluating the expression twice cannot change anything: no calls, no `or_return`, no dereference.
@(private = "file")
side_effect_free :: proc(expr: ^ast.Expr) -> bool {
	if expr == nil do return false
	#partial switch e in expr.derived {
	case ^ast.Ident, ^ast.Basic_Lit, ^ast.Implicit_Selector_Expr:
		return true
	case ^ast.Selector_Expr:
		return side_effect_free(e.expr)
	case ^ast.Paren_Expr:
		return side_effect_free(e.expr)
	case ^ast.Unary_Expr:
		return side_effect_free(e.expr)
	case ^ast.Binary_Expr:
		return side_effect_free(e.left) && side_effect_free(e.right)
	case ^ast.Index_Expr:
		return side_effect_free(e.expr) && side_effect_free(e.index)
	}
	return false
}
