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
	if function == nil || function.body == nil {
		return
	}

	all_uses := collect_ident_uses(function.body)
	at: ^ast.Ident
	for use in all_uses {
		if use.ident.pos.offset <= ctx.range.start && ctx.range.start <= use.ident.end.offset && !is_member_name(use) {
			at = use.ident
			break
		}
	}
	if at == nil || at.name == "_" {
		return
	}

	// Most identifiers name no such declaration, so this comes before the whole-file resolve.
	candidates := inline_candidates(function.body, at.name, ctx.document.ast.src)
	if len(candidates) == 0 {
		return
	}
	symbols := resolve_entire_file_for_references(ctx.document, context.temp_allocator, .Identifier, "")
	decl := target_decl(ctx, symbols, candidates, at)
	if decl == nil {
		return
	}
	name := decl.names[0].derived.(^ast.Ident)
	value := decl.values[0]
	src := ctx.document.ast.src

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
	// A nested procedure sees the static locals of the procedures around it.
	top: ^ast.Node = function.body
	for decl in ctx.document.ast.decls {
		if decl.pos.offset <= function.pos.offset && function.end.offset <= decl.end.offset {
			top = decl
		}
	}
	stable := stable_locals(ctx, symbols, typed, top, all_uses)
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
			if is_write(use) && (between || address_taken(use)) || aliases(use) || passes_address(typed, use) {
				return
			}
		}
	}

	// An identifier of the initializer or the type must still mean the same thing at each use.
	if name_captured(ctx, symbols, all_uses, value, decl.end.offset, last_use.end.offset) {
		return
	}
	if decl.type != nil && name_captured(ctx, symbols, all_uses, decl.type, decl.end.offset, last_use.end.offset) {
		return
	}

	text := src[value.pos.offset:value.end.offset]
	if decl.type != nil {
		typed_value, ok := restate_with_type(typed, decl.type, value, src)
		if !ok {
			return
		}
		text = typed_value
	}
	paren_text := strings.concatenate({"(", text, ")"}, context.temp_allocator)
	has_literal := contains_comp_lit(value)

	edits := make([dynamic]TextEdit, 0, len(uses) + 1, context.temp_allocator)
	append(&edits, delete_lines_edit(ctx, decl.pos.line - 1, decl.end.line - 1))
	this_use: []TextEdit
	for use in uses {
		wrap := decl.type == nil && needs_parens(value, use) || has_literal && literal_needs_parens(use)
		append(
			&edits,
			TextEdit {
				range = range_of(ctx, use.ident.pos.offset, use.ident.end.offset),
				newText = wrap ? paren_text : text,
			},
		)
		if use.ident == at {
			this_use = edits[len(edits) - 1:]
		}
	}

	append(ctx.actions, make_code_action(ctx, "Inline variable", "refactor.inline", edits[:]))
	// With one use the action above does the same. With more, the checks above already require an
	// initializer that can run again: no call, no global read, no literal.
	if len(uses) > 1 && this_use != nil {
		append(ctx.actions, make_code_action(ctx, "Inline this use", "refactor.inline", this_use))
	}
}

// Whether an identifier between after and until shares a name with one in root and means something
// else, so a copy of root placed there could read the wrong thing. Sibling scopes count too, which
// only refuses more.
name_captured :: proc(
	ctx: ^ActionContext,
	symbols: SymbolAndNodeMap,
	all_uses: []IdentUse,
	root: ^ast.Node,
	after, until: int,
) -> bool {
	for read in collect_ident_uses(root) {
		if is_member_name(read) {
			continue
		}
		read_decl, read_local := local_decl_offset(ctx, symbols, read.ident)
		for other in all_uses {
			if other.ident.name != read.ident.name || is_member_name(other) {
				continue
			}
			if other.ident.pos.offset < after || until < other.ident.pos.offset {
				continue
			}
			other_decl, other_local := local_decl_offset(ctx, symbols, other.ident)
			if other_local != read_local || other_local && other_decl != read_decl {
				return true
			}
		}
	}
	return false
}

