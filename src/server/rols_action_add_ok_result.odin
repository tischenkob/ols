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
	// Both tags require exactly two results, so a third one would not compile.
	if lit.type.tags & {.Optional_Ok, .Optional_Allocator_Error} != {} {
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

		// Falling off the end is the success path, and a bool result makes it a missing return.
		block := lit.body.derived_stmt.(^ast.Block_Stmt)
		ends_in_return := false
		if n := len(block.stmts); n > 0 {
			_, ends_in_return = block.stmts[n - 1].derived_stmt.(^ast.Return_Stmt)
		}
		if !ends_in_return {
			ind := get_line_indentation(src, decl.pos.offset)
			first: ^ast.Stmt
			if len(block.stmts) > 0 {
				first = block.stmts[0]
			}
			close := block.close.offset
			for close > 0 && strings.is_space(rune(src[close - 1])) {
				close -= 1
			}
			text := fmt.tprintf("\n%s%sreturn true", ind, indent_unit(src, ind, first))
			append(&edits, TextEdit{range = range_of(ctx, close, close), newText = text})
		}
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
		// The parser gives an unnamed result a synthesised name at the type's own position, so
		// counting names would read `(int, bool)` as named and write a list mixing the two forms.
		for field in results.list {
			for name in field.names {
				if field.type != nil && name.pos.offset == field.type.pos.offset {
					continue
				}
				named = true
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
