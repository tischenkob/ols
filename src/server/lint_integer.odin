package server

import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"

import "src:common"

lint_integer_range :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_integer_range do return

	#partial switch n in node.derived {
	case ^ast.Binary_Expr:
		#partial switch n.op.kind {
		case .Shl, .Shr:
			shift_overflow(ctx, node, n.left, n.right, diags)
		case .Cmp_Eq, .Not_Eq, .Lt, .Lt_Eq, .Gt, .Gt_Eq:
			unsigned_compare(ctx, n, diags)
		}
	case ^ast.Assign_Stmt:
		if (n.op.kind == .Shl_Eq || n.op.kind == .Shr_Eq) && len(n.lhs) == 1 && len(n.rhs) == 1 {
			shift_overflow(ctx, node, n.lhs[0], n.rhs[0], diags)
		}
	case ^ast.Call_Expr, ^ast.Type_Cast:
		division_before_conversion(ctx, node, diags)
	}
}

// Bit width and signedness of a sized integer type name. int, uint and uintptr are 64-bit.
@(private = "file")
int_kind :: proc(name: string) -> (width: int, unsigned: bool, ok: bool) {
	switch name {
	case "i8":
		return 8, false, true
	case "u8":
		return 8, true, true
	case "i16":
		return 16, false, true
	case "u16":
		return 16, true, true
	case "i32":
		return 32, false, true
	case "u32":
		return 32, true, true
	case "i64", "int":
		return 64, false, true
	case "u64", "uint", "uintptr":
		return 64, true, true
	case "i128":
		return 128, false, true
	case "u128":
		return 128, true, true
	}
	return
}

// The integer type name behind an expression. Only identifiers and selectors are in the resolved
// map, so an indexed or called integer is invisible here. A distinct integer still counts.
@(private = "file")
integer_name :: proc(ctx: ^LintContext, expr: ^ast.Expr) -> (name: string, ok: bool) {
	resolved := lint_symbols(ctx)[uintptr(expr)] or_return
	if resolved.is_unresolved || resolved.symbol.pointers != 0 do return
	basic := resolved.symbol.value.(SymbolBasicValue) or_return
	if _, _, is_int := int_kind(basic.ident.name); !is_int do return
	return basic.ident.name, true
}

@(private = "file")
shift_overflow :: proc(ctx: ^LintContext, node: ^ast.Node, left, right: ^ast.Expr, diags: ^[dynamic]Diagnostic) {
	name, is_int := integer_name(ctx, left)
	if !is_int do return
	width, _, _ := int_kind(name)
	amount, is_literal := int_literal(right)
	if !is_literal || amount < width do return

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(node^, ctx.src),
			severity = .Warning,
			code = "shift-overflow",
			message = fmt.tprintf("shifting a %s by %d always yields 0", name, amount),
		},
	)
}

@(private = "file")
unsigned_compare :: proc(ctx: ^LintContext, binary: ^ast.Binary_Expr, diags: ^[dynamic]Diagnostic) {
	name, value, op, ok := unsigned_and_literal(ctx, binary.left, binary.right, binary.op.kind)
	if !ok {
		name, value, op, ok = unsigned_and_literal(ctx, binary.right, binary.left, mirrored(binary.op.kind))
		if !ok do return
	}

	always: bool
	switch {
	case value < 0:
		#partial switch op {
		case .Not_Eq, .Gt, .Gt_Eq:
			always = true
		}
	case value == 0:
		#partial switch op {
		case .Lt:
			always = false
		case .Gt_Eq:
			always = true
		case:
			return
		}
	case:
		return
	}

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(binary^, ctx.src),
			severity = .Warning,
			code = "unsigned-negative-compare",
			message = fmt.tprintf("an unsigned %s is never negative, so this is always %v", name, always),
		},
	)
}

// Reads the comparison with `unsigned` on the left; `op` is already mirrored by the caller when it is not.
@(private = "file")
unsigned_and_literal :: proc(
	ctx: ^LintContext,
	unsigned, literal: ^ast.Expr,
	op: tokenizer.Token_Kind,
) -> (
	name: string,
	value: int,
	out_op: tokenizer.Token_Kind,
	ok: bool,
) {
	name = integer_name(ctx, unsigned) or_return
	if _, is_unsigned, _ := int_kind(name); !is_unsigned do return
	value = int_literal(literal) or_return
	return name, value, op, true
}

@(private = "file")
mirrored :: proc(op: tokenizer.Token_Kind) -> tokenizer.Token_Kind {
	#partial switch op {
	case .Lt:
		return .Gt
	case .Lt_Eq:
		return .Gt_Eq
	case .Gt:
		return .Lt
	case .Gt_Eq:
		return .Lt_Eq
	}
	return op
}

@(private = "file")
division_before_conversion :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	inner, type, is_conversion := float_conversion(cast(^ast.Expr)node)
	if !is_conversion do return
	for {
		paren := inner.derived.(^ast.Paren_Expr) or_break
		inner = paren.expr
	}
	binary, is_binary := inner.derived.(^ast.Binary_Expr)
	if !is_binary || binary.op.kind != .Quo do return
	if !is_integer_expr(ctx, binary.left) || !is_integer_expr(ctx, binary.right) do return

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(node^, ctx.src),
			severity = .Warning,
			code = "integer-division-float",
			message = fmt.tprintf("integer division happens before the conversion to %s", type),
		},
	)
}

@(private = "file")
is_integer_expr :: proc(ctx: ^LintContext, expr: ^ast.Expr) -> bool {
	if lit, is_lit := expr.derived.(^ast.Basic_Lit); is_lit {
		return lit.tok.kind == .Integer
	}
	_, ok := integer_name(ctx, expr)
	return ok
}
