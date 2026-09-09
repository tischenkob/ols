#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"

Cleanup :: struct {
	pkg, callee: string,
	text:        string, // format string taking the variable name
	allocator:   bool, // the cleanup takes the allocator the call was given as a second argument
}

// Bare callees are the runtime builtins. Temp-allocator procs are left out on purpose.
cleanups := [?]Cleanup {
	{"", "make", "delete(%s)", true},
	{"", "new", "free(%s)", true},
	{"", "new_clone", "free(%s)", true},
	{"strings", "builder_make", "strings.builder_destroy(&%s)", false},
	{"strings", "clone", "delete(%s)", true},
	{"strings", "concatenate", "delete(%s)", true},
	{"strings", "join", "delete(%s)", true},
	{"fmt", "aprintf", "delete(%s)", true},
	{"fmt", "aprint", "delete(%s)", true},
	{"fmt", "aprintln", "delete(%s)", true},
	{"os", "read_entire_file", "delete(%s)", true},
	{"slice", "clone", "delete(%s)", true},
	{"mem", "alloc", "free(%s)", true},
	{"mem", "alloc_bytes", "delete(%s)", true},
}

@(private = "package")
add_defer_delete_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_defer_delete {
		return
	}
	function := ctx.position_context.function
	if function == nil || function.body == nil {
		return
	}

	stmt, block: ^ast.Node
	name: ^ast.Ident
	value: ^ast.Expr
	#reverse for at in nodes_at({function.body}, ctx.range.start) {
		block = at.parent
		#partial switch n in at.node.derived {
		case ^ast.Value_Decl:
			if !n.is_mutable || len(n.values) != 1 || len(n.names) == 0 {
				return
			}
			stmt, value = n, n.values[0]
			name = n.names[0].derived.(^ast.Ident) or_else nil
		case ^ast.Assign_Stmt:
			if n.op.kind != .Eq || len(n.lhs) != 1 || len(n.rhs) != 1 {
				return
			}
			stmt, value = n, n.rhs[0]
			name = n.lhs[0].derived.(^ast.Ident) or_else nil
		case:
			continue
		}
		break
	}
	if stmt == nil || name == nil || name.name == "_" {
		return
	}
	// A `do` body holds one statement, so a defer after it would name something out of scope.
	if block != nil && do_keyword(block) != "" {
		return
	}

	for {
		#partial switch v in value.derived {
		case ^ast.Or_Return_Expr:
			value = v.expr
			continue
		case ^ast.Or_Else_Expr:
			value = v.x
			continue
		}
		break
	}
	call := value.derived.(^ast.Call_Expr) or_else nil
	if call == nil {
		return
	}

	pkg, callee: string
	#partial switch c in call.expr.derived {
	case ^ast.Ident:
		callee = c.name
	case ^ast.Selector_Expr:
		base := c.expr.derived.(^ast.Ident) or_else nil
		if base == nil || c.field == nil {
			return
		}
		pkg, callee = base.name, c.field.name
	case:
		return
	}
	// The memory has to go back to the allocator it came from, so an argument naming one is
	// passed on to the cleanup.
	src := ctx.document.ast.src
	allocator: string
	if len(call.args) > 0 {
		last := call.args[len(call.args) - 1]
		#partial switch _ in last.derived {
		case ^ast.Ident, ^ast.Selector_Expr:
			text := node_text(src, last)
			if strings.has_suffix(text, "temp_allocator") {
				return
			}
			if strings.has_suffix(text, "allocator") {
				allocator = text
			}
		}
	}
	// `delete` on a dynamic array or a map takes no allocator.
	if pkg == "" && callee == "make" && len(call.args) > 0 {
		#partial switch _ in call.args[0].derived {
		case ^ast.Dynamic_Array_Type, ^ast.Map_Type:
			allocator = ""
		}
	}

	cleanup: string
	for entry in cleanups {
		if entry.pkg != pkg || entry.callee != callee {
			continue
		}
		argument := name.name
		if entry.allocator && allocator != "" {
			argument = fmt.tprintf("%s, %s", name.name, allocator)
		}
		cleanup = fmt.tprintf(entry.text, argument)
	}
	if cleanup == "" {
		return
	}

	resolved, is_resolved := resolve_entire_file(ctx.document)[uintptr(call.expr)]
	if !is_resolved {
		return
	}
	// A call matching several overloads of a group resolves to an aggregate.
	#partial switch _ in resolved.symbol.value {
	case SymbolProcedureValue, SymbolProcedureGroupValue, SymbolAggregateValue:
	case:
		return
	}

	if list, ok := find_stmt_list_at(function.body, stmt.pos.offset, stmt.end.offset); ok {
		for s in list.stmts {
			d := s.derived.(^ast.Defer_Stmt) or_else nil
			if d != nil && strip_space(node_text(src, d.stmt)) == strip_space(cleanup) {
				return
			}
		}
	}
	if escapes(ctx, function.body, name.name) {
		return
	}

	ind := get_line_indentation(src, stmt.pos.offset)
	at := stmt.end.offset
	for at < len(src) && src[at] != '\n' {
		at += 1
	}
	text: string
	if at < len(src) {
		at += 1
		text = strings.concatenate({ind, "defer ", cleanup, "\n"}, context.temp_allocator)
	} else {
		text = strings.concatenate({"\n", ind, "defer ", cleanup}, context.temp_allocator)
	}
	title := strings.concatenate({"Add defer ", cleanup}, context.temp_allocator)
	append_insert(ctx, at, title, "refactor.rewrite", text)
}

// Ownership leaves the scope when the variable is returned, appended, stored in a field or
// assigned to anything but a local. Shadowing is ignored.
escapes :: proc(ctx: ^ActionContext, body: ^ast.Stmt, name: string) -> bool {
	for use in collect_ident_uses(body) {
		if use.ident.name != name || len(use.parents) == 0 {
			continue
		}
		target: ^ast.Expr = use.ident
		#partial switch p in use.parents[len(use.parents) - 1].derived {
		case ^ast.Return_Stmt:
			return true
		case ^ast.Field_Value:
			if p.value == target {
				return true
			}
		case ^ast.Call_Expr:
			if final_name(p.expr) == "append" && slice.contains(p.args, target) {
				return true
			}
		case ^ast.Assign_Stmt:
			if !slice.contains(p.rhs, target) {
				continue
			}
			lhs := p.lhs[0].derived.(^ast.Ident) or_else nil
			if lhs == nil || lhs.name in ctx.ast_context.globals {
				return true
			}
		}
	}
	return false
}
