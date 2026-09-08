package server

import "core:fmt"
import "core:odin/ast"

import "src:common"

// A name is used when some identifier with the same name appears after the declaration ends.
// A later shadowing declaration therefore hides the outer one; that only loses reports.
lint_unused_variable :: proc(ctx: ^LintContext, node: ^ast.Node, diags: ^[dynamic]Diagnostic) {
	if !ctx.config.enable_lint_unused_variable do return
	lit := node.derived.(^ast.Proc_Lit) or_else nil
	if lit == nil || lit.body == nil do return

	uses := collect_ident_uses(lit.body)

	for decl in body_decls(lit.body) {
		if decl.is_using do continue
		for name in decl.names {
			ident := name.derived.(^ast.Ident) or_continue
			if ident.name == "_" do continue
			if used_after(uses, ident.name, decl.end.offset) do continue
			append(
				diags,
				Diagnostic {
					range = common.get_token_range(ident, ctx.src),
					severity = .Hint,
					code = "unused-variable",
					message = fmt.tprintf("'%s' declared but not used", ident.name),
					tags = {.Unnecessary},
				},
			)
			add_unused_variable_fixes(ctx, decl, ident)
		}
	}
}

// Value declarations at any depth in the body. A nested procedure literal is its own scope and
// the lint walker reaches it separately.
@(private = "file")
body_decls :: proc(body: ^ast.Stmt) -> []^ast.Value_Decl {
	decls := make([dynamic]^ast.Value_Decl, context.temp_allocator)
	visitor := ast.Visitor {
		data = &decls,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil do return nil
			#partial switch n in node.derived {
			case ^ast.Proc_Lit:
				return nil
			case ^ast.Value_Decl:
				append((^[dynamic]^ast.Value_Decl)(visitor.data), n)
			}
			return visitor
		},
	}
	ast.walk(&visitor, body)
	return decls[:]
}

@(private = "file")
used_after :: proc(uses: []IdentUse, name: string, offset: int) -> bool {
	for use in uses {
		if use.ident.name == name && use.ident.pos.offset >= offset do return true
	}
	return false
}

@(private = "file")
add_unused_variable_fixes :: proc(ctx: ^LintContext, decl: ^ast.Value_Decl, ident: ^ast.Ident) {
	if len(decl.names) != 1 || !alone_on_line(ctx.src, decl) {
		append(&ctx.fixes, Lint_Fix{ident.pos.offset, ident.end.offset, "Replace with `_`", "_"})
		return
	}

	if !any_side_effect(decl.values) {
		start, end := whole_lines(ctx.src, decl.pos.offset, decl.end.offset)
		append(&ctx.fixes, Lint_Fix{start, end, "Remove declaration", ""})
	}

	// `_ := v` is not valid, so the value keeps its name and a discard follows it.
	if len(decl.values) > 0 {
		indent := get_line_indentation(ctx.src, decl.pos.offset)
		text := fmt.tprintf("%s\n%s_ = %s", node_text(ctx.src, decl), indent, ident.name)
		append(&ctx.fixes, Lint_Fix{decl.pos.offset, decl.end.offset, "Replace with `_`", text})
	} else {
		append(&ctx.fixes, Lint_Fix{ident.pos.offset, ident.end.offset, "Replace with `_`", "_"})
	}
}

@(private = "file")
any_side_effect :: proc(values: []^ast.Expr) -> bool {
	for value in values {
		if has_side_effect(value) do return true
	}
	return false
}
