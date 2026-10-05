#+private file

package server

import "core:fmt"
import "core:odin/ast"

import "src:common"

// The quick fix of the redundant-type-assertion lint: one edit per site, so it cannot be a Lint_Fix.
@(private = "package")
add_bind_switch_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_lint_redundant_type_assertion {
		return
	}
	src := string(ctx.document.text[:ctx.document.used_text])
	for at in nodes_at(ctx.document.ast.decls[:], ctx.range.start) {
		n := at.node.derived.(^ast.Type_Switch_Stmt) or_continue
		m := match_switch_binding(src, ctx.document.ast.decls[:], n) or_continue
		if !on_switch(n, m, ctx.range) {
			continue
		}
		append(ctx.actions, make_code_action(ctx, "Bind the switch variant", "quickfix", bind_edits(ctx, n, m)))
	}
}

// The switch header up to `in s`, or a reported assertion.
on_switch :: proc(n: ^ast.Type_Switch_Stmt, m: Bind_Match, range: common.AbsoluteRange) -> bool {
	if n.switch_pos.offset <= range.start && range.end <= m.tag.end.offset {
		return true
	}
	for site in m.sites {
		if site.pos.offset <= range.start && range.end <= site.end.offset {
			return true
		}
	}
	return false
}

bind_edits :: proc(ctx: ^ActionContext, n: ^ast.Type_Switch_Stmt, m: Bind_Match) -> []TextEdit {
	name := m.name if m.name != "" else binding_name(ctx, n)
	ref := fmt.tprintf("&%s", name)
	binding := m.tag.lhs[0]
	edits := make([dynamic]TextEdit, context.temp_allocator)

	switch {
	case m.bare:
		at := m.tag.op.pos.offset
		text := ref if m.need_ref else name
		append(&edits, TextEdit{range = range_of(ctx, at, at), newText = fmt.tprintf("%s ", text)})
	case m.name == "":
		text := ref if m.need_ref || m.is_ref else name
		append(&edits, TextEdit{range = range_of(ctx, binding.pos.offset, binding.end.offset), newText = text})
	case m.need_ref && !m.is_ref:
		append(&edits, TextEdit{range = range_of(ctx, binding.pos.offset, binding.pos.offset), newText = "&"})
	}

	for e in m.edits {
		text := "" if e.form == .Delete else (ref if e.form == .Ref else name)
		append(&edits, TextEdit{range = range_of(ctx, e.start, e.end), newText = text})
	}
	return edits[:]
}

// v, else v2, v3... free at the switch and unused in its body, so it captures no name there.
binding_name :: proc(ctx: ^ActionContext, n: ^ast.Type_Switch_Stmt) -> string {
	body_names := make(map[string]struct{}, context.temp_allocator)
	for use in collect_ident_uses(n.body) do body_names[use.ident.name] = {}
	probe: ast.Ident
	probe.pos = n.switch_pos
	probe.name = "v"
	for i := 2; (probe.name in body_names) || is_taken(ctx, probe); i += 1 {
		probe.name = fmt.tprintf("v%d", i)
	}
	return probe.name
}
