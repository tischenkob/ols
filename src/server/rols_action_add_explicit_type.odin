#+private file

package server

import "core:odin/ast"
import "core:strings"

@(private = "package")
add_explicit_type_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_add_explicit_type {
		return
	}

	decl := ctx.position_context.value_decl
	if decl == nil || !decl.is_mutable || decl.type != nil || len(decl.names) != 1 || len(decl.values) != 1 {
		return
	}
	name, is_ident := decl.names[0].derived.(^ast.Ident)
	value := decl.values[0]
	if !is_ident || name.name == "_" || ctx.range.start < decl.pos.offset || value.pos.offset < ctx.range.end {
		return
	}

	// Locals are gathered up to the cursor only, so re-gather at the declaration end to resolve
	// the name.
	pc := ctx.position_context^
	pc.position = decl.end.offset
	pc.nested_position = decl.end.offset
	clear_locals(ctx.ast_context)
	get_locals(ctx.ast_context, &pc)

	callee: Symbol
	callee_ok: bool
	if call, is_call := value.derived.(^ast.Call_Expr); is_call {
		callee, callee_ok = resolve_type_expression(ctx.ast_context, call.expr)
	}
	if value_states_type(value, callee, callee_ok) {
		return
	}

	text, ok := local_type_text(ctx, name)
	if !ok {
		return
	}

	edits := make([]TextEdit, 1, context.temp_allocator)
	edits[0] = TextEdit {
		range   = range_of(ctx, name.end.offset, value.pos.offset),
		newText = strings.concatenate({": ", text, " = "}, context.temp_allocator),
	}
	append(ctx.actions, make_code_action(ctx, "Add explicit type", "refactor.rewrite", edits))
}
