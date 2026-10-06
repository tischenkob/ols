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
		loop_single_iteration(ctx, n.for_pos, n.body, n.label, diags)
		loop_condition_constant(ctx, n, diags)
		empty_loop(ctx, n, diags)
	case ^ast.Range_Stmt:
		loop_single_iteration(ctx, n.for_pos, n.body, n.label, diags)
		range_off_by_one(ctx, n, diags)
		range_map_lookup(ctx, n, diags)
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

@(private = "file")
Jump_Scan :: struct {
	using jumps: Loop_Jumps,
	name:        string, // this loop's label, "" when it has none
}

@(private = "file")
label_name :: proc(label: ^ast.Expr) -> string {
	if label == nil do return ""
	ident, is_ident := label.derived.(^ast.Ident)
	return is_ident ? ident.name : ""
}

// Jumps that belong to this loop. A nested loop owns its unlabelled jumps but a jump labelled with
// this loop's name is ours wherever it sits. A proc literal's jumps belong to that proc.
@(private = "file")
loop_jumps :: proc(body: ^ast.Stmt, label: ^ast.Expr) -> Loop_Jumps {
	scan := Jump_Scan {
		name = label_name(label),
	}
	visitor := ast.Visitor {
		data = &scan,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			scan := (^Jump_Scan)(visitor.data)
			#partial switch n in node.derived {
			case ^ast.For_Stmt, ^ast.Range_Stmt, ^ast.Unroll_Range_Stmt:
				labelled_jumps(node, scan)
				return nil
			case ^ast.Proc_Lit:
				return nil
			case ^ast.Return_Stmt:
				scan.jumps.has_exit = true
			case ^ast.Or_Branch_Expr:
				#partial switch n.token.kind {
				case .Or_Continue:
					scan.jumps.has_continue = true
				case .Or_Break, .Or_Return:
					scan.jumps.has_exit = true
				}
			case ^ast.Branch_Stmt:
				#partial switch n.tok.kind {
				case .Continue:
					scan.jumps.has_continue = true
				case .Break:
					scan.jumps.has_exit = true
				}
			}
			return visitor
		},
	}
	ast.walk(&visitor, body)
	return scan.jumps
}

@(private = "file")
labelled_jumps :: proc(loop: ^ast.Node, scan: ^Jump_Scan) {
	if scan.name == "" do return
	visitor := ast.Visitor {
		data = scan,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			scan := (^Jump_Scan)(visitor.data)
			#partial switch n in node.derived {
			case ^ast.Proc_Lit:
				return nil
			case ^ast.Branch_Stmt:
				if label_name(n.label) == scan.name {
					#partial switch n.tok.kind {
					case .Continue:
						scan.jumps.has_continue = true
					case .Break:
						scan.jumps.has_exit = true
					}
				}
			}
			return visitor
		},
	}
	ast.walk(&visitor, loop)
}

@(private = "file")
loop_single_iteration :: proc(
	ctx: ^LintContext,
	for_pos: tokenizer.Pos,
	body: ^ast.Stmt,
	label: ^ast.Expr,
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
	if !exits || loop_jumps(body, label).has_continue do return

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
	if len(names) == 0 || loop_jumps(n.body, n.label).has_exit do return
	if condition_global_call(ctx, n) do return

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

// A call in the body can reach a global the condition reads, without naming it here. An identifier
// that does not resolve is assumed global for the same reason.
@(private = "file")
condition_global_call :: proc(ctx: ^LintContext, n: ^ast.For_Stmt) -> bool {
	if !loop_body_has_call(n.body) do return false
	for use in collect_ident_uses(n.cond) {
		resolved, ok := lint_symbols(ctx)[uintptr(use.ident)]
		if !ok || resolved.is_unresolved do return true
		if .Local not_in resolved.symbol.flags && .Mutable in resolved.symbol.flags do return true
	}
	return false
}

@(private = "file")
loop_body_has_call :: proc(body: ^ast.Stmt) -> (found: bool) {
	visitor := ast.Visitor {
		data = &found,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			if _, is_call := node.derived.(^ast.Call_Expr); is_call {
				(^bool)(visitor.data)^ = true
				return nil
			}
			return visitor
		},
	}
	ast.walk(&visitor, body)
	return
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
	// Only a range starting at 0 has len(x) as its one-past-the-end bound.
	low, is_low := unparen(bin.left).derived.(^ast.Basic_Lit)
	if !is_low || low.tok.kind != .Integer || low.tok.text != "0" do return

	fix: Lint_Fix
	bound: ^ast.Expr // the collection whose len ends the range
	#partial switch bin.op.kind {
	case .Range_Full:
		ok: bool
		bound, ok = len_call(bin.right)
		if !ok do return
		fix = {
			bin.op.pos.offset,
			bin.op.pos.offset + len(bin.op.text),
			"Use ..< instead of ..=",
			"..<",
			"range-off-by-one",
		}
	case .Range_Half:
		plus, is_plus := unparen(bin.right).derived.(^ast.Binary_Expr)
		if !is_plus || plus.op.kind != .Add do return
		ok: bool
		bound, ok = len_call(plus.left)
		if !ok do return
		lit, is_lit := unparen(plus.right).derived.(^ast.Basic_Lit)
		if !is_lit || lit.tok.kind != .Integer do return
		if value, ok := strconv.parse_i64_maybe_prefixed(lit.tok.text); !ok || value != 1 do return
		fix = {
			plus.pos.offset,
			plus.end.offset,
			"Remove '+ 1' from the range end",
			node_text(ctx.src, plus.left),
			"range-off-by-one",
		}
	case:
		return
	}

	if intentional_inclusive(ctx, n, bound) do return

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

