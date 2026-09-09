#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:strconv"

import "src:common"

@(private = "package")
add_extra_inlay_hints :: proc(
	node: ^ast.Node,
	document: ^Document,
	symbols: SymbolAndNodeMap,
	config: ^common.Config,
	ast_context: ^AstContext,
	hints: ^[dynamic]InlayHint,
) {
	add_comp_lit_field_hints(node, document, symbols, config, hints)
	add_range_type_hints(node, document, symbols, config, ast_context, hints)
	add_constant_value_hints(node, document, config, hints)
}

// Point{[[x: ]]1, [[y: ]]2}
add_comp_lit_field_hints :: proc(
	node: ^ast.Node,
	document: ^Document,
	symbols: SymbolAndNodeMap,
	config: ^common.Config,
	hints: ^[dynamic]InlayHint,
) -> (
	ok: bool,
) {
	if !config.enable_inlay_hints_comp_lit_fields {
		return
	}

	lit := node.derived.(^ast.Comp_Lit) or_return
	if lit.type == nil {
		return
	}

	resolved := symbols[uintptr(lit.type)] or_return
	value := resolved.symbol.value.(SymbolStructValue) or_return

	// A `using` field flattens into the positional order, so index i no longer names field i.
	if len(value.usings) > 0 {
		return
	}

	src := string(document.text)

	for elem, i in lit.elems {
		if i >= len(value.names) {
			return
		}
		if _, is_field := elem.derived.(^ast.Field_Value); is_field {
			continue
		}
		range := common.get_token_range(elem, src)
		append(hints, InlayHint{range.start, .Parameter, fmt.tprintf("%s: ", value.names[i])})
	}

	return true
}

// for k[[: string]], v[[: int]] in m
add_range_type_hints :: proc(
	node: ^ast.Node,
	document: ^Document,
	symbols: SymbolAndNodeMap,
	config: ^common.Config,
	ast_context: ^AstContext,
	hints: ^[dynamic]InlayHint,
) -> (
	ok: bool,
) {
	if !config.enable_inlay_hints_range_types {
		return
	}

	stmt := node.derived.(^ast.Range_Stmt) or_return
	src := string(document.text)

	for val in stmt.vals {
		ident := val.derived.(^ast.Ident) or_continue
		if ident.name == "_" {
			continue
		}
		resolved := symbols[uintptr(ident)] or_continue
		text := symbol_type_text(ast_context, resolved.symbol^, ident.name) or_continue
		range := common.get_token_range(ident, src)
		append(hints, InlayHint{range.end, .Type, fmt.tprintf(": %s", text)})
	}

	return true
}

// SIZE :: WIDTH * 2[[ = 8]]
add_constant_value_hints :: proc(
	node: ^ast.Node,
	document: ^Document,
	config: ^common.Config,
	hints: ^[dynamic]InlayHint,
) -> (
	ok: bool,
) {
	if !config.enable_inlay_hints_constant_values {
		return
	}

	decl := node.derived.(^ast.Value_Decl) or_return
	if decl.is_mutable {
		return
	}

	src := string(document.text)

	for value in decl.values {
		if _, is_literal := value.derived.(^ast.Basic_Lit); is_literal {
			continue
		}
		folded := fold_constant(value, document, 0) or_continue
		text: string
		switch v in folded {
		case i64:
			text = fmt.tprintf(" = %d", v)
		case bool:
			text = fmt.tprintf(" = %t", v)
		case string:
			text = fmt.tprintf(" = %q", v)
		}
		range := common.get_token_range(value, src)
		append(hints, InlayHint{range.end, .Type, text})
	}

	return true
}

Constant :: union {
	i64,
	bool,
	string,
}

MAX_FOLD_DEPTH :: 16

fold_constant :: proc(expr: ^ast.Expr, document: ^Document, depth: int) -> (result: Constant, ok: bool) {
	if expr == nil || depth > MAX_FOLD_DEPTH {
		return
	}

	#partial switch v in expr.derived {
	case ^ast.Basic_Lit:
		#partial switch v.tok.kind {
		case .Integer:
			n := strconv.parse_i64_maybe_prefixed(v.tok.text) or_return
			return n, true
		case .String:
			text, _, unquoted := strconv.unquote_string(v.tok.text, context.temp_allocator)
			if !unquoted {
				return
			}
			return text, true
		}
		return

	case ^ast.Ident:
		switch v.name {
		case "true":
			return true, true
		case "false":
			return false, true
		}
		value := find_file_constant(document, v.name) or_return
		return fold_constant(value, document, depth + 1)

	case ^ast.Paren_Expr:
		return fold_constant(v.expr, document, depth + 1)

	case ^ast.Unary_Expr:
		operand := fold_constant(v.expr, document, depth + 1) or_return
		#partial switch v.op.kind {
		case .Add:
			n := operand.(i64) or_return
			return n, true
		case .Sub:
			n := operand.(i64) or_return
			return -n, true
		case .Xor:
			n := operand.(i64) or_return
			return ~n, true
		case .Not:
			b := operand.(bool) or_return
			return !b, true
		}
		return

	case ^ast.Binary_Expr:
		left := fold_constant(v.left, document, depth + 1) or_return

		// Short-circuit operators still fold both sides; a constant expression has no side effects.
		if lb, is_bool := left.(bool); is_bool {
			#partial switch v.op.kind {
			case .Cmp_And, .Cmp_Or:
				rb := fold_constant(v.right, document, depth + 1) or_return
				rbool := rb.(bool) or_return
				return v.op.kind == .Cmp_And ? lb && rbool : lb || rbool, true
			}
			return
		}

		right := fold_constant(v.right, document, depth + 1) or_return

		if ls, is_string := left.(string); is_string {
			rs := right.(string) or_return
			if v.op.kind != .Add {
				return
			}
			return fmt.tprintf("%s%s", ls, rs), true
		}

		l := left.(i64) or_return
		r := right.(i64) or_return

		#partial switch v.op.kind {
		case .Add:
			return l + r, true
		case .Sub:
			return l - r, true
		case .Mul:
			return l * r, true
		case .Quo:
			if r == 0 {
				return
			}
			return l / r, true
		case .Mod:
			if r == 0 {
				return
			}
			return l % r, true
		case .Shl:
			if r < 0 || r > 63 {
				return
			}
			return l << uint(r), true
		case .Shr:
			if r < 0 || r > 63 {
				return
			}
			return l >> uint(r), true
		case .Or:
			return l | r, true
		case .And:
			return l & r, true
		case .Xor:
			return l ~ r, true
		case .And_Not:
			return l &~ r, true
		}
		return
	}

	return
}

// ponytail: linear scan of top-level decls; constants declared inside a procedure are not found.
find_file_constant :: proc(document: ^Document, name: string) -> (^ast.Expr, bool) {
	for decl in document.ast.decls {
		value_decl := decl.derived.(^ast.Value_Decl) or_continue
		if value_decl.is_mutable || len(value_decl.names) != len(value_decl.values) {
			continue
		}
		for n, i in value_decl.names {
			ident := n.derived.(^ast.Ident) or_continue
			if ident.name == name {
				return value_decl.values[i], true
			}
		}
	}
	return nil, false
}
