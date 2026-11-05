#+private file

package server

import "core:odin/ast"
import "core:odin/tokenizer"
import "core:slice"
import "core:strings"

// Wraps the statement at the cursor, or the statements a selection touches, in a construct. A placeholder condition
// compiles and the user replaces it.
@(private = "package")
add_surround_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_surround {
		return
	}

	function := ctx.position_context.function
	if function == nil || function.body == nil {
		return
	}

	src := ctx.document.ast.src
	start, end := trim_selection(src, ctx.range.start, ctx.range.end)
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

	// Whole lines move. A label, a directive or an attribute would stay outside, as would a neighbor on the line.
	line_start, _ := before_on_line(src, sel_start)
	if strings.trim_space(src[line_start:sel_start]) != "" || marked_by_line_above(src, sel_start) {
		return
	}
	line_end := sel_end
	for line_end < len(src) && src[line_end] != '\n' && src[line_end] != '\r' {
		line_end += 1
	}
	trailing := strings.trim_space(src[sel_end:line_end])
	if trailing != "" && !strings.has_prefix(trailing, "//") {
		return
	}

	// Indenting the lines of a multi-line string would change its value.
	if has_multiline_string(src[line_start:line_end]) {
		return
	}
	flow := scan_flow(stmts)
	level := scan_level(ctx, stmts)

	// A new scope ends the life of its names, runs a `defer` or a scope guard earlier, and restores `context`.
	scoped := !level.opaque && !level.ends_with_scope && !names_escape(function, level, sel_start, sel_end)
	// `odin check` wants the last statement of a procedure with a result to end the flow, and these three do not.
	falls_off :=
		(function.type.results != nil || function.type.diverging) &&
		may_end_procedure(ctx.document, stmts[len(stmts) - 1])

	indent := get_line_indentation(src, sel_start)
	deeper := strings.concatenate({indent, indent_unit(src, indent, nil)}, context.temp_allocator)
	inner := reindent(src[line_start:line_end], indent, deeper)
	offer := proc(ctx: ^ActionContext, start, end: int, title, head, indent, inner: string) {
		text := strings.concatenate({indent, head, "{\n", inner, "\n", indent, "}"}, context.temp_allocator)
		append_replace_range(ctx, start, end, title, text)
	}

	if scoped {
		offer(ctx, line_start, line_end, "Surround with block", "", indent, inner)
	}
	if scoped && !falls_off && !flow.fallthrough_out {
		offer(ctx, line_start, line_end, "Surround with if", "if true ", indent, inner)
	}
	if scoped && !falls_off && !flow.fallthrough_out && !flow.branch_out {
		offer(ctx, line_start, line_end, "Surround with for", "for true ", indent, inner)
	}
	offer(ctx, line_start, line_end, "Surround with when", "when true ", indent, inner)
	if len(level.names) == 0 &&
	   !level.opaque &&
	   !falls_off &&
	   !flow.returns &&
	   !flow.fallthrough_out &&
	   !flow.branch_out &&
	   !flow.labeled {
		offer(ctx, line_start, line_end, "Surround with defer", "defer ", indent, inner)
	}
	if scoped {
		offer(ctx, line_start, line_end, "Surround with #no_bounds_check", "#no_bounds_check ", indent, inner)
	}
}

Flow :: struct {
	returns:         bool, // a `return` or an `or_return`
	fallthrough_out: bool, // a `fallthrough` of a switch outside the statements
	branch_out:      bool, // a `break` or a `continue` that leaves the statements
	labeled:         bool, // a labeled branch: `odin check` rejects any of them in a `defer`
}

Opened :: enum {
	Nothing,
	Loop,
	Switch,
}

// Scans tokens, as a string can sit in a nested procedure, a struct tag or an attribute.
@(private = "package")
has_multiline_string :: proc(text: string) -> bool {
	t: tokenizer.Tokenizer
	tokenizer.init(&t, text, "", proc(pos: tokenizer.Pos, msg: string, args: ..any) {})
	for token := tokenizer.scan(&t); token.kind != .EOF; token = tokenizer.scan(&t) {
		if token.kind == .String && strings.contains_rune(token.text, '\n') {
			return true
		}
	}
	return false
}

