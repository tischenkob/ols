#+private file

package server

import "core:odin/ast"
import "core:odin/tokenizer"
import "core:slice"
import "core:strings"

@(private = "package")
add_const_var_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_const_var {
		return
	}
	stmts, index, ok := stmt_at_range(ctx)
	if !ok {
		return
	}
	decl, is_decl := stmts[index].derived.(^ast.Value_Decl)
	if !is_decl || decl.type != nil || decl.is_using || len(decl.attributes) > 0 {
		return
	}
	if len(decl.names) != 1 || len(decl.values) != 1 {
		return
	}
	name, is_ident := decl.names[0].derived.(^ast.Ident)
	value := decl.values[0]
	if !is_ident || name.name == "_" {
		return
	}
	src := ctx.document.ast.src
	separator := strings.trim_space(src[name.end.offset:value.pos.offset])
	if separator != (decl.is_mutable ? ":=" : "::") || !is_constant(ctx, value) {
		return
	}

	type: string
	if decl.is_mutable {
		// A constant literal needs a type the compiler can hold as a constant, which the name alone does not tell.
		if _, is_literal := value.derived.(^ast.Comp_Lit); is_literal {
			return
		}
		gather_locals_at(ctx, decl.end.offset)
		defer restore_locals(ctx)
		type, ok = local_type_text(ctx, name)
	} else {
		type, ok = constant_default_type(ctx, value)
	}
	if !ok {
		return
	}

	checker := Use_Checker {
		ctx         = ctx,
		typed       = resolve_entire_file(ctx.document),
		to_variable = !decl.is_mutable,
	}
	symbols := resolve_entire_file_for_references(ctx.document, context.temp_allocator, .Identifier, "")
	uses := 0
	for use in collect_ident_uses(ctx.position_context.function.body) {
		if use.ident == name || use.ident.name != name.name || is_member_name(use) {
			continue
		}
		// A local constant is visible above its declaration, so a constant would capture an earlier use of this name.
		if use.ident.pos.offset < decl.pos.offset {
			return
		}
		offset, is_local := local_decl_offset(ctx, symbols, use.ident)
		if !is_local {
			return
		}
		if offset != name.pos.offset {
			continue
		}
		// A nested procedure sees a constant of the procedure around it, and no variable.
		for parent in use.parents {
			if _, is_proc := parent.derived.(^ast.Proc_Lit); is_proc {
				return
			}
		}
		if !keeps_meaning(&checker, use.parents, use.ident, type) {
			return
		}
		uses += 1
	}
	if uses == 0 {
		return
	}

	title := decl.is_mutable ? "Convert to constant" : "Convert to variable"
	append_replace_range(ctx, name.end.offset, value.pos.offset, title, decl.is_mutable ? " :: " : " := ")
}

// The default type of a constant expression, when its form alone tells it: what `x := v` gives x. A name or a type
// other than `true` and `false` fails, which also refuses types and procedures.
@(private = "package")
constant_default_type :: proc(ctx: ^ActionContext, value: ^ast.Expr) -> (string, bool) {
	src := ctx.document.ast.src
	#partial switch v in value.derived {
	case ^ast.Basic_Lit:
		return literal_type(v)
	case ^ast.Ident:
		return "bool", v.name == "true" || v.name == "false"
	case ^ast.Paren_Expr:
		return constant_default_type(ctx, v.expr)
	case ^ast.Unary_Expr:
		#partial switch v.op.kind {
		case .Add, .Sub, .Xor, .Not:
			return constant_default_type(ctx, v.expr)
		}
	case ^ast.Binary_Expr:
		left, left_ok := constant_default_type(ctx, v.left)
		right, right_ok := constant_default_type(ctx, v.right)
		if !left_ok || !right_ok || left != right {
			return "", false
		}
		return is_comparison(v.op.kind) ? "bool" : left, true
	case ^ast.Call_Expr:
		if !is_constant(ctx, value) {
			return "", false
		}
		if callee, is_name := v.expr.derived.(^ast.Ident); is_name {
			switch callee.name {
			case "size_of", "align_of", "offset_of":
				return "int", true
			}
		}
		return node_text(src, v.expr), true
	case ^ast.Type_Cast:
		if is_constant(ctx, value) {
			return node_text(src, v.type), true
		}
	case ^ast.Comp_Lit:
		if v.type != nil && is_constant(ctx, value) {
			return node_text(src, v.type), true
		}
	case ^ast.Selector_Expr:
		// A constant of a package gets the package name, which matches no type, so it passes only where no type is
		// written.
		if is_constant(ctx, value) {
			return node_text(src, v.expr), true
		}
	}
	return "", false
}

literal_type :: proc(literal: ^ast.Basic_Lit) -> (string, bool) {
	#partial switch literal.tok.kind {
	case .Integer:
		return "int", true
	case .Float:
		return "f64", true
	case .Rune:
		return "rune", true
	case .String:
		return "string", true
	}
	return "", false
}

