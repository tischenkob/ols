package server

import "core:odin/ast"
import "core:strconv"

// const_int follows at most this many named constants, which bounds a cycle such as `A :: B` and `B :: A`.
ENUM_VALUE_MAX_DEPTH :: 32

// The value of each enum member, nil when it cannot be evaluated, and the index of the first member a
// switch case on it also covers. A member that names an earlier member (`FIRST = A`) shares that member's
// class even when the value is unknown. Any other member with an unknown value gets a class of its own.
// A super enum (a union of enums) carries no values, so each of its members is its own class.
@(private = "package")
enum_member_values :: proc(ast_context: ^AstContext, v: SymbolEnumValue) -> (values: []Maybe(int), classes: []int) {
	values = make([]Maybe(int), len(v.names), context.temp_allocator)
	classes = make([]int, len(v.names), context.temp_allocator)
	has_values := len(v.values) == len(v.names)
	// The index of each member name seen so far, and of the first member with each known value.
	member_index := make(map[string]int, len(v.names), context.temp_allocator)
	// The value of each member name seen so far, for a value written over earlier members.
	member_value := make(map[string]Maybe(int), len(v.names), context.temp_allocator)
	value_index := make(map[int]int, len(v.names), context.temp_allocator)
	next: Maybe(int) = 0
	for name, i in v.names {
		classes[i] = i
		if !has_values {
			continue
		}

		value := next
		if expr := v.values[i]; expr != nil {
			value = nil
			// Members are in scope inside the enum body, ahead of any constant with the same name.
			if ident, is_ident := expr.derived.(^ast.Ident); is_ident {
				if j, is_member := member_index[ident.name]; is_member {
					classes[i] = classes[j]
					value = values[j]
				}
			}
			if classes[i] == i {
				if n, ok := const_int(ast_context, expr, member_value); ok {
					value = n
				}
			}
		}

		values[i] = value
		if name not_in member_index {
			member_index[name] = i
			member_value[name] = value
		}
		n, known := value.?
		next = nil
		if !known {
			continue
		}
		next = n + 1
		if classes[i] != i {
			continue
		}
		if j, seen := value_index[n]; seen {
			classes[i] = classes[j]
		} else {
			value_index[n] = i
		}
	}
	return
}

// `members` holds the values of the earlier members of the enum whose member value this is, nil when unknown.
// A member name is in scope ahead of any constant with the same name.
const_int :: proc(
	ast_context: ^AstContext,
	expr: ^ast.Expr,
	members: map[string]Maybe(int) = nil,
	depth := 0,
) -> (
	value: int,
	ok: bool,
) {
	// depth counts the constants followed so far, which bounds a cycle such as `A :: B` and `B :: A`.
	if expr == nil || depth > ENUM_VALUE_MAX_DEPTH {
		return
	}

	#partial switch v in expr.derived {
	case ^ast.Basic_Lit:
		if v.tok.kind == .Rune {
			if len(v.tok.text) < 3 {
				return
			}
			r, _, tail := strconv.unquote_char(v.tok.text[1:len(v.tok.text) - 1], '\'') or_return
			if tail != "" {
				return
			}
			return int(r), true
		}
		return strconv.parse_int(v.tok.text, 0)
	case ^ast.Paren_Expr:
		return const_int(ast_context, v.expr, members, depth)
	case ^ast.Unary_Expr:
		value = const_int(ast_context, v.expr, members, depth) or_return
		#partial switch v.op.kind {
		case .Sub:
			return -value, true
		case .Add:
			return value, true
		}
	case ^ast.Binary_Expr:
		left := const_int(ast_context, v.left, members, depth) or_return
		right := const_int(ast_context, v.right, members, depth) or_return
		#partial switch v.op.kind {
		case .Add:
			return left + right, true
		case .Sub:
			return left - right, true
		case .Mul:
			return left * right, true
		case .Quo, .Mod, .Mod_Mod:
			if right == 0 do return
			// The smallest int divided by -1 overflows, which traps on some targets.
			if right == -1 do return v.op.kind == .Quo ? -left : 0, true
			if v.op.kind == .Quo do return left / right, true
			return v.op.kind == .Mod ? left % right : left %% right, true
		case .Shl, .Shr:
			// ponytail: constants are 64-bit here, while Odin folds untyped constants at full precision.
			if right < 0 || right >= 64 {
				return
			}
			return v.op.kind == .Shl ? left << uint(right) : left >> uint(right), true
		case .Or:
			return left | right, true
		case .And:
			return left & right, true
		case .Xor:
			return left ~ right, true
		case .And_Not:
			return left &~ right, true
		}
	case ^ast.Ident, ^ast.Selector_Expr:
		if ident, is_ident := expr.derived.(^ast.Ident); is_ident {
			if member, is_member := members[ident.name]; is_member {
				return member.?
			}
		}
		symbol := resolve_type_expression(ast_context, expr) or_return
		// A constant declared as an expression folds in the package that declares it.
		if symbol.type == .Constant && symbol.value_expr != nil {
			set_ast_package_from_symbol_scoped(ast_context, symbol)
			return const_int(ast_context, symbol.value_expr, nil, depth + 1)
		}
		untyped := symbol.value.(SymbolUntypedValue) or_return
		if untyped.type != .Integer {
			return
		}
		return strconv.parse_int(untyped.tok.text, 0)
	}

	return
}