// Nested procedures keep their own control flow.
scan_flow :: proc(stmts: []^ast.Stmt) -> Flow {
	Data :: struct {
		flow:     Flow,
		loops:    int,
		switches: int,
		opened:   [dynamic]Opened,
		labels:   [dynamic]string,
	}

	branch :: proc(data: ^Data, kind: enum {
			Break,
			Continue,
		}, label: ^ast.Expr) {
		if label != nil {
			data.flow.labeled = true
			name, is_name := label.derived.(^ast.Ident)
			data.flow.branch_out ||= !is_name || !slice.contains(data.labels[:], name.name)
		} else if kind == .Continue {
			data.flow.branch_out ||= data.loops == 0
		} else {
			data.flow.branch_out ||= data.loops == 0 && data.switches == 0
		}
	}

	data := Data {
		opened = make([dynamic]Opened, context.temp_allocator),
		labels = make([dynamic]string, context.temp_allocator),
	}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil {
				#partial switch pop(&data.opened) {
				case .Loop:
					data.loops -= 1
				case .Switch:
					data.switches -= 1
				}
				return nil
			}

			opened := Opened.Nothing
			label: ^ast.Expr
			#partial switch n in node.derived {
			case ^ast.Proc_Lit:
				return nil
			case ^ast.Return_Stmt, ^ast.Or_Return_Expr:
				data.flow.returns = true
			case ^ast.Branch_Stmt:
				#partial switch n.tok.kind {
				case .Break:
					branch(data, .Break, n.label)
				case .Continue:
					branch(data, .Continue, n.label)
				case .Fallthrough:
					data.flow.fallthrough_out ||= data.switches == 0
				}
			case ^ast.Or_Branch_Expr:
				#partial switch n.token.kind {
				case .Or_Break:
					branch(data, .Break, n.label)
				case .Or_Continue:
					branch(data, .Continue, n.label)
				}
			case ^ast.For_Stmt:
				opened, label = .Loop, n.label
			case ^ast.Range_Stmt:
				opened, label = .Loop, n.label
			case ^ast.Unroll_Range_Stmt:
				opened, label = .Loop, n.label
			case ^ast.Switch_Stmt:
				opened, label = .Switch, n.label
			case ^ast.Type_Switch_Stmt:
				opened, label = .Switch, n.label
			case ^ast.If_Stmt:
				label = n.label
			case ^ast.Block_Stmt:
				label = n.label
			}
			if label != nil {
				if name, is_name := label.derived.(^ast.Ident); is_name {
					append(&data.labels, name.name)
				}
			}
			#partial switch opened {
			case .Loop:
				data.loops += 1
			case .Switch:
				data.switches += 1
			}
			append(&data.opened, opened)
			return visitor
		},
	}
	for stmt in stmts {
		ast.walk(&visitor, stmt)
	}
	return data.flow
}

Level :: struct {
	names:           [dynamic]Declared,
	opaque:          bool, // a `using` brings names that the text does not show
	ends_with_scope: bool, // a `defer`, a scope guard or a write of `context`, which the scope around it ends
}

Declared :: struct {
	name:     string,
	constant: bool,
}

// What the statements do in the scope they sit in. A `when` body shares that scope, and any other block has its own.
scan_level :: proc(ctx: ^ActionContext, stmts: []^ast.Stmt) -> Level {
	level := Level {
		names = make([dynamic]Declared, context.temp_allocator),
	}
	for stmt in stmts {
		scan_level_stmt(ctx, stmt, &level)
	}
	return level
}

