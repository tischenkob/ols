#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:strings"

import "src:common"

@(private = "package")
add_extract_procedure_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_extract_procedure || ctx.range.start >= ctx.range.end {
		return
	}

	function := ctx.position_context.function
	if function == nil || function.body == nil {
		return
	}

	src := ctx.document.ast.src
	start, end := trim_range(src, ctx.range.start, ctx.range.end)
	if start < function.body.pos.offset || function.body.end.offset < end {
		return
	}

	list, found := find_stmt_list_at(function.body, start, end)
	if !found || list.first > list.last {
		return
	}
	stmts := list.stmts[list.first:list.last + 1]
	sel_start := stmts[0].pos.offset
	sel_end := stmts[len(stmts) - 1].end.offset
	if sel_start != start || end < sel_end {
		return
	}

	if !can_extract(stmts) {
		return
	}

	symbols := resolve_entire_file_for_references(ctx.document, context.temp_allocator, .Identifier, "")

	inputs := make([dynamic]Var, context.temp_allocator)
	outputs := make([dynamic]Var, context.temp_allocator)

	for use in collect_ident_uses(function.body) {
		decl, ok := local_decl_offset(ctx, symbols, use.ident)
		if !ok || decl < function.pos.offset {
			continue
		}
		offset := use.ident.pos.offset
		if decl < sel_start {
			if offset < sel_start || sel_end <= offset {
				continue
			}
			// Parameters are immutable, and a local constant or nested proc has no value to pass.
			local, is_local := get_local(ctx.ast_context^, use.ident^)
			if is_write(use) || !is_local || .Mutable not_in local.flags {
				return
			}
			if !has_decl(inputs[:], decl) {
				append(&inputs, Var{use.ident, decl})
			}
		} else if decl < sel_end && sel_end <= offset {
			name, value_decl := decl_name_at(stmts, decl)
			if value_decl == nil {
				continue
			}
			if !value_decl.is_mutable {
				return
			}
			if !has_decl(outputs[:], decl) {
				i := 0
				for i < len(outputs) && outputs[i].decl < decl {
					i += 1
				}
				inject_at(&outputs, i, Var{name, decl})
			}
		}
	}

	// Locals are gathered up to the cursor only, so re-gather at the selection end to resolve
	// declarations inside it.
	pc := ctx.position_context^
	pc.position = sel_end
	pc.nested_position = sel_end
	clear_locals(ctx.ast_context)
	get_locals(ctx.ast_context, &pc)

	name := "extracted"
	for i := 2; (name in ctx.ast_context.globals); i += 1 {
		name = fmt.tprintf("extracted%d", i)
	}

	sb := strings.builder_make(context.temp_allocator)
	strings.write_string(&sb, name)
	strings.write_string(&sb, " :: proc(")
	for input, i in inputs {
		if i > 0 {
			strings.write_string(&sb, ", ")
		}
		strings.write_string(&sb, input.ident.name)
		strings.write_string(&sb, ": ")
		text, ok := local_type_text(ctx, input.ident)
		if !ok {
			return
		}
		strings.write_string(&sb, text)
	}
	strings.write_byte(&sb, ')')
	if len(outputs) > 0 {
		strings.write_string(&sb, " -> ")
		if len(outputs) > 1 {
			strings.write_byte(&sb, '(')
		}
		for output, i in outputs {
			if i > 0 {
				strings.write_string(&sb, ", ")
			}
			text, ok := local_type_text(ctx, output.ident)
			if !ok {
				return
			}
			strings.write_string(&sb, text)
		}
		if len(outputs) > 1 {
			strings.write_byte(&sb, ')')
		}
	}
	strings.write_string(&sb, " {\n")

	line_start := sel_start
	for line_start > 0 && src[line_start - 1] != '\n' {
		line_start -= 1
	}
	strings.write_string(&sb, reindent(src[line_start:sel_end], get_line_indentation(src, sel_start), "\t"))
	strings.write_byte(&sb, '\n')

	call := strings.builder_make(context.temp_allocator)
	if len(outputs) > 0 {
		strings.write_string(&sb, "\treturn ")
		for output, i in outputs {
			if i > 0 {
				strings.write_string(&sb, ", ")
				strings.write_string(&call, ", ")
			}
			strings.write_string(&sb, output.ident.name)
			strings.write_string(&call, output.ident.name)
		}
		strings.write_byte(&sb, '\n')
		strings.write_string(&call, " := ")
	}
	strings.write_byte(&sb, '}')
	strings.write_string(&call, name)
	strings.write_byte(&call, '(')
	for input, i in inputs {
		if i > 0 {
			strings.write_string(&call, ", ")
		}
		strings.write_string(&call, input.ident.name)
	}
	strings.write_byte(&call, ')')

	insert, ok := insert_after_decl(ctx, sel_start, strings.to_string(sb))
	if !ok {
		return
	}

	edits := make([]TextEdit, 2, context.temp_allocator)
	edits[0] = TextEdit {
		range   = range_of(ctx, sel_start, sel_end),
		newText = strings.to_string(call),
	}
	edits[1] = insert

	append(ctx.actions, make_code_action(ctx, "Extract procedure", "refactor.extract", edits))
}

