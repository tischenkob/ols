#+private file

package server

import "core:odin/ast"
import "core:slice"
import "core:strings"

import "src:common"

@(private = "package")
add_inline_variable_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_inline_variable {
		return
	}

	function := ctx.position_context.function
	decl := ctx.position_context.value_decl
	if function == nil || function.body == nil || decl == nil {
		return
	}
	if decl.pos.offset < function.body.pos.offset || function.body.end.offset < decl.end.offset {
		return
	}
	if len(decl.names) != 1 || len(decl.values) != 1 || decl.is_using || decl.type != nil {
		return
	}
	name, is_ident := decl.names[0].derived.(^ast.Ident)
	if !is_ident || name.name == "_" {
		return
	}
	if ctx.range.start < name.pos.offset || name.end.offset < ctx.range.start {
		return
	}
	value := decl.values[0]
	if _, is_proc := value.derived.(^ast.Proc_Lit); is_proc {
		return
	}

	src := ctx.document.ast.src
	if !alone_on_line(src, decl) {
		return
	}

	symbols := resolve_entire_file_for_references(ctx.document, context.temp_allocator, .Identifier, "")
	all_uses := collect_ident_uses(function.body)

	uses := make([dynamic]IdentUse, context.temp_allocator)
	for use in all_uses {
		if use.ident == name || use.ident.name != name.name {
			continue
		}
		if offset, ok := local_decl_offset(ctx, symbols, use.ident); ok && offset == name.pos.offset {
			if is_write(use) {
				return
			}
			append(&uses, use)
		}
	}
	if len(uses) == 0 {
		return
	}
	last_use := uses[len(uses) - 1].ident

	// Inlining keeps behaviour only when the initializer still runs once, at the same point, or
	// when it has no side effects and reads nothing the code it moves past can change.
	typed := resolve_entire_file(ctx.document)
	stable := stable_locals(ctx, symbols, function.body, all_uses)
	if !evaluated_in_place(typed, stable, function.body, decl, uses[:]) &&
	   reads_state(typed, stable, value, max(int), true) {
		return
	}
	// Each copy of a literal is a fresh value: copies no longer share storage, and a [dynamic] or
	// map literal allocates once per copy.
	if len(uses) > 1 && contains_comp_lit(value) {
		return
	}

	// A use inside a loop that starts after the declaration sees writes made anywhere in that loop,
	// and a deferred use runs when the procedure returns.
	check_end := last_use.end.offset
	for use in uses {
		for parent in use.parents {
			if parent.pos.offset < decl.end.offset {
				continue
			}
			#partial switch _ in parent.derived {
			case ^ast.For_Stmt, ^ast.Range_Stmt, ^ast.Unroll_Range_Stmt:
				check_end = max(check_end, parent.end.offset)
			case ^ast.Defer_Stmt:
				check_end = max(check_end, function.body.end.offset)
			}
		}
	}

	// A local read by the initializer must keep its value up to the last use, and nothing may
	// reach it under another name.
	for read in collect_ident_uses(value) {
		if is_member_name(read) {
			continue
		}
		read_decl, ok := local_decl_offset(ctx, symbols, read.ident)
		if !ok {
			// A field that `using` brings into scope resolves to the field, not to a local.
			if resolved, found := typed[uintptr(read.ident)]; found && .Local in resolved.symbol.flags {
				return
			}
			continue
		}
		if !strings.has_prefix(src[read_decl:], read.ident.name) {
			return
		}
		for use in all_uses {
			offset, ok := local_decl_offset(ctx, symbols, use.ident)
			if !ok || offset != read_decl {
				continue
			}
			between := decl.end.offset <= use.ident.pos.offset && use.ident.pos.offset <= check_end
			if is_write(use) && (between || address_taken(use)) || aliases(use) {
				return
			}
		}
	}

	text := src[value.pos.offset:value.end.offset]
	paren_text := strings.concatenate({"(", text, ")"}, context.temp_allocator)

	edits := make([dynamic]TextEdit, 0, len(uses) + 1, context.temp_allocator)
	append(&edits, delete_lines_edit(ctx, decl.pos.line - 1, decl.end.line - 1))
	for use in uses {
		append(
			&edits,
			TextEdit {
				range = range_of(ctx, use.ident.pos.offset, use.ident.end.offset),
				newText = needs_parens(value, use) ? paren_text : text,
			},
		)
	}

	append(ctx.actions, make_code_action(ctx, "Inline variable", "refactor.inline", edits[:]))
}

