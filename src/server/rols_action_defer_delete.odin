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
	if escapes(function.body, name) {
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

// Ownership leaves the scope when the variable, or any value derived from it, can outlive the
// procedure: returned, stored in a variable, field, literal or map key, appended, passed to a call
// whose result is kept, or when the variable is reassigned. A call whose result is discarded is
// trusted not to keep its arguments, except the append family in `stores`. Uses this walk does not
// know count as escapes. Shadowing is ignored. name is the variable the allocation statement assigns,
// or with element an alias of one element, such as `e` in `for &e in s`.
escapes :: proc(body: ^ast.Stmt, name: ^ast.Ident, element := false) -> bool {
	for use in collect_ident_uses(body) {
		if use.ident.name != name.name || use.ident == name || len(use.parents) == 0 {
			continue
		}
		if is_value_use(use) && escapes_from(use.ident, use.parents, element) {
			return true
		}
	}
	return false
}

// value is an expression that may share the allocation; parents are its ancestors, outermost first.
// An element read (index or deref) copies out of the allocation, so it only shares it through a
// later `&` or slice. element says that value itself already is such a read.
escapes_from :: proc(value: ^ast.Expr, parents: []^ast.Node, element := false) -> bool {
	value, element := value, element
	for i := len(parents) - 1; i >= 0; i -= 1 {
		#partial switch p in parents[i].derived {
		case ^ast.Paren_Expr, ^ast.Selector_Expr:
		case ^ast.Index_Expr:
			// An allocation is never an integer, so in the index position it is a map key.
			if p.expr != value {
				return !element
			}
			element = true
		case ^ast.Deref_Expr:
			element = true
		case ^ast.Unary_Expr:
			if p.op.kind != .And {
				return false
			}
			element = false
		case ^ast.Slice_Expr:
			if p.expr != value {
				return false
			}
			element = false
		case:
			if element {
				return false
			}
			#partial switch q in parents[i].derived {
			case ^ast.Ternary_If_Expr,
			     ^ast.Ternary_When_Expr,
			     ^ast.Or_Else_Expr,
			     ^ast.Or_Return_Expr,
			     ^ast.Type_Assertion,
			     ^ast.Type_Cast,
			     ^ast.Auto_Cast,
			     ^ast.Selector_Call_Expr:
			case ^ast.Binary_Expr:
				if .B_Comparison_Begin < q.op.kind && q.op.kind < .B_Comparison_End {
					return false
				}
				if q.op.kind == .In || q.op.kind == .Not_In {
					return false
				}
			case ^ast.Call_Expr:
				// A call on the value, or with it as an argument, may return memory it owns.
				if q.expr != value {
					callee := final_name(q.expr)
					if callee == "len" || callee == "cap" {
						return false
					}
					// The first argument of these is the container that grows; the others go into it.
					if slice.contains(stores, callee) && len(q.args) > 0 && q.args[0] != value {
						return true
					}
				}
			case ^ast.Assign_Stmt:
				// Writing through the value is safe, but reassigning the variable leaks the
				// allocation and frees whatever it holds instead.
				_, is_variable := value.derived.(^ast.Ident)
				return is_variable || !slice.contains(q.lhs, value)
			case ^ast.Range_Stmt:
				// `for &e in s` makes e an element of s in place, so `&e` shares the allocation.
				if q.expr != value || q.body == nil {
					return false
				}
				for val in q.vals {
					ref, is_ref := val.derived.(^ast.Unary_Expr)
					if !is_ref || ref.op.kind != .And {
						continue
					}
					if alias, is_ident := ref.expr.derived.(^ast.Ident); is_ident && escapes(q.body, alias, true) {
						return true
					}
				}
				return false
			case ^ast.Expr_Stmt,
			     ^ast.If_Stmt,
			     ^ast.When_Stmt,
			     ^ast.For_Stmt,
			     ^ast.Switch_Stmt,
			     ^ast.Type_Switch_Stmt,
			     ^ast.Case_Clause:
				return false
			case:
				return true
			}
		}
		// Every case that gets here is an expression whose value may share the allocation.
		value = (^ast.Expr)(parents[i])
	}
	return false
}

stores := []string{"append", "append_elem", "append_elems", "inject_at", "assign_at", "map_insert"}