is_comparison :: proc(kind: tokenizer.Token_Kind) -> bool {
	#partial switch kind {
	case .Cmp_Eq, .Not_Eq, .Lt, .Gt, .Lt_Eq, .Gt_Eq:
		return true
	}
	return false
}

Use_Checker :: struct {
	ctx:         ^ActionContext,
	typed:       SymbolAndNodeMap,
	to_variable: bool,
}

// A constant has an untyped value, a variable its one type. They read the same only in these places, where the value
// takes that type either way and no constant is needed. Anything else refuses: `2.0 * x` changes type, `u8(x)` and
// `10 / x` can stop compiling as a constant, and `y: f32 = x` or `[x]int` stop compiling as a variable.
keeps_meaning :: proc(checker: ^Use_Checker, parents: []^ast.Node, expr: ^ast.Expr, type: string) -> bool {
	if len(parents) == 0 {
		return false
	}
	src := checker.ctx.document.ast.src
	rest := parents[:len(parents) - 1]
	#partial switch p in parents[len(parents) - 1].derived {
	case ^ast.Paren_Expr:
		return keeps_meaning(checker, rest, p, type)
	case ^ast.Unary_Expr:
		return p.op.kind == .Not && type == "bool" && keeps_meaning(checker, rest, p, type)
	case ^ast.Value_Decl:
		return p.is_mutable && slice.contains(p.values, expr) && (p.type == nil || node_text(src, p.type) == type)
	case ^ast.Assign_Stmt:
		index, found := slice.linear_search(p.rhs, expr)
		return found && len(p.lhs) == len(p.rhs) && has_type(checker, p.lhs[index], type)
	case ^ast.If_Stmt:
		return type == "bool" && p.cond == expr
	case ^ast.For_Stmt:
		return type == "bool" && p.cond == expr
	case ^ast.Index_Expr:
		return checker.to_variable && type == "int" && p.index == expr
	case ^ast.Slice_Expr:
		return checker.to_variable && type == "int" && (p.low == expr || p.high == expr)
	case ^ast.Return_Stmt:
		return result_has_type(checker, p, expr, type)
	case ^ast.Call_Expr:
		return param_has_type(checker, p, expr, type)
	case ^ast.Binary_Expr:
		other := p.left == expr ? p.right : p.left
		if !has_type(checker, other, type) {
			return false
		}
		if is_comparison(p.op.kind) {
			return keeps_meaning(checker, rest, p, "bool")
		}
		#partial switch p.op.kind {
		case .Cmp_And, .Cmp_Or:
			return type == "bool" && keeps_meaning(checker, rest, p, type)
		case .Add, .Sub, .Mul, .Quo, .Mod:
			// Constant folding fails on what runs as a variable, and it is more exact than f64.
			return checker.to_variable && type == "int" && keeps_meaning(checker, rest, p, type)
		}
	}
	return false
}

// A literal of the default type, or a local whose resolved type prints as type.
has_type :: proc(checker: ^Use_Checker, expr: ^ast.Expr, type: string) -> bool {
	#partial switch e in expr.derived {
	case ^ast.Basic_Lit:
		literal, ok := literal_type(e)
		return ok && literal == type
	case ^ast.Ident:
		if e.name == "true" || e.name == "false" {
			return type == "bool"
		}
		resolved, found := checker.typed[uintptr(expr)]
		if !found || resolved.is_unresolved {
			return false
		}
		text, ok := symbol_type_text(checker.ctx.ast_context, resolved.symbol^, e.name, require_import = true)
		return ok && text == type
	}
	return false
}

result_has_type :: proc(checker: ^Use_Checker, stmt: ^ast.Return_Stmt, expr: ^ast.Expr, type: string) -> bool {
	index, found := slice.linear_search(stmt.results, expr)
	results := checker.ctx.position_context.function.type.results
	if !found || results == nil {
		return false
	}
	for field in results.list {
		if index < len(field.names) {
			return field.type != nil && node_text(checker.ctx.document.ast.src, field.type) == type
		}
		index -= len(field.names)
	}
	return false
}

// An `any` parameter takes either form. A `$N` parameter needs a constant, and `#by_ptr` an address.
param_has_type :: proc(checker: ^Use_Checker, call: ^ast.Call_Expr, expr: ^ast.Expr, type: string) -> bool {
	index, is_arg := slice.linear_search(call.args, expr)
	resolved, found := checker.typed[uintptr(call.expr)]
	if !is_arg || !found || resolved.is_unresolved {
		return false
	}
	callee, is_proc := resolved.symbol.value.(SymbolProcedureValue)
	if !is_proc {
		return false
	}
	field, has_field := get_call_arg_field(callee, call^, index)
	if !has_field || .By_Ptr in field.flags || .Const in field.flags {
		return false
	}
	for name in field.names {
		if _, is_poly := name.derived.(^ast.Poly_Type); is_poly {
			return false
		}
	}
	if names_any(field.type) {
		return true
	}
	ident, is_ident := field.type.derived.(^ast.Ident)
	return is_ident && ident.name == type
}
