#+private file

package server

import "base:intrinsics"
import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"

// The largest expression around the cursor made of integer literals and `+ - * / % << >> & |`. Odin evaluates such a
// constant exactly, so an intermediate value outside i64 refuses even when the result would fit.
@(private = "package")
add_evaluate_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_evaluate {
		return
	}
	for at in nodes_at(ctx.document.ast.decls[:], ctx.range.start) {
		if ctx.range.end > at.node.end.offset {
			continue
		}
		operations := 0
		value := evaluate(at.node, &operations) or_continue
		if operations == 0 {
			continue
		}
		text := fmt.tprintf("%d", value)
		// `a - (1 - 2)` must not become `a - -1` glued to another operator.
		if value < 0 && at.parent != nil {
			#partial switch _ in at.parent.derived {
			case ^ast.Binary_Expr, ^ast.Unary_Expr:
				text = fmt.tprintf("(%d)", value)
			}
		}
		append_replace_range(ctx, at.node.pos.offset, at.node.end.offset, "Evaluate constant", text)
		return
	}
}

evaluate :: proc(node: ^ast.Node, operations: ^int) -> (value: i64, ok: bool) {
	#partial switch n in node.derived {
	case ^ast.Basic_Lit:
		if n.tok.kind != .Integer {
			return
		}
		return parse_literal(n.tok.text)
	case ^ast.Paren_Expr:
		return evaluate(n.expr, operations)
	case ^ast.Unary_Expr:
		operand := evaluate(n.expr, operations) or_return
		#partial switch n.op.kind {
		case .Add:
			return operand, true
		case .Sub:
			return -operand, operand != min(i64)
		}
	case ^ast.Binary_Expr:
		left := evaluate(n.left, operations) or_return
		right := evaluate(n.right, operations) or_return
		operations^ += 1
		return apply(n.op.kind, left, right)
	}
	return
}

apply :: proc(op: tokenizer.Token_Kind, a, b: i64) -> (value: i64, ok: bool) {
	overflow: bool
	#partial switch op {
	case .Add:
		value, overflow = intrinsics.overflow_add(a, b)
	case .Sub:
		value, overflow = intrinsics.overflow_sub(a, b)
	case .Mul:
		value, overflow = intrinsics.overflow_mul(a, b)
	case .Quo:
		if b == 0 || (a == min(i64) && b == -1) {
			return
		}
		value = a / b
	case .Mod:
		if b == 0 || (a == min(i64) && b == -1) {
			return
		}
		value = a % b
	case .Shl:
		if b < 0 || b > 63 {
			return
		}
		value = a << u64(b)
		overflow = value >> u64(b) != a
	case .Shr:
		if b < 0 || b > 63 {
			return
		}
		value = a >> u64(b)
	case .And:
		value = a & b
	case .Or:
		value = a | b
	case:
		return
	}
	return value, !overflow
}

// strconv does not report an overflow.
parse_literal :: proc(text: string) -> (value: i64, ok: bool) {
	base: i64 = 10
	digits := text
	if len(text) > 2 && text[0] == '0' {
		prefixed := true
		switch text[1] {
		case 'x':
			base = 16
		case 'b':
			base = 2
		case 'o':
			base = 8
		case 'd':
			base = 10
		case 'z':
			base = 12
		case:
			prefixed = false
		}
		if prefixed {
			digits = text[2:]
		}
	}
	for c in transmute([]u8)digits {
		digit: i64
		switch c {
		case '_':
			continue
		case '0' ..= '9':
			digit = i64(c - '0')
		case 'a' ..= 'f':
			digit = i64(c - 'a') + 10
		case 'A' ..= 'F':
			digit = i64(c - 'A') + 10
		case:
			return 0, false
		}
		if digit >= base {
			return 0, false
		}
		times, times_over := intrinsics.overflow_mul(value, base)
		sum, sum_over := intrinsics.overflow_add(times, digit)
		if times_over || sum_over {
			return 0, false
		}
		value = sum
	}
	return value, true
}
