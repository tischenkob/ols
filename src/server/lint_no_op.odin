package server

import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strconv"
import "core:strings"

import "src:common"

lint_no_op :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_no_op do return

	no_op_append(ctx, node, diags)

	#partial switch n in node.derived {
	case ^ast.Binary_Expr:
		no_op_arithmetic(ctx, n, diags)
		no_op_literal_division(ctx, n, diags)
		no_op_address_nil(ctx, n, diags)
	case ^ast.Assign_Stmt:
		no_op_compound_assign(ctx, n, diags)
	case ^ast.If_Stmt:
		no_op_empty_body(ctx, n.body, diags)
		no_op_empty_body(ctx, n.else_stmt, diags)
	case ^ast.For_Stmt:
		// `for {}` is a spin loop, not an empty body.
		if n.init != nil || n.cond != nil || n.post != nil {
			no_op_empty_body(ctx, n.body, diags)
		}
	case ^ast.Range_Stmt:
		no_op_empty_body(ctx, n.body, diags)
	}
}

// The literal operand that leaves the other side unchanged: `x + 0`, `x * 1`, `x << 0`.
@(private = "file")
identity_operand :: proc(op: tokenizer.Token_Kind) -> (value: i64, ok: bool) {
	#partial switch op {
	case .Add, .Sub, .Or, .Xor, .Shl, .Shr:
		return 0, true
	case .Mul, .Quo:
		return 1, true
	}
	return
}

@(private = "file")
commutative :: proc(op: tokenizer.Token_Kind) -> bool {
	#partial switch op {
	case .Add, .Mul, .Or, .Xor, .And:
		return true
	}
	return false
}

// The literal operand that pins the result to 0 whatever the other side is.
@(private = "file")
zeroes_result :: proc(op: tokenizer.Token_Kind, value: i64) -> bool {
	#partial switch op {
	case .Mod, .Mod_Mod:
		return value == 1
	case .And, .Mul:
		return value == 0
	}
	return false
}

@(private = "file")
int_literal :: proc(expr: ^ast.Expr) -> (value: i64, ok: bool) {
	lit := expr.derived.(^ast.Basic_Lit) or_return
	if lit.tok.kind != .Integer do return
	return strconv.parse_i64_maybe_prefixed(lit.tok.text)
}

@(private = "file")
no_op_arithmetic :: proc(ctx: ^LintContext, bin: ^ast.Binary_Expr, diags: ^[dynamic]Diagnostic) {
	left, right := unparen(bin.left), unparen(bin.right)
	left_value, left_is_lit := int_literal(left)
	right_value, right_is_lit := int_literal(right)
	// Two literals fold at compile time; that is arithmetic, not a mistake.
	if left_is_lit && right_is_lit do return

	other: ^ast.Expr
	value: i64
	switch {
	case right_is_lit:
		other, value = left, right_value
	case left_is_lit && commutative(bin.op.kind):
		other, value = right, left_value
	case:
		return
	}

	if identity, ok := identity_operand(bin.op.kind); ok && identity == value {
		append(
			diags,
			Diagnostic {
				range = common.get_token_range(bin, ctx.src),
				severity = .Hint,
				code = "no-op-arithmetic",
				message = "this operation leaves the value unchanged",
				tags = {.Unnecessary},
			},
		)
		append(
			&ctx.fixes,
			Lint_Fix{bin.pos.offset, bin.end.offset, "Remove no-op arithmetic", node_text(ctx.src, other)},
		)
		return
	}

	if zeroes_result(bin.op.kind, value) {
		append(
			diags,
			Diagnostic {
				range = common.get_token_range(bin, ctx.src),
				severity = .Warning,
				code = "no-op-arithmetic",
				message = "this expression is always 0",
			},
		)
	}
}

@(private = "file")
no_op_compound_assign :: proc(ctx: ^LintContext, assign: ^ast.Assign_Stmt, diags: ^[dynamic]Diagnostic) {
	if len(assign.lhs) != 1 || len(assign.rhs) != 1 do return

	identity, ok := identity_operand(compound_base(assign.op.kind))
	if !ok do return
	value, is_lit := int_literal(unparen(assign.rhs[0]))
	if !is_lit || value != identity do return

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(assign, ctx.src),
			severity = .Hint,
			code = "no-op-arithmetic",
			message = "this assignment leaves the value unchanged",
			tags = {.Unnecessary},
		},
	)
	start, end := whole_lines(ctx.src, assign.pos.offset, assign.end.offset)
	append(&ctx.fixes, Lint_Fix{start, end, "Remove no-op arithmetic", ""})
}