Var :: struct {
	ident: ^ast.Ident,
	decl:  int,
}

has_decl :: proc(vars: []Var, decl: int) -> bool {
	for var in vars {
		if var.decl == decl {
			return true
		}
	}
	return false
}

decl_name_at :: proc(stmts: []^ast.Stmt, offset: int) -> (^ast.Ident, ^ast.Value_Decl) {
	for stmt in stmts {
		decl, ok := stmt.derived.(^ast.Value_Decl)
		if !ok {
			continue
		}
		for name in decl.names {
			if ident, ok := name.derived.(^ast.Ident); ok && ident.pos.offset == offset {
				return ident, decl
			}
		}
	}
	return nil, nil
}

// Statements that return, defer, alter the context, or branch to something outside the selection
// cannot move to another procedure. Nested proc literals keep their own control flow.
can_extract :: proc(stmts: []^ast.Stmt) -> bool {
	Data :: struct {
		ok:    bool,
		depth: int, // loops and switches opened inside the selection
		stack: [dynamic]bool, // whether each open node counts toward depth
	}

	data := Data {
		ok    = true,
		stack = make([dynamic]bool, context.temp_allocator),
	}

	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil {
				if pop(&data.stack) {
					data.depth -= 1
				}
				return nil
			}
			if !data.ok {
				return nil
			}

			opens := false
			#partial switch n in node.derived {
			case ^ast.Proc_Lit:
				return nil
			case ^ast.Return_Stmt, ^ast.Or_Return_Expr, ^ast.Or_Branch_Expr, ^ast.Defer_Stmt, ^ast.Using_Stmt:
				data.ok = false
			case ^ast.Branch_Stmt:
				data.ok = n.label == nil && data.depth > 0
			case ^ast.Assign_Stmt:
				for lhs in n.lhs {
					if _, implicit := lhs.derived.(^ast.Implicit); implicit {
						data.ok = false
					}
				}
			case ^ast.For_Stmt, ^ast.Range_Stmt, ^ast.Unroll_Range_Stmt, ^ast.Switch_Stmt, ^ast.Type_Switch_Stmt:
				opens = true
				data.depth += 1
			}
			if !data.ok {
				return nil
			}
			append(&data.stack, opens)
			return visitor
		},
	}

	for stmt in stmts {
		ast.walk(&visitor, stmt)
	}
	return data.ok
}

// Inserts text after the top-level declaration containing offset, on its own line.
@(private = "package")
insert_after_decl :: proc(ctx: ^ActionContext, offset: int, text: string) -> (TextEdit, bool) {
	for decl in ctx.document.ast.decls {
		if offset < decl.pos.offset || decl.end.offset < offset {
			continue
		}
		document := ctx.document.text[:ctx.document.used_text]
		line := decl.end.line // 1-based, so this is the 0-based line after the declaration
		if _, ok := common.get_last_column(line, document); ok {
			return TextEdit {
					range = {start = {line = line, character = 0}, end = {line = line, character = 0}},
					newText = strings.concatenate({"\n", text, "\n"}, context.temp_allocator),
				},
				true
		}
		column, ok := common.get_last_column(line - 1, document)
		if !ok {
			return {}, false
		}
		return TextEdit {
				range = {start = {line = line - 1, character = column}, end = {line = line - 1, character = column}},
				newText = strings.concatenate({"\n\n", text}, context.temp_allocator),
			},
			true
	}
	return {}, false
}