@(private = "package")
alone_on_line :: proc(src: string, decl: ^ast.Value_Decl) -> bool {
	for i := decl.pos.offset - 1; i >= 0 && src[i] != '\n'; i -= 1 {
		if src[i] != ' ' && src[i] != '\t' {
			return false
		}
	}
	for i := decl.end.offset; i < len(src) && src[i] != '\n'; i += 1 {
		if src[i] != ' ' && src[i] != '\t' {
			return strings.has_prefix(src[i:], "//")
		}
	}
	return true
}

@(private = "package")
has_side_effect :: proc(value: ^ast.Expr) -> bool {
	found: bool
	visitor := ast.Visitor {
		data = &found,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			#partial switch n in node.derived {
			case ^ast.Call_Expr, ^ast.Or_Return_Expr, ^ast.Or_Else_Expr, ^ast.Or_Branch_Expr:
				(^bool)(visitor.data)^ = true
				return nil
			}
			return visitor
		},
	}
	ast.walk(&visitor, value)
	return found
}

// Uses of locals mapped to true when the address of the local is never taken, aliased or passed to
// a `->` call, so no call can change it. Uses of a `@(static)` local map to false: a recursive call
// writes the same variable, so it counts as a global. An `any` or `#by_ptr` argument also passes an
// address, which this does not see.
stable_locals :: proc(
	ctx: ^ActionContext,
	symbols: SymbolAndNodeMap,
	body: ^ast.Stmt,
	uses: []IdentUse,
) -> map[^ast.Ident]bool {
	statics := make(map[int]struct{}, context.temp_allocator)
	for offset in static_local_offsets(body) {
		statics[offset] = {}
	}
	unstable := make(map[int]struct{}, context.temp_allocator)
	for use in uses {
		offset := local_decl_offset(ctx, symbols, use.ident) or_continue
		method := false
		if len(use.parents) > 0 {
			selector, is_selector := use.parents[len(use.parents) - 1].derived.(^ast.Selector_Expr)
			method = is_selector && selector.expr == use.ident && selector.op.kind == .Arrow_Right
		}
		if method || address_taken(use) || aliases(use) {
			unstable[offset] = {}
		}
	}
	stable := make(map[^ast.Ident]bool, context.temp_allocator)
	for use in uses {
		offset := local_decl_offset(ctx, symbols, use.ident) or_continue
		if offset in statics {
			stable[use.ident] = false
		} else if offset not_in unstable {
			stable[use.ident] = true
		}
	}
	return stable
}

// Name offsets of the `@(static)` locals declared in body.
static_local_offsets :: proc(body: ^ast.Stmt) -> []int {
	offsets := make([dynamic]int, context.temp_allocator)
	visitor := ast.Visitor {
		data = &offsets,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			if decl, is_decl := node.derived.(^ast.Value_Decl); is_decl {
				if slice.contains(attribute_names(decl.attributes[:]), "static") {
					for name in decl.names {
						append((^[dynamic]int)(visitor.data), name.pos.offset)
					}
				}
			}
			return visitor
		},
	}
	ast.walk(&visitor, body)
	return offsets[:]
}

// The single use sits in the statement right after the declaration, runs exactly once whenever
// that statement runs, and nothing evaluated before it in that statement calls, reads a global or
// reads a local that a call could change. A plain `=` target is written after every operand.
evaluated_in_place :: proc(
	typed: SymbolAndNodeMap,
	stable: map[^ast.Ident]bool,
	body: ^ast.Stmt,
	decl: ^ast.Value_Decl,
	uses: []IdentUse,
) -> bool {
	if len(uses) != 1 {
		return false
	}
	use := uses[0]
	list, found := find_stmt_list_at(body, decl.pos.offset, decl.end.offset)
	if !found || list.first != list.last || len(list.stmts) <= list.first + 1 {
		return false
	}
	next := list.stmts[list.first + 1]
	#partial switch _ in next.derived {
	case ^ast.For_Stmt, ^ast.Range_Stmt, ^ast.Unroll_Range_Stmt, ^ast.Defer_Stmt:
		return false
	}

	inside_next := false
	for parent, i in use.parents {
		if parent == next {
			inside_next = true
			continue
		}
		if !inside_next {
			continue
		}
		child: ^ast.Node = i + 1 < len(use.parents) ? use.parents[i + 1] : use.ident
		#partial switch p in parent.derived {
		case ^ast.Block_Stmt,
		     ^ast.Case_Clause,
		     ^ast.If_Stmt,
		     ^ast.When_Stmt,
		     ^ast.Switch_Stmt,
		     ^ast.Type_Switch_Stmt,
		     ^ast.For_Stmt,
		     ^ast.Range_Stmt,
		     ^ast.Unroll_Range_Stmt,
		     ^ast.Defer_Stmt,
		     ^ast.Proc_Lit,
		     ^ast.Ternary_If_Expr,
		     ^ast.Ternary_When_Expr:
			return false
		case ^ast.Or_Else_Expr:
			if child == p.y {
				return false
			}
		case ^ast.Binary_Expr:
			if (p.op.kind == .Cmp_And || p.op.kind == .Cmp_Or) && child == p.right {
				return false
			}
		}
	}
	return inside_next && !reads_state(typed, stable, next, use.ident.pos.offset, false)
}