@(private = "file")
compound_base :: proc(op: tokenizer.Token_Kind) -> tokenizer.Token_Kind {
	#partial switch op {
	case .Add_Eq:
		return .Add
	case .Sub_Eq:
		return .Sub
	case .Mul_Eq:
		return .Mul
	case .Quo_Eq:
		return .Quo
	case .Or_Eq:
		return .Or
	case .Xor_Eq:
		return .Xor
	case .Shl_Eq:
		return .Shl
	case .Shr_Eq:
		return .Shr
	}
	return .Invalid
}

@(private = "file")
no_op_literal_division :: proc(ctx: ^LintContext, bin: ^ast.Binary_Expr, diags: ^[dynamic]Diagnostic) {
	if bin.op.kind != .Quo do return
	left_value, left_ok := int_literal(unparen(bin.left))
	right_value, right_ok := int_literal(unparen(bin.right))
	if !left_ok || !right_ok || left_value >= right_value do return

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(bin, ctx.src),
			severity = .Warning,
			code = "literal-division-zero",
			message = "integer division of literals is 0; add a decimal point for float division",
		},
	)
}

@(private = "file")
no_op_address_nil :: proc(ctx: ^LintContext, bin: ^ast.Binary_Expr, diags: ^[dynamic]Diagnostic) {
	if bin.op.kind != .Cmp_Eq && bin.op.kind != .Not_Eq do return
	left, right := unparen(bin.left), unparen(bin.right)
	if !(is_address_of(left) && is_nil(right)) && !(is_nil(left) && is_address_of(right)) do return

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(bin, ctx.src),
			severity = .Warning,
			code = "address-nil-compare",
			message = "address of a variable is never nil",
		},
	)
}

@(private = "file")
is_address_of :: proc(expr: ^ast.Expr) -> bool {
	unary, is_unary := expr.derived.(^ast.Unary_Expr)
	return is_unary && unary.op.kind == .And
}

@(private = "file")
is_nil :: proc(expr: ^ast.Expr) -> bool {
	ident, is_ident := expr.derived.(^ast.Ident)
	return is_ident && ident.name == "nil"
}

@(private = "file")
no_op_empty_body :: proc(ctx: ^LintContext, stmt: ^ast.Stmt, diags: ^[dynamic]Diagnostic) {
	if stmt == nil do return
	block, is_block := stmt.derived.(^ast.Block_Stmt)
	if !is_block || len(block.stmts) > 0 do return
	// A block kept only for a comment is deliberate.
	inner := ctx.src[block.open.offset + 1:block.close.offset]
	if strings.contains(inner, "//") || strings.contains(inner, "/*") do return

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(block, ctx.src),
			severity = .Warning,
			code = "empty-body",
			message = "this body is empty",
		},
	)
}

@(private = "file")
append_without_values :: proc(call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 1 do return false
	callee, is_ident := call.expr.derived.(^ast.Ident)
	if !is_ident do return false
	return callee.name == "append" || callee.name == "append_elem" || callee.name == "append_elems"
}

// The diagnostic hangs off the call and the fix off the enclosing statement, so the walker
// reaches each exactly once.
@(private = "file")
no_op_append :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	#partial switch n in node.derived {
	case ^ast.Call_Expr:
		if !append_without_values(n) do return
		append(
			diags,
			Diagnostic {
				range = common.get_token_range(n, ctx.src),
				severity = .Hint,
				code = "append-no-values",
				message = "append without values does nothing",
				tags = {.Unnecessary},
			},
		)
	case ^ast.Expr_Stmt:
		call, is_call := n.expr.derived.(^ast.Call_Expr)
		if !is_call || !append_without_values(call) do return
		start, end := whole_lines(ctx.src, node.pos.offset, node.end.offset)
		append(&ctx.fixes, Lint_Fix{start, end, "Remove append without values", ""})
	}
}
