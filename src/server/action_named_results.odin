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

	taken := make([dynamic]string, context.temp_allocator)
	if lit.type.params != nil {
		for field in lit.type.params.list {
			for name in field.names {
				append(&taken, final_name(name))
			}
		}
	}
	for field in lit.type.results.list {
		for name in field.names {
			append(&taken, final_name(name))
		}
	}

	src := ctx.document.ast.src
	sb := strings.builder_make(context.temp_allocator)
	strings.write_byte(&sb, '(')
	unnamed := 0
	for field, i in lit.type.results.list {
		if i > 0 {
			strings.write_string(&sb, ", ")
		}
		if len(field.names) == 0 {
			unnamed += 1
			strings.write_string(&sb, fresh_result_name(&taken, field.type))
		}
		for name, j in field.names {
			if j > 0 {
				strings.write_string(&sb, ", ")
			}
			text := final_name(name)
			if text == "" || text == "_" {
				unnamed += 1
				text = fresh_result_name(&taken, field.type)
			}
			strings.write_string(&sb, text)
		}
		strings.write_string(&sb, ": ")
		strings.write_string(&sb, node_text(src, field.type))
	}
	strings.write_byte(&sb, ')')
	if unnamed == 0 {
		return
	}

	// The result list node excludes its parentheses.
	results := lit.type.results
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
	append_replace_range(ctx, start, end, "Use named results", strings.to_string(sb))
}

// ok for bool, err for error-like types, the lowercased type name for named types and pointers
// to them, result otherwise. Numbered when taken.
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
	name := base
	for i := 2; slice.contains(taken[:], name); i += 1 {
		name = fmt.tprintf("%s%d", base, i)
	}
	append(taken, name)
	return name
}