Builtin_Call :: enum {
	Other,
	Pure, // reads only its arguments
	Static, // reads only the types of its arguments
}

// How a call of a runtime builtin reads state. len or cap of a pointer or a cstring reads through it,
// so it counts as .Other.
builtin_call :: proc(typed: SymbolAndNodeMap, call: ^ast.Call_Expr) -> Builtin_Call {
	callee, is_ident := call.expr.derived.(^ast.Ident)
	if !is_ident {
		return .Other
	}
	resolved, found := typed[uintptr(callee)]
	if !found || resolved.is_unresolved || resolved.symbol.pkg != "$builtin" {
		return .Other
	}
	switch callee.name {
	case "size_of", "align_of", "offset_of", "type_of", "typeid_of":
		return .Static
	case "min", "max", "abs", "clamp":
		return .Pure
	case "len", "cap":
		// The length of a cstring is found by reading the bytes it points to.
		for arg in call.args {
			symbol, arg_found := typed[uintptr(arg)]
			if !arg_found || symbol.is_unresolved || symbol.symbol.pointers != 0 {
				return .Other
			}
			if basic, is_basic := symbol.symbol.value.(SymbolBasicValue); is_basic && basic.ident != nil {
				if basic.ident.name == "cstring" || basic.ident.name == "cstring16" {
					return .Other
				}
			}
		}
		return .Pure
	}
	return .Other
}

// Whether the part of root before offset limit calls, reads through an indirection, or reads a
// global variable or a static local. Other locals count too unless allow_locals is set, except plain
// assignment targets and the stable locals. A pure builtin call counts only by its arguments.
reads_state :: proc(
	typed: SymbolAndNodeMap,
	stable: map[^ast.Ident]bool,
	root: ^ast.Node,
	limit: int,
	allow_locals: bool,
) -> bool {
	Data :: struct {
		typed:  SymbolAndNodeMap,
		limit:  int,
		found:  bool,
		static: [dynamic]^ast.Node, // builtin calls that read only the types of their arguments
	}

	data := Data {
		typed  = typed,
		limit  = limit,
		static = make([dynamic]^ast.Node, context.temp_allocator),
	}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil || data.found || data.limit <= node.pos.offset {
				return nil
			}
			if data.limit < node.end.offset {
				return visitor
			}
			#partial switch n in node.derived {
			case ^ast.Call_Expr:
				switch builtin_call(data.typed, n) {
				case .Static:
					append(&data.static, n)
					return nil
				case .Pure:
					return visitor
				case .Other:
					data.found = true
					return nil
				}
			case ^ast.Or_Return_Expr,
			     ^ast.Or_Else_Expr,
			     ^ast.Or_Branch_Expr,
			     ^ast.Deref_Expr,
			     ^ast.Index_Expr,
			     ^ast.Slice_Expr,
			     ^ast.Matrix_Index_Expr,
			     ^ast.Implicit:
				data.found = true
				return nil
			case ^ast.Selector_Expr:
				base, is_ident := n.expr.derived.(^ast.Ident)
				if is_ident && is_variable(data.typed, base) || is_variable(data.typed, n) {
					data.found = true
					return nil
				}
			}
			return visitor
		},
	}
	ast.walk(&visitor, root)
	if data.found {
		return true
	}

	uses: for use in collect_ident_uses(root) {
		if limit <= use.ident.pos.offset || is_member_name(use) {
			continue
		}
		for call in data.static {
			if call.pos.offset <= use.ident.pos.offset && use.ident.end.offset <= call.end.offset {
				continue uses
			}
		}
		// Fail closed on a name the resolver missed, except a callee: compiling code calls a procedure.
		if _, resolved := typed[uintptr(use.ident)]; !resolved && !is_callee(use) {
			return true
		}
		if !is_variable(typed, use.ident) {
			continue
		}
		if !allow_locals && is_plain_target(use) {
			continue
		}
		is_stable, known := stable[use.ident]
		if .Local not_in typed[uintptr(use.ident)].symbol.flags || known && !is_stable {
			return true
		}
		if !allow_locals && !is_stable {
			return true
		}
	}
	return false
}

