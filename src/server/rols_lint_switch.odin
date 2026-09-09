package server

import "core:odin/ast"

import "src:common"

lint_switch :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_switch do return

	#partial switch n in node.derived {
	case ^ast.Switch_Stmt:
		if !n.partial do return
		redundant_partial(ctx, node, n.body, n.cond, diags)
	case ^ast.Type_Switch_Stmt:
		if !n.partial do return
		assign, is_assign := n.tag.derived.(^ast.Assign_Stmt)
		if !is_assign || len(assign.rhs) != 1 do return
		redundant_partial(ctx, node, n.body, assign.rhs[0], diags)
	case ^ast.Case_Clause:
		if len(n.body) == 0 do return
		last := n.body[len(n.body) - 1]
		branch, is_branch := last.derived.(^ast.Branch_Stmt)
		// A break statement directly in a clause body targets the switch, never an outer loop.
		if !is_branch || branch.tok.kind != .Break || branch.label != nil do return
		append(
			diags,
			Diagnostic {
				range = common.get_token_range(branch, ctx.src),
				severity = .Hint,
				code = "unnecessary-break",
				message = "break at the end of a case does nothing",
				tags = {.Unnecessary},
			},
		)
		start, end := whole_lines(ctx.src, last.pos.offset, last.end.offset)
		append(&ctx.fixes, Lint_Fix{start, end, "Remove break", ""})
	}
}

@(private = "file")
redundant_partial :: proc(
	ctx: ^LintContext,
	node: ^ast.Node,
	body: ^ast.Stmt,
	subject: ^ast.Expr,
	diags: ^[dynamic]Diagnostic,
) {
	members, has_members := switch_members(ctx, subject)
	if !has_members do return
	cases, all_named := case_names(body)
	if !all_named || len(cases) != len(members) do return
	for member in members {
		if member not_in cases do return
	}

	start, is_partial := partial_start(ctx.src, node.pos.offset)
	if !is_partial do return
	append(
		diags,
		Diagnostic {
			range = {
				start = common.get_relative_token_position(start, ctx.document.text, 0),
				end = common.get_relative_token_position(start + len("#partial"), ctx.document.text, 0),
			},
			severity = .Hint,
			code = "redundant-partial",
			message = "#partial is unnecessary: every case is listed",
			tags = {.Unnecessary},
		},
	)
	append(&ctx.fixes, Lint_Fix{start, node.pos.offset, "Remove #partial", ""})
}

// The switch statement starts at the `switch` token, so `#partial` is found by scanning back.
@(private = "file")
partial_start :: proc(src: string, switch_offset: int) -> (int, bool) {
	end := switch_offset
	for end > 0 && (src[end - 1] == ' ' || src[end - 1] == '\t') do end -= 1
	start := end - len("#partial")
	if start < 0 || src[start:end] != "#partial" do return 0, false
	return start, true
}

// Enum member names, or the type names of a union's variants.
@(private = "file")
switch_members :: proc(ctx: ^LintContext, subject: ^ast.Expr) -> (names: []string, ok: bool) {
	#partial switch _ in subject.derived {
	case ^ast.Ident, ^ast.Selector_Expr:
	case:
		return
	}
	resolved := lint_symbols(ctx)[uintptr(subject)] or_return
	if resolved.is_unresolved || resolved.symbol == nil do return

	#partial switch v in resolved.symbol.value {
	case SymbolEnumValue:
		return v.names, true
	case SymbolUnionValue:
		names = make([]string, len(v.types), context.temp_allocator)
		for type, i in v.types {
			names[i] = get_used_switch_name(type) or_return
		}
		return names, true
	}
	return
}

// The name of every case value, or ok = false when a clause is a default or a form we cannot name.
@(private = "file")
case_names :: proc(body: ^ast.Stmt) -> (names: map[string]struct{}, ok: bool) {
	block := body.derived.(^ast.Block_Stmt) or_return
	names = make(map[string]struct{}, context.temp_allocator)
	for stmt in block.stmts {
		clause := stmt.derived.(^ast.Case_Clause) or_return
		if len(clause.list) == 0 do return
		for expr in clause.list {
			names[get_used_switch_name(expr) or_return] = {}
		}
	}
	return names, true
}