scan_level_stmt :: proc(ctx: ^ActionContext, stmt: ^ast.Stmt, level: ^Level) {
	#partial switch s in stmt.derived {
	case ^ast.When_Stmt:
		scan_when_part(ctx, s.body, level)
		if s.else_stmt != nil {
			scan_when_part(ctx, s.else_stmt, level)
		}
		return
	case ^ast.Value_Decl:
		level.opaque ||= s.is_using
		for name in s.names {
			if ident, is_ident := name.derived.(^ast.Ident); is_ident {
				append(&level.names, Declared{ident.name, !s.is_mutable})
			}
		}
	case ^ast.Using_Stmt:
		level.opaque = true
	case ^ast.Defer_Stmt:
		level.ends_with_scope = true
		return
	}

	Data :: struct {
		typed: SymbolAndNodeMap,
		found: bool,
	}
	data := Data {
		typed = resolve_entire_file(ctx.document),
	}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil || data.found {
				return nil
			}
			#partial switch n in node.derived {
			case ^ast.Block_Stmt, ^ast.Proc_Lit:
				return nil
			case ^ast.Assign_Stmt:
				data.found = slice.any_of_proc(n.lhs, writes_context)
			case ^ast.Call_Expr:
				resolved, found := data.typed[uintptr(n.expr)]
				data.found = found && !resolved.is_unresolved && is_scope_guard(resolved.symbol^)
			}
			return visitor
		},
	}
	ast.walk(&visitor, stmt)
	level.ends_with_scope ||= data.found
}

scan_when_part :: proc(ctx: ^ActionContext, part: ^ast.Stmt, level: ^Level) {
	if block, is_block := part.derived.(^ast.Block_Stmt); is_block {
		for stmt in block.stmts {
			scan_level_stmt(ctx, stmt, level)
		}
		return
	}
	scan_level_stmt(ctx, part, level)
}

// `context` and `context.field` hold until the end of the scope.
writes_context :: proc(lhs: ^ast.Expr) -> bool {
	target := lhs
	for {
		#partial switch n in target.derived {
		case ^ast.Implicit:
			return n.tok.kind == .Context
		case ^ast.Selector_Expr:
			target = n.expr
		case ^ast.Index_Expr:
			target = n.expr
		case ^ast.Paren_Expr:
			target = n.expr
		case:
			return false
		}
	}
}

// A callee with `@(deferred_in)`, `@(deferred_out)` or the like runs that procedure at the end of the scope. A procedure
// group call that leaves several members counts when any of them does.
is_scope_guard :: proc(symbol: Symbol) -> bool {
	#partial switch v in symbol.value {
	case SymbolProcedureValue:
		for attribute in v.attributes {
			for elem in attribute.elems {
				field, is_field := elem.derived.(^ast.Field_Value)
				if !is_field {
					continue
				}
				if name, is_name := field.field.derived.(^ast.Ident);
				   is_name && strings.has_prefix(name.name, "deferred_") {
					return true
				}
			}
		}
	case SymbolAggregateValue:
		for member in v.symbols {
			if is_scope_guard(member) {
				return true
			}
		}
	}
	return false
}

// Whether a name declared in the statements is used outside them. A local constant or procedure is visible above its
// declaration too. Another variable of the same name in a later scope counts as well.
names_escape :: proc(function: ^ast.Proc_Lit, level: Level, sel_start, sel_end: int) -> bool {
	if len(level.names) == 0 {
		return false
	}
	for use in collect_ident_uses(function.body) {
		offset := use.ident.pos.offset
		if sel_start <= offset && offset < sel_end || is_member_name(use) {
			continue
		}
		for declared in level.names {
			if declared.name == use.ident.name && (offset >= sel_end || declared.constant) {
				return true
			}
		}
	}
	return false
}

// Whether the statement can be what ends the flow of a procedure. Counting too much only withholds the action.
may_end_procedure :: proc(document: ^Document, stmt: ^ast.Stmt) -> bool {
	if ends_flow(document, stmt) {
		return true
	}
	#partial switch s in stmt.derived {
	case ^ast.For_Stmt:
		return s.cond == nil
	case ^ast.Switch_Stmt, ^ast.Type_Switch_Stmt:
		return true
	case ^ast.Block_Stmt:
		return len(s.stmts) > 0 && may_end_procedure(document, s.stmts[len(s.stmts) - 1])
	case ^ast.If_Stmt:
		return s.else_stmt != nil
	case ^ast.When_Stmt:
		return s.else_stmt != nil || may_end_procedure(document, s.body)
	}
	return false
}