// A composite literal does not parse at the start of a statement, and in the header of these
// statements it would parse as the start of the body.
literal_needs_parens :: proc(use: IdentUse) -> bool {
	for parent, i in use.parents {
		child: ^ast.Node = i + 1 < len(use.parents) ? use.parents[i + 1] : use.ident
		#partial switch p in parent.derived {
		case ^ast.Expr_Stmt:
			if p.pos.offset == use.ident.pos.offset do return true
		case ^ast.Assign_Stmt:
			for target in p.lhs {
				if target.pos.offset == use.ident.pos.offset do return true
			}
		case ^ast.If_Stmt:
			if child != p.body && child != p.else_stmt do return true
		case ^ast.When_Stmt:
			if child != p.body && child != p.else_stmt do return true
		case ^ast.For_Stmt:
			if child != p.body do return true
		case ^ast.Range_Stmt:
			if child != p.body do return true
		case ^ast.Unroll_Range_Stmt:
			if child != p.body do return true
		case ^ast.Switch_Stmt:
			if child != p.body do return true
		case ^ast.Type_Switch_Stmt:
			if child != p.body do return true
		}
	}
	return false
}

// The declarations in body that name could refer to and the action can inline. A value of `---`
// exists only in a declaration.
inline_candidates :: proc(body: ^ast.Stmt, name: string, src: string) -> []^ast.Value_Decl {
	Data :: struct {
		name:  string,
		src:   string,
		decls: [dynamic]^ast.Value_Decl,
	}

	data := Data {
		name  = name,
		src   = src,
		decls = make([dynamic]^ast.Value_Decl, context.temp_allocator),
	}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			data := (^Data)(visitor.data)
			if decl, is_decl := node.derived.(^ast.Value_Decl); is_decl {
				if len(decl.names) == 1 && len(decl.values) == 1 && !decl.is_using && can_restate_type(decl.type) {
					ident, is_ident := decl.names[0].derived.(^ast.Ident)
					#partial switch _ in decl.values[0].derived {
					case ^ast.Proc_Lit, ^ast.Undef:
						is_ident = false
					}
					if is_ident && ident.name == data.name && alone_on_line(data.src, decl) {
						append(&data.decls, decl)
					}
				}
			}
			return visitor
		},
	}
	ast.walk(&visitor, body)
	return data.decls[:]
}

// The candidate that at names or refers to. Resolving keeps a shadowed declaration apart.
target_decl :: proc(
	ctx: ^ActionContext,
	symbols: SymbolAndNodeMap,
	candidates: []^ast.Value_Decl,
	at: ^ast.Ident,
) -> ^ast.Value_Decl {
	for candidate in candidates {
		if candidate.names[0] == at {
			return candidate
		}
	}
	offset, ok := local_decl_offset(ctx, symbols, at)
	if !ok {
		return nil
	}
	for candidate in candidates {
		if candidate.names[0].pos.offset == offset {
			return candidate
		}
	}
	return nil
}

// Whether a use can state the declared type. An `any` stores the address of its value, `typeid(int)`
// does not compile, and each spelling of an inline or distinct type is a new type.
can_restate_type :: proc(type: ^ast.Expr) -> bool {
	if type == nil {
		return true
	}
	if names_any(type) {
		return false
	}
	found: bool
	visitor := ast.Visitor {
		data = &found,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			#partial switch _ in node.derived {
			case ^ast.Struct_Type,
			     ^ast.Union_Type,
			     ^ast.Enum_Type,
			     ^ast.Bit_Field_Type,
			     ^ast.Distinct_Type,
			     ^ast.Typeid_Type:
				(^bool)(visitor.data)^ = true
				return nil
			}
			return visitor
		},
	}
	ast.walk(&visitor, type)
	return !found
}