// `for b in 0 ..= len(s)` is intended when the loop variable only addresses the end of something
// else: a slice bound (`s[:b]`), another collection (`adv[b]` sized len+1), or `s[b]` behind a
// `b < len(s)` guard. Any unguarded `s[b]` still reads one past the end, so it keeps the warning.
@(private = "file")
intentional_inclusive :: proc(ctx: ^LintContext, n: ^ast.Range_Stmt, bound: ^ast.Expr) -> bool {
	if len(n.vals) == 0 || n.body == nil do return false
	val := n.vals[0].derived.(^ast.Ident) or_else nil
	if val == nil do return false

	bound_text := node_text(ctx.src, bound)
	evidence := false
	for use in collect_ident_uses(n.body) {
		if use.ident.name != val.name do continue
		if len(use.parents) == 0 do continue
		parent := use.parents[len(use.parents) - 1]
		#partial switch p in parent.derived {
		case ^ast.Slice_Expr:
			if p.low == use.ident || p.high == use.ident do evidence = true
		case ^ast.Index_Expr:
			if p.index != use.ident do continue
			if node_text(ctx.src, p.expr) != bound_text || guarded_by_len(ctx, use.ident, use.parents, bound_text) {
				evidence = true
			} else {
				return false
			}
		}
	}
	return evidence
}

// Whether an enclosing `if` keeps the loop variable below len(collection), written out or through a
// local `n := len(collection)`. The then-branch needs a comparison that holds only for `v < L`, such
// as `v < L`, `v <= L - 1`, `v + 1 <= L`, `!(v >= L)` or `v != L`, as the condition or a top-level
// `&&` operand. The else-branch needs one that fails only for `v < L`, such as `v >= L` or `v == L`, as
// the condition or a top-level `||` operand. A use inside the condition is guarded only by the left
// operand of an enclosing `&&` (that holds) or `||` (that failed). A use in the init runs before the
// condition.
@(private = "file")
guarded_by_len :: proc(ctx: ^LintContext, use: ^ast.Ident, parents: []^ast.Node, collection: string) -> bool {
	for parent in parents {
		if_stmt, is_if := parent.derived.(^ast.If_Stmt)
		if !is_if || if_stmt.cond == nil do continue
		guard := Len_Guard{ctx, use.name, collection}
		switch {
		case contains_offset(if_stmt.cond, use.pos.offset):
			if guards_in_condition(guard, if_stmt.cond, use.pos.offset) do return true
		case contains_offset(if_stmt.body, use.pos.offset):
			if guards_branch(guard, if_stmt.cond, true) do return true
		case contains_offset(if_stmt.else_stmt, use.pos.offset):
			if guards_branch(guard, if_stmt.cond, false) do return true
		}
	}
	return false
}

@(private = "file")
Len_Guard :: struct {
	ctx:        ^LintContext,
	var:        string,
	collection: string,
}

@(private = "file")
contains_offset :: proc(node: ^ast.Node, offset: int) -> bool {
	return node != nil && node.pos.offset <= offset && offset < node.end.offset
}

