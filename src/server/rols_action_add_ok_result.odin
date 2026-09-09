#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"

@(private = "package")
add_add_ok_result_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_add_ok_result {
		return
	}

	decl: ^ast.Value_Decl
	lit: ^ast.Proc_Lit
	for at in nodes_at(ctx.document.ast.decls[:], ctx.range.start) {
		d, is_decl := at.node.derived.(^ast.Value_Decl)
		if !is_decl || len(d.values) != 1 {
			continue
		}
		if l, is_lit := d.values[0].derived.(^ast.Proc_Lit); is_lit {
			decl, lit = d, l
		}
	}
	if lit == nil || lit.type == nil || lit.body == nil {
		return
	}

	pos := ctx.range.start
	results := lit.type.results
	on_target := results != nil && results.pos.offset <= pos && pos <= results.end.offset
	for name in decl.names {
		on_target ||= name.pos.offset <= pos && pos <= name.end.offset
	}
	if !on_target {
		return
	}

	src := ctx.document.ast.src
	edits := make([dynamic]TextEdit, context.temp_allocator)

	if results == nil {
		// Before the body brace rather than at the proc type end, which a where clause extends.
		at := lit.body.pos.offset
		for at > 0 && strings.is_space(rune(src[at - 1])) {
			at -= 1
		}
		append(&edits, TextEdit{range = range_of(ctx, at, at), newText = " -> bool"})
	} else {
		named := false
		taken := make([dynamic]string, context.temp_allocator)
		if lit.type.params != nil {
			for field in lit.type.params.list {
				for name in field.names {
					append(&taken, final_name(name))
				}
			}
		}
		for field in results.list {
			named ||= len(field.names) > 0
			for name in field.names {
				append(&taken, final_name(name))
			}
		}

		text: string
		inner := src[results.pos.offset:results.end.offset]
		if named {
			ok := "ok"
			for i := 2; slice.contains(taken[:], ok); i += 1 {
				ok = fmt.tprintf("ok%d", i)
			}
			text = fmt.tprintf("(%s, %s: bool)", inner, ok)
		} else {
			text = fmt.tprintf("(%s, bool)", inner)
		}

		// The result list node excludes its parentheses.
		start, end := results.pos.offset, results.end.offset
		open := start
		for open > 0 && strings.is_space(rune(src[open - 1])) {
			open -= 1
		}
		if open > 0 && src[open - 1] == '(' {
			start = open - 1
		}
		close := end
		for close < len(src) && strings.is_space(rune(src[close])) {
			close += 1
		}
		if close < len(src) && src[close] == ')' {
			end = close + 1
		}
		append(&edits, TextEdit{range = range_of(ctx, start, end), newText = text})
	}

	for ret in body_returns(lit.body) {
		if len(ret.results) == 0 {
			// A bare return still works once every result is named.
			if results != nil {
				continue
			}
			append(&edits, TextEdit{range = range_of(ctx, ret.end.offset, ret.end.offset), newText = " true"})
		} else {
			append(&edits, TextEdit{range = range_of(ctx, ret.end.offset, ret.end.offset), newText = ", true"})
		}
	}

	append(ctx.actions, make_code_action(ctx, "Add ok result", "refactor.rewrite", edits[:]))
}

// Returns of this procedure, skipping those of nested procedure literals.
body_returns :: proc(body: ^ast.Stmt) -> []^ast.Return_Stmt {
	found := make([dynamic]^ast.Return_Stmt, context.temp_allocator)
	visitor := ast.Visitor {
		data = &found,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			#partial switch n in node.derived {
			case ^ast.Proc_Lit:
				return nil
			case ^ast.Return_Stmt:
				append((^[dynamic]^ast.Return_Stmt)(visitor.data), n)
				return nil
			}
			return visitor
		},
	}
	ast.walk(&visitor, body)
	return found[:]
}
