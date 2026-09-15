#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:strings"

import "src:common"

@(private = "package")
add_checker_fix_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_checker_fix {
		return
	}

	selection := range_of(ctx, ctx.range.start, ctx.range.end)

	for diagnostic in diagnostics_of(.Check, ctx.uri, context.temp_allocator) {
		line := diagnostic.range.start.line
		if line < selection.start.line || selection.end.line < line {
			continue
		}
		offset, ok := common.get_absolute_position(diagnostic.range.start, ctx.document.text[:ctx.document.used_text])
		if !ok {
			continue
		}
		if name, is_unused := unused_name(diagnostic.message); is_unused {
			add_unused_fixes(ctx, offset, name)
		} else if strings.has_prefix(diagnostic.message, "Unneeded cast") {
			add_conversion_fix(ctx, offset, "Remove cast")
		} else if strings.has_prefix(diagnostic.message, "Unneeded transmute") {
			add_conversion_fix(ctx, offset, "Remove transmute")
		}
	}
}

// The name in `'x' declared but not used`.
unused_name :: proc(message: string) -> (string, bool) {
	if !strings.has_prefix(message, "'") {
		return "", false
	}
	end := strings.index_byte(message[1:], '\'')
	if end < 0 || !strings.has_prefix(message[end + 2:], " declared but not used") {
		return "", false
	}
	return message[1:end + 1], true
}

add_unused_fixes :: proc(ctx: ^ActionContext, offset: int, name: string) {
	decl, ident := unused_decl_at(ctx, offset, name)
	if decl == nil {
		return
	}

	fixes := make([dynamic]Lint_Fix, context.temp_allocator)
	unused_variable_fixes(
		ctx.document.ast.src,
		decl,
		ident,
		fmt.tprintf("Remove '%s'", name),
		fmt.tprintf("Replace '%s' with _", name),
		&fixes,
	)

	for fix, i in fixes {
		edits := make([]TextEdit, 1, context.temp_allocator)
		edits[0] = TextEdit {
			range   = range_of(ctx, fix.start, fix.end),
			newText = fix.text,
		}
		action := make_code_action(ctx, fix.title, "quickfix", edits)
		action.isPreferred = i == len(fixes) - 1
		append(ctx.actions, action)
	}
}

unused_decl_at :: proc(ctx: ^ActionContext, offset: int, name: string) -> (^ast.Value_Decl, ^ast.Ident) {
	#reverse for at in nodes_at(ctx.document.ast.decls[:], offset) {
		ident := at.node.derived.(^ast.Ident) or_continue
		if ident.name != name || at.parent == nil {
			continue
		}
		decl := at.parent.derived.(^ast.Value_Decl) or_continue
		for decl_name in decl.names {
			if (decl_name.derived.(^ast.Ident) or_else nil) == ident {
				return decl, ident
			}
		}
	}
	return nil, nil
}

add_conversion_fix :: proc(ctx: ^ActionContext, offset: int, title: string) {
	// Innermost first: an outer conversion starts before the one the checker reported.
	#reverse for at in nodes_at(ctx.document.ast.decls[:], offset) {
		operand: ^ast.Expr
		#partial switch n in at.node.derived {
		case ^ast.Type_Cast:
			operand = n.expr
		case ^ast.Call_Expr:
			// A conversion `T(x)` parses as a call.
			if len(n.args) == 1 {
				operand = n.args[0]
			}
		}
		if operand == nil {
			continue
		}
		edits := make([]TextEdit, 1, context.temp_allocator)
		edits[0] = TextEdit {
			range   = range_of(ctx, at.node.pos.offset, at.node.end.offset),
			newText = node_text(ctx.document.ast.src, operand),
		}
		action := make_code_action(ctx, title, "quickfix", edits)
		action.isPreferred = true
		append(ctx.actions, action)
		return
	}
}