// Parameters count: one can be a pointer, and reads through it see writes made elsewhere.
is_variable :: proc(typed: SymbolAndNodeMap, node: ^ast.Node) -> bool {
	resolved, ok := typed[uintptr(node)]
	return ok && (.Mutable in resolved.symbol.flags || .Parameter in resolved.symbol.flags)
}

is_plain_target :: proc(use: IdentUse) -> bool {
	if len(use.parents) == 0 {
		return false
	}
	#partial switch p in use.parents[len(use.parents) - 1].derived {
	case ^ast.Assign_Stmt:
		return p.op.kind == .Eq && slice.contains(p.lhs, use.ident)
	case ^ast.Value_Decl:
		return slice.contains(p.names, use.ident)
	}
	return false
}

// `x[:]` or `for &e in x` lets writes change x without naming it.
aliases :: proc(use: IdentUse) -> bool {
	target: rawptr = use.ident
	#reverse for parent in use.parents {
		#partial switch p in parent.derived {
		case ^ast.Selector_Expr:
			if rawptr(p.expr) != target {
				return false
			}
		case ^ast.Index_Expr:
			if rawptr(p.expr) != target {
				return false
			}
		case ^ast.Paren_Expr:
		case ^ast.Slice_Expr:
			return rawptr(p.expr) == target
		case ^ast.Range_Stmt:
			return rawptr(p.expr) == target && slice.any_of_proc(p.vals, is_address_of)
		case ^ast.Unroll_Range_Stmt:
			return rawptr(p.expr) == target && (is_address_of(p.val0) || is_address_of(p.val1))
		case:
			return false
		}
		target = parent
	}
	return false
}

is_address_of :: proc(expr: ^ast.Expr) -> bool {
	if expr == nil {
		return false
	}
	unary, ok := expr.derived.(^ast.Unary_Expr)
	return ok && unary.op.kind == .And
}

// A field, enum member or argument name, which the resolver does not record on its own.
is_member_name :: proc(use: IdentUse) -> bool {
	if len(use.parents) == 0 {
		return false
	}
	#partial switch p in use.parents[len(use.parents) - 1].derived {
	case ^ast.Selector_Expr:
		return p.field == use.ident
	case ^ast.Implicit_Selector_Expr:
		return p.field == use.ident
	case ^ast.Field_Value:
		return p.field == use.ident
	}
	return false
}

is_callee :: proc(use: IdentUse) -> bool {
	if len(use.parents) == 0 {
		return false
	}
	call, ok := use.parents[len(use.parents) - 1].derived.(^ast.Call_Expr)
	return ok && call.expr == use.ident
}

contains_comp_lit :: proc(value: ^ast.Expr) -> bool {
	found: bool
	visitor := ast.Visitor {
		data = &found,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			if _, is_lit := node.derived.(^ast.Comp_Lit); is_lit {
				(^bool)(visitor.data)^ = true
				return nil
			}
			return visitor
		},
	}
	ast.walk(&visitor, value)
	return found
}

needs_parens :: proc(value: ^ast.Expr, use: IdentUse) -> bool {
	#partial switch v in value.derived {
	case ^ast.Binary_Expr,
	     ^ast.Ternary_If_Expr,
	     ^ast.Ternary_When_Expr,
	     ^ast.Or_Else_Expr,
	     ^ast.Unary_Expr,
	     ^ast.Type_Cast,
	     ^ast.Auto_Cast:
	case:
		return false
	}
	if len(use.parents) == 0 {
		return false
	}
	#partial switch p in use.parents[len(use.parents) - 1].derived {
	case ^ast.Binary_Expr,
	     ^ast.Unary_Expr,
	     ^ast.Selector_Expr,
	     ^ast.Index_Expr,
	     ^ast.Slice_Expr,
	     ^ast.Deref_Expr,
	     ^ast.Matrix_Index_Expr,
	     ^ast.Type_Assertion,
	     ^ast.Or_Return_Expr:
		return true
	case ^ast.Call_Expr:
		return p.expr == use.ident
	}
	return false
}