// Whether cond, when it holds (then) or fails (else), keeps the variable below the length.
@(private = "file")
guards_branch :: proc(guard: Len_Guard, cond: ^ast.Expr, then: bool) -> bool {
	#partial switch e in unparen(cond).derived {
	case ^ast.Unary_Expr:
		return e.op.kind == .Not && guards_branch(guard, e.expr, !then)
	case ^ast.Binary_Expr:
		#partial switch e.op.kind {
		case .Cmp_And:
			return then && (guards_branch(guard, e.left, then) || guards_branch(guard, e.right, then))
		case .Cmp_Or:
			return !then && (guards_branch(guard, e.left, then) || guards_branch(guard, e.right, then))
		}
		return guards_comparison(guard, e, then)
	}
	return false
}

// A comparison of `v + a` with `L + l`, either way round, read as `v op L + k` with k = l - a. It
// keeps v below L when it holds (then) or fails (else), for every v of the range 0 ..= L.
@(private = "file")
guards_comparison :: proc(guard: Len_Guard, bin: ^ast.Binary_Expr, then: bool) -> bool {
	op := bin.op.kind
	var_add, var_ok := var_term(guard, bin.left)
	len_add, len_ok := len_term(guard, bin.right)
	if !var_ok || !len_ok {
		var_add, var_ok = var_term(guard, bin.right)
		len_add, len_ok = len_term(guard, bin.left)
		if !var_ok || !len_ok do return false
		#partial switch op {
		case .Lt:
			op = .Gt
		case .Gt:
			op = .Lt
		case .Lt_Eq:
			op = .Gt_Eq
		case .Gt_Eq:
			op = .Lt_Eq
		}
	}
	if !then {
		// The else-branch runs when the comparison fails.
		#partial switch op {
		case .Lt:
			op = .Gt_Eq
		case .Gt_Eq:
			op = .Lt
		case .Gt:
			op = .Lt_Eq
		case .Lt_Eq:
			op = .Gt
		case .Cmp_Eq:
			op = .Not_Eq
		case .Not_Eq:
			op = .Cmp_Eq
		}
	}
	k := len_add - var_add
	#partial switch op {
	case .Lt:
		return k <= 0
	case .Lt_Eq:
		return k <= -1
	case .Not_Eq:
		// The range ends at L, so v != L leaves v < L.
		return k == 0
	}
	return false
}

// expr as `base + n`, `base - n` or `n + base` with n an integer literal. Any other expr is its own
// base with n = 0.
@(private = "file")
offset_term :: proc(expr: ^ast.Expr) -> (base: ^ast.Expr, n: int) {
	base = unparen(expr)
	bin, is_bin := base.derived.(^ast.Binary_Expr)
	if !is_bin || (bin.op.kind != .Add && bin.op.kind != .Sub) do return
	if value, is_int := int_literal(bin.right); is_int {
		return unparen(bin.left), value if bin.op.kind == .Add else -value
	}
	if value, is_int := int_literal(bin.left); is_int && bin.op.kind == .Add {
		return unparen(bin.right), value
	}
	return
}

@(private = "file")
int_literal :: proc(expr: ^ast.Expr) -> (int, bool) {
	lit, is_lit := unparen(expr).derived.(^ast.Basic_Lit)
	if !is_lit || lit.tok.kind != .Integer do return 0, false
	value, ok := strconv.parse_i64_maybe_prefixed(lit.tok.text)
	return int(value), ok
}

@(private = "file")
var_term :: proc(guard: Len_Guard, expr: ^ast.Expr) -> (add: int, ok: bool) {
	base: ^ast.Expr
	base, add = offset_term(expr)
	ident, is_ident := base.derived.(^ast.Ident)
	return add, is_ident && ident.name == guard.var
}

@(private = "file")
len_term :: proc(guard: Len_Guard, expr: ^ast.Expr) -> (add: int, ok: bool) {
	base: ^ast.Expr
	base, add = offset_term(expr)
	if arg, is_len := len_call(base); is_len do return add, node_text(guard.ctx.src, arg) == guard.collection
	ident, is_ident := base.derived.(^ast.Ident)
	return add, is_ident && names_len_local(guard.ctx, ident, guard.collection)
}

