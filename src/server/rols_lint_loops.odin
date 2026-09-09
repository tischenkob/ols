package server

import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:slice"
import "core:strconv"

import "src:common"

lint_loops :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_loops do return

	#partial switch n in node.derived {
	case ^ast.For_Stmt:
		loop_single_iteration(ctx, n.for_pos, n.body, diags)
		loop_condition_constant(ctx, n, diags)
		empty_loop(ctx, n, diags)
	case ^ast.Range_Stmt:
		loop_single_iteration(ctx, n.for_pos, n.body, diags)
		range_off_by_one(ctx, n, diags)
	}
}

@(private = "file")
for_range :: proc(ctx: ^LintContext, for_pos: tokenizer.Pos) -> common.Range {
	return {
		start = common.get_relative_token_position(for_pos.offset, ctx.document.text, 0),
		end = common.get_relative_token_position(for_pos.offset + len("for"), ctx.document.text, 0),
	}
}

@(private = "file")
Loop_Jumps :: struct {
	has_continue: bool,
	has_exit:     bool, // break or return
}

// Jumps that belong to this loop. Nested loops own their own jumps and a proc literal's
// jumps belong to that proc, so neither is descended into.
@(private = "file")
loop_jumps :: proc(body: ^ast.Stmt) -> (jumps: Loop_Jumps) {
	visitor := ast.Visitor {
		data = &jumps,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			jumps := (^Loop_Jumps)(visitor.data)
			#partial switch n in node.derived {
			case ^ast.For_Stmt, ^ast.Range_Stmt, ^ast.Unroll_Range_Stmt, ^ast.Proc_Lit:
				return nil
			case ^ast.Return_Stmt:
				jumps.has_exit = true
			case ^ast.Or_Branch_Expr:
				if n.token.kind == .Or_Continue do jumps.has_continue = true
			case ^ast.Branch_Stmt:
				#partial switch n.tok.kind {
				case .Continue:
					jumps.has_continue = true
				case .Break:
					jumps.has_exit = true
				}
			}
			return visitor
		},
	}
	ast.walk(&visitor, body)
	return
}

@(private = "file")
loop_single_iteration :: proc(
	ctx: ^LintContext,
	for_pos: tokenizer.Pos,
	body: ^ast.Stmt,
	diags: ^[dynamic]Diagnostic,
) {
	block, is_block := body.derived.(^ast.Block_Stmt)
	if !is_block || len(block.stmts) == 0 do return

	exits: bool
	#partial switch s in block.stmts[len(block.stmts) - 1].derived {
	case ^ast.Return_Stmt:
		exits = true
	case ^ast.Branch_Stmt:
		exits = s.tok.kind == .Break && s.label == nil
	}
	if !exits || loop_jumps(body).has_continue do return

	append(
		diags,
		Diagnostic {
			range = for_range(ctx, for_pos),
			severity = .Warning,
			code = "loop-single-iteration",
			message = "loop body always exits after the first iteration",
		},
	)
}

@(private = "file")
loop_condition_constant :: proc(ctx: ^LintContext, n: ^ast.For_Stmt, diags: ^[dynamic]Diagnostic) {
	if n.cond == nil || n.init != nil || n.post != nil do return
	if !loop_side_effect_free(n.cond) do return

	names := make(map[string]struct{}, context.temp_allocator)
	for use in collect_ident_uses(n.cond) {
		names[use.ident.name] = {}
	}
	if len(names) == 0 || loop_jumps(n.body).has_exit do return

	for use in collect_ident_uses(n.body) {
		if use.ident.name not_in names do continue
		if is_write(use) do return
		if len(use.parents) == 0 do continue
		// A call given the variable by pointer can change it.
		arg: ^ast.Expr = use.ident
		call, is_call := use.parents[len(use.parents) - 1].derived.(^ast.Call_Expr)
		if !is_call || !slice.contains(call.args, arg) do continue
		if resolved, ok := lint_symbols(ctx)[uintptr(use.ident)];
		   ok && !resolved.is_unresolved && resolved.symbol.pointers > 0 {
			return
		}
	}

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(n.cond, ctx.src),
			severity = .Warning,
			code = "loop-condition-constant",
			message = "loop condition never changes inside the body",
		},
	)
}

@(private = "file")
empty_loop :: proc(ctx: ^LintContext, n: ^ast.For_Stmt, diags: ^[dynamic]Diagnostic) {
	if n.init != nil || n.cond != nil || n.post != nil do return
	block, is_block := n.body.derived.(^ast.Block_Stmt)
	if !is_block || len(block.stmts) > 0 do return

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(n, ctx.src),
			severity = .Warning,
			code = "empty-loop",
			message = "empty infinite loop spins",
		},
	)
}

@(private = "file")
len_call :: proc(expr: ^ast.Expr) -> (arg: ^ast.Expr, ok: bool) {
	call := unparen(expr).derived.(^ast.Call_Expr) or_return
	if len(call.args) != 1 do return
	callee := call.expr.derived.(^ast.Ident) or_return
	if callee.name != "len" do return
	return call.args[0], true
}

@(private = "file")
range_off_by_one :: proc(ctx: ^LintContext, n: ^ast.Range_Stmt, diags: ^[dynamic]Diagnostic) {
	bin, is_bin := unparen(n.expr).derived.(^ast.Binary_Expr)
	if !is_bin do return

	fix: Lint_Fix
	#partial switch bin.op.kind {
	case .Range_Full:
		if _, ok := len_call(bin.right); !ok do return
		fix = {bin.op.pos.offset, bin.op.pos.offset + len(bin.op.text), "Use ..< instead of ..=", "..<"}
	case .Range_Half:
		plus, is_plus := unparen(bin.right).derived.(^ast.Binary_Expr)
		if !is_plus || plus.op.kind != .Add do return
		if _, ok := len_call(plus.left); !ok do return
		lit, is_lit := unparen(plus.right).derived.(^ast.Basic_Lit)
		if !is_lit || lit.tok.kind != .Integer do return
		if value, ok := strconv.parse_i64_maybe_prefixed(lit.tok.text); !ok || value != 1 do return
		fix = {plus.pos.offset, plus.end.offset, "Remove '+ 1' from the range end", node_text(ctx.src, plus.left)}
	case:
		return
	}

	append(
		diags,
		Diagnostic {
			range = common.get_token_range(bin, ctx.src),
			severity = .Warning,
			code = "range-off-by-one",
			message = fmt.tprintf("'%s%s' runs one past the end", bin.op.text, node_text(ctx.src, bin.right)),
		},
	)
	append(&ctx.fixes, fix)
}

// Evaluating the expression twice cannot change anything: no calls, no `or_return`, no dereference.
@(private = "file")
loop_side_effect_free :: proc(expr: ^ast.Expr) -> bool {
	if expr == nil do return false
	#partial switch e in expr.derived {
	case ^ast.Ident, ^ast.Basic_Lit, ^ast.Implicit_Selector_Expr:
		return true
	case ^ast.Selector_Expr:
		return loop_side_effect_free(e.expr)
	case ^ast.Paren_Expr:
		return loop_side_effect_free(e.expr)
	case ^ast.Unary_Expr:
		return loop_side_effect_free(e.expr)
	case ^ast.Binary_Expr:
		return loop_side_effect_free(e.left) && loop_side_effect_free(e.right)
	case ^ast.Index_Expr:
		return loop_side_effect_free(e.expr) && loop_side_effect_free(e.index)
	}
	return false
}
