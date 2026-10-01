#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"

@(private = "package")
add_named_results_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_named_results {
		return
	}

	lit: ^ast.Proc_Lit
	#reverse for at in nodes_at(ctx.document.ast.decls[:], ctx.range.start) {
		if l, is_lit := at.node.derived.(^ast.Proc_Lit); is_lit {
			if _, in_decl := at.parent.derived.(^ast.Value_Decl); in_decl {
				lit = l
			}
			break
		}
	}
	if lit == nil || lit.type == nil || lit.type.results == nil {
		return
	}
	pos := ctx.range.start
	if pos < lit.type.pos.offset || lit.type.end.offset < pos {
		return
	}

	taken := signature_names(lit)

	// Edits touch only names and a bare result's type, so defaults, comments and line breaks stay as written.
	src := ctx.document.ast.src
	edits := make([dynamic]TextEdit, context.temp_allocator)
	for field in lit.type.results.list {
		// Only an unparenthesized result has no names.
		if field.names == nil {
			text := fmt.tprintf("(%s: %s)", fresh_result_name(&taken, field.type), node_text(src, field.type))
			append(
				&edits,
				TextEdit{range = range_of(ctx, field.type.pos.offset, field.type.end.offset), newText = text},
			)
			continue
		}
		// The parser names an unnamed result in parentheses `_`, starting where its type does.
		if field.type != nil && field.names[0].pos.offset == field.type.pos.offset {
			name := fresh_result_name(&taken, field.type)
			at := field.type.pos.offset
			append(
				&edits,
				TextEdit {
					range = range_of(ctx, at, at),
					newText = strings.concatenate({name, ": "}, context.temp_allocator),
				},
			)
			continue
		}
		for name in field.names {
			if text := final_name(name); text != "" && text != "_" {
				continue
			}
			// A field like `_ := false` has no type to name it after.
			fresh := field.type != nil ? fresh_result_name(&taken, field.type) : take_result_name(&taken, "result")
			append(&edits, TextEdit{range = range_of(ctx, name.pos.offset, name.end.offset), newText = fresh})
		}
	}
	if len(edits) == 0 {
		return
	}
	append(ctx.actions, make_code_action(ctx, "Use named results", "refactor.rewrite", edits[:]))
}

// The parameter and result names of a procedure literal, as a list new names are added to.
@(private = "package")
signature_names :: proc(lit: ^ast.Proc_Lit) -> [dynamic]string {
	taken := make([dynamic]string, context.temp_allocator)
	for list in ([]^ast.Field_List{lit.type.params, lit.type.results}) {
		if list == nil {
			continue
		}
		for field in list.list {
			for name in field.names {
				append(&taken, final_name(name))
			}
		}
	}
	return taken
}

// The offsets of a result list with its parentheses; the list node excludes them.
@(private = "package")
result_list_range :: proc(src: string, results: ^ast.Field_List) -> (start, end: int) {
	start, end = results.pos.offset, results.end.offset
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
	return
}

// ok for bool, err for error-like types, the lowercased type name for named types and pointers
// to them, result otherwise. Numbered when taken.
@(private = "package")
fresh_result_name :: proc(taken: ^[dynamic]string, type: ^ast.Expr) -> string {
	type := type
	for {
		ptr, is_ptr := type.derived.(^ast.Pointer_Type)
		if !is_ptr {
			break
		}
		type = ptr.elem
	}
	base := "result"
	switch result_kind(type) {
	case .Bool:
		base = "ok"
	case .Error:
		base = "err"
	case .Other:
		if name := final_name(type); name != "" && name not_in keyword_map {
			base = strings.to_lower(name, context.temp_allocator)
		}
	}
	return take_result_name(taken, base)
}

// base, else base2, base3... whichever is not taken yet, then marks it taken.
@(private = "package")
take_result_name :: proc(taken: ^[dynamic]string, base: string) -> string {
	name := base
	for i := 2; slice.contains(taken[:], name); i += 1 {
		name = fmt.tprintf("%s%d", base, i)
	}
	append(taken, name)
	return name
}