// A use inside the condition runs only after the left operand of each enclosing `&&` held and of
// each enclosing `||` failed.
@(private = "file")
guards_in_condition :: proc(guard: Len_Guard, cond: ^ast.Expr, offset: int) -> bool {
	#partial switch e in unparen(cond).derived {
	case ^ast.Unary_Expr:
		return guards_in_condition(guard, e.expr, offset)
	case ^ast.Binary_Expr:
		if contains_offset(e.right, offset) {
			#partial switch e.op.kind {
			case .Cmp_And:
				if guards_branch(guard, e.left, true) do return true
			case .Cmp_Or:
				if guards_branch(guard, e.left, false) do return true
			}
			return guards_in_condition(guard, e.right, offset)
		}
		return guards_in_condition(guard, e.left, offset)
	}
	return false
}

// Whether ident names a local `ident := len(collection)` (or `::`), the declaration of the name
// visible at ident in the same top-level declaration, while the length is still current: nothing in
// the top-level declaration assigns to the name, and nothing after the declaration assigns to the
// collection. A change through a pointer, such as `pop(&s)`, is not seen.
@(private = "file")
names_len_local :: proc(ctx: ^LintContext, ident: ^ast.Ident, collection: string) -> bool {
	top := top_level_stmt_at(ctx.document.ast.decls[:], ident.pos.offset)
	if top == nil do return false
	visible := visible_declaration(ctx, top, ident.name, ident.pos.offset)
	if visible.ident == nil || visible.value == nil do return false
	arg, is_len := len_call(visible.value)
	if !is_len || node_text(ctx.src, arg) != collection do return false

	Data :: struct {
		ctx:        ^LintContext,
		name:       string,
		collection: string,
		from:       int,
		stale:      bool,
	}
	data := Data {
		ctx        = ctx,
		name       = ident.name,
		collection = collection,
		from       = visible.ident.pos.offset,
	}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil || data.stale do return nil
			assign, is_assign := node.derived.(^ast.Assign_Stmt)
			if !is_assign do return visitor
			for lhs in assign.lhs {
				if target, ok := lhs.derived.(^ast.Ident); ok && target.name == data.name do data.stale = true
				if node.pos.offset > data.from && node_text(data.ctx.src, lhs) == data.collection do data.stale = true
			}
			return visitor
		},
	}
	ast.walk(&visitor, top)
	return !data.stale
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

// `for x in m[k]` reads the length through the slot pointer, which is nil for a missing key. Only
// dynamic array, map and fixed array values actually read through it; slice and string values
// iterate zero times, so they are left alone.
@(private = "file")
range_map_lookup :: proc(ctx: ^LintContext, stmt: ^ast.Range_Stmt, diags: ^[dynamic]Diagnostic) {
	if stmt.expr == nil {
		return
	}
	index, is_index := unparen(stmt.expr).derived.(^ast.Index_Expr)
	if !is_index {
		return
	}
	value, is_map, ok := index_element(ctx, index)
	if !ok || !is_map {
		return
	}
	#partial switch t in unparen(value).derived {
	case ^ast.Dynamic_Array_Type, ^ast.Map_Type:
	case ^ast.Array_Type:
		if t.len == nil do return // a slice
	case:
		return
	}
	append(
		diags,
		Diagnostic {
			range = common.get_token_range(stmt.expr, ctx.src),
			severity = .Warning,
			code = "range-map-lookup",
			message = fmt.tprintf(
				"'%s' is a map lookup; bind it to a name before ranging over it",
				node_text(ctx.src, stmt.expr),
			),
		},
	)
}

// The element type expression of one level of indexing, and whether the container indexed is a map.
// Nested lookups like `table[.Kind][key]` resolve the innermost name and follow the element types
// outward; anything else is not judged.
@(private = "file")
index_element :: proc(ctx: ^LintContext, index: ^ast.Index_Expr) -> (elem: ^ast.Expr, is_map: bool, ok: bool) {
	base := unparen(index.expr)
	#partial switch inner in base.derived {
	case ^ast.Ident, ^ast.Selector_Expr:
		resolved := lint_symbols(ctx)[uintptr(base)] or_return
		#partial switch v in resolved.symbol.value {
		case SymbolFixedArrayValue:
			return v.expr, false, true
		case SymbolSliceValue:
			return v.expr, false, true
		case SymbolDynamicArrayValue:
			return v.expr, false, true
		case SymbolMapValue:
			return v.value, true, true
		}
	case ^ast.Index_Expr:
		outer, _ := index_element(ctx, inner) or_return
		#partial switch t in unparen(outer).derived {
		case ^ast.Array_Type:
			return t.elem, false, true
		case ^ast.Dynamic_Array_Type:
			return t.elem, false, true
		case ^ast.Map_Type:
			return t.value, true, true
		}
	}
	return
}