// The initializer of a typed declaration with its type stated: `f32(1)`, `(^int)(nil)`, `Color.Red`
// or `Foo{a = 1}`. These forms bind tighter than any operator at a use. Fails on an untyped literal
// for a union, since `x: Maybe(Foo) = {a = 1}` compiles and `Maybe(Foo){a = 1}` does not.
restate_with_type :: proc(
	typed: SymbolAndNodeMap,
	type: ^ast.Expr,
	value: ^ast.Expr,
	src: string,
) -> (
	text: string,
	ok: bool,
) {
	type_text := src[type.pos.offset:type.end.offset]
	value_text := src[value.pos.offset:value.end.offset]

	named := false
	#partial switch _ in type.derived {
	case ^ast.Ident, ^ast.Selector_Expr, ^ast.Call_Expr:
		named = true
	}
	type_value: SymbolValue
	resolved, found := typed[uintptr(type)]
	found = found && !resolved.is_unresolved
	if found {
		type_value = resolved.symbol.value
	}
	// An alias of a type that can_restate_type refuses by its spelling.
	if basic, is_basic := type_value.(SymbolBasicValue); is_basic && basic.ident != nil {
		if basic.ident.name == "typeid" || basic.ident.name == "any" {
			return "", false
		}
	}

	#partial switch v in value.derived {
	case ^ast.Implicit_Selector_Expr:
		if _, is_enum := type_value.(SymbolEnumValue); is_enum {
			return strings.concatenate({type_text, value_text}, context.temp_allocator), true
		}
	case ^ast.Comp_Lit:
		if v.type == nil {
			_, is_union := type_value.(SymbolUnionValue)
			if named && (!found || is_union) {
				return "", false
			}
			return strings.concatenate({type_text, value_text}, context.temp_allocator), true
		}
	}

	if named {
		return strings.concatenate({type_text, "(", value_text, ")"}, context.temp_allocator), true
	}
	return strings.concatenate({"(", type_text, ")(", value_text, ")"}, context.temp_allocator), true
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

// Uses of locals mapped to true when the address of the local is never taken, aliased, passed to
// a `->` call or passed as an `any` or `#by_ptr` argument, so no call can change it. Uses of a
// `@(static)` local map to false: a recursive call writes the same variable, so it counts as a global.
stable_locals :: proc(
	ctx: ^ActionContext,
	symbols: SymbolAndNodeMap,
	typed: SymbolAndNodeMap,
	scope: ^ast.Node,
	uses: []IdentUse,
) -> map[^ast.Ident]bool {
	statics := make(map[int]struct{}, context.temp_allocator)
	for offset in static_local_offsets(scope) {
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
		if method || address_taken(use) || aliases(use) || passes_address(typed, use) {
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

// Name offsets of the `@(static)` locals declared in scope, nested procedures included.
static_local_offsets :: proc(scope: ^ast.Node) -> []int {
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
	ast.walk(&visitor, scope)
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

// The use, or a field or element of it, is a call argument that the callee receives by address: an
// `any` points at an addressable value, a `#by_ptr` parameter is passed by pointer. A callee the
// resolver misses, a procedure group or a parameter it cannot find counts as one.
passes_address :: proc(typed: SymbolAndNodeMap, use: IdentUse) -> bool {
	child: ^ast.Node = use.ident
	#reverse for parent in use.parents {
		#partial switch p in parent.derived {
		case ^ast.Selector_Expr:
			if p.expr != child do return false
		case ^ast.Index_Expr:
			if p.expr != child do return false
		case ^ast.Paren_Expr:
		case ^ast.Field_Value:
			if p.value != child do return false
		case ^ast.Call_Expr:
			index, is_arg := slice.linear_search(p.args, cast(^ast.Expr)child)
			if !is_arg do return false
			resolved, found := typed[uintptr(p.expr)]
			if !found || resolved.is_unresolved {
				return true
			}
			#partial switch v in resolved.symbol.value {
			case SymbolProcedureValue:
				field, has_field := get_call_arg_field(v, p^, index)
				if !has_field || .By_Ptr in field.flags do return true
				return names_any(field.type)
			case SymbolProcedureGroupValue:
				return true
			case SymbolBasicValue:
				// The conversion `any(x)`.
				return v.ident != nil && v.ident.name == "any"
			}
			return false
		case:
			return false
		}
		child = parent
	}
	return false
}

// `any` or `..any`.
names_any :: proc(type: ^ast.Expr) -> bool {
	if type == nil {
		return false
	}
	if ellipsis, is_ellipsis := type.derived.(^ast.Ellipsis); is_ellipsis {
		return names_any(ellipsis.expr)
	}
	ident, is_ident := unparen(type).derived.(^ast.Ident)
	return is_ident && ident.name == "any"
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
