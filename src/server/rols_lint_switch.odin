package server

import "core:odin/ast"
import "core:slice"

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
				tags = unnecessary_tags,
			},
		)
		start, end := whole_lines(ctx.src, last.pos.offset, last.end.offset)
		append(&ctx.fixes, Lint_Fix{start, end, "Remove break", "", "unnecessary-break"})
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
	cases, all_named := case_names(body)
	if !all_named do return
	if !switch_is_complete(ctx, subject, cases) do return

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
			message = "#partial is unnecessary: every value has a case",
			tags = unnecessary_tags,
		},
	)
	append(&ctx.fixes, Lint_Fix{start, node.pos.offset, "Remove #partial", "", "redundant-partial"})
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

// Whether the cases cover every enum value, or name every type of a union's variants.
@(private = "file")
switch_is_complete :: proc(ctx: ^LintContext, subject: ^ast.Expr, cases: map[string]struct{}) -> bool {
	#partial switch _ in subject.derived {
	case ^ast.Ident, ^ast.Selector_Expr:
	case:
		return false
	}
	resolved := lint_symbols(ctx)[uintptr(subject)] or_return
	if resolved.is_unresolved || resolved.symbol == nil do return false

	#partial switch v in resolved.symbol.value {
	case SymbolEnumValue:
		for name in cases {
			if !slice.contains(v.names, name) do return false
		}
		if len(cases) == len(v.names) do return true
		// Without an explicit value every member is distinct, so a missing name is a missing value.
		explicit := false
		for value in v.values {
			if value != nil {
				explicit = true
				break
			}
		}
		if !explicit do return false
		// Member values may name constants of the enum's own package.
		ast_context := package_ast_context(
			ctx.document.ast,
			ctx.document.imports,
			ctx.document.package_name,
			ctx.document.uri.uri,
			ctx.document.fullpath,
			resolved.symbol.pkg,
		)
		return len(uncovered_enum_members(&ast_context, v, cases)) == 0
	case SymbolUnionValue:
		if len(cases) != len(v.types) do return false
		for type in v.types {
			name := get_used_switch_name(type) or_return
			if name not_in cases do return false
		}
		return true
	}
	return false
}

// The members a switch still needs a case for: the first member of each value class that no case names.
// An alias such as `FIRST = A` shares A's class, so a case on either covers both.
uncovered_enum_members :: proc(ast_context: ^AstContext, v: SymbolEnumValue, cases: map[string]struct{}) -> []string {
	_, classes := enum_member_values(ast_context, v)
	covered := make([]bool, len(v.names), context.temp_allocator)
	for name, i in v.names {
		if name in cases do covered[classes[i]] = true
	}
	uncovered := make([dynamic]string, context.temp_allocator)
	for name, i in v.names {
		if classes[i] == i && !covered[i] do append(&uncovered, name)
	}
	return uncovered[:]
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
