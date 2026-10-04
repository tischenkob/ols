#+private file

package server

import "core:math"
import "core:odin/ast"
import "core:slice"
import "core:strconv"
import "core:strings"

TITLE :: "Change result type to returned types"

Result_Types :: struct {
	ctx:       ^ActionContext,
	lit:       ^ast.Proc_Lit,
	declared:  ^ast.Expr, // the last result's type, the one rewritten
	last_name: ^ast.Expr, // the last result's name, nil when unnamed
	count:     int, // result values of the procedure
	texts:     [dynamic]string,
	keys:      [dynamic]string, // texts without whitespace, for deduplication
	edits:     [dynamic]TextEdit, // imports the texts need
	targets:   Maybe([]Constant_Target), // built on the first untyped constant, nil when unknown
	built:     bool,
	body:      map[string]struct{}, // constants and types declared in the body, unseen by the signature
	nilable:   [dynamic]bool, // per text: whether the type takes nil
	has_nil:   bool, // some return is nil
	basics:    [dynamic]string, // per text: the builtin type it is or aliases, else ""
	// The untyped constants returned; each has to pick one variant of a generated union.
	constants: [dynamic]Constant,
}

Constant :: struct {
	kind:     SymbolUntypedValueType,
	// A float written as a literal has a known value; an integral one also converts to integers.
	known:    bool,
	integral: bool,
}

// A declared result type, or a variant of a declared union, that untyped constants may convert to.
Constant_Target :: struct {
	text:    string,
	edits:   []TextEdit,
	// A variant of a named union: nested in a new union, the union no longer takes the constant.
	pinned:  bool,
	nilable: bool,
	basic:   string,
}

Proc_Exit :: union {
	^ast.Return_Stmt,
	^ast.Or_Return_Expr,
}

// Rewrites the last result type of a procedure to the union of the types that reach it through
// its returns and or_returns. Odin does not widen one union into another, so a union that reaches
// the result becomes one variant as a whole. With several results, or_return needs them named, so
// the edit names every unnamed result too.
@(private = "package")
add_result_union_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_result_union {
		return
	}

	// Offered on a return or or_return of the innermost procedure literal around the cursor.
	lit: ^ast.Proc_Lit
	on_exit := false
	#reverse for at in nodes_at(ctx.document.ast.decls[:], ctx.range.start) {
		if l, is_lit := at.node.derived.(^ast.Proc_Lit); is_lit {
			if on_exit && at.parent != nil {
				if _, in_decl := at.parent.derived.(^ast.Value_Decl); in_decl {
					lit = l
				}
			}
			break
		}
		#partial switch _ in at.node.derived {
		case ^ast.Return_Stmt, ^ast.Or_Return_Expr:
			on_exit = true
		}
	}
	if lit == nil || lit.type == nil || lit.body == nil || lit.type.results == nil {
		return
	}
	results := lit.type.results.list
	count := len(field_types(results))
	if count == 0 {
		return
	}
	for field in results {
		if field.type == nil {
			return
		}
	}
	last := results[len(results) - 1]
	// A default value of the old type may not convert to the new one.
	if last.default_value != nil {
		return
	}
	declared := last.type
	last_name: ^ast.Expr
	if len(last.names) > 0 {
		if name := final_name(last.names[len(last.names) - 1]); name != "" && name != "_" {
			last_name = last.names[len(last.names) - 1]
		}
	}

	types := Result_Types {
		ctx       = ctx,
		lit       = lit,
		declared  = declared,
		count     = count,
		last_name = last_name,
		texts     = make([dynamic]string, context.temp_allocator),
		keys      = make([dynamic]string, context.temp_allocator),
		edits     = make([dynamic]TextEdit, context.temp_allocator),
		body      = body_constant_names(lit.body),
		nilable   = make([dynamic]bool, context.temp_allocator),
		basics    = make([dynamic]string, context.temp_allocator),
		constants = make([dynamic]Constant, context.temp_allocator),
	}
	// Resolving returns re-gathers locals at each one; the later actions expect them at the cursor.
	defer {
		clear_locals(ctx.ast_context)
		get_locals(ctx.ast_context, ctx.position_context)
	}
	// Writes and most reads of the named last result depend on its old type.
	if uses_result(&types) {
		return
	}
	for exit in proc_exits(lit.body) {
		ok: bool
		switch e in exit {
		case ^ast.Return_Stmt:
			ok = add_return_type(&types, e)
		case ^ast.Or_Return_Expr:
			ok = add_or_return_type(&types, e)
		}
		if !ok {
			return
		}
	}
	if len(types.texts) == 0 {
		return
	}
	// A generated union takes nil; one type alone has to.
	if types.has_nil && len(types.texts) == 1 && !types.nilable[0] {
		return
	}
	if len(types.texts) > 1 && !constants_convert(&types) {
		return
	}

	text := types.texts[0]
	if len(types.texts) > 1 {
		text = strings.concatenate(
			{"union {", strings.join(types.texts[:], ", ", context.temp_allocator), "}"},
			context.temp_allocator,
		)
	}
	src := ctx.document.ast.src
	if strip_space(text) == strip_space(node_text(src, declared)) {
		return
	}

	// With every result named and the last field holding one name, only the type changes, which
	// keeps comments and layout of the list.
	all_named := true
	for field in results {
		all_named &&= len(field.names) > 0
		for name in field.names {
			all_named &&= final_name(name) != "" && final_name(name) != "_"
		}
	}
	edits := make([dynamic]TextEdit, context.temp_allocator)
	if count == 1 || all_named && len(last.names) == 1 {
		append(&edits, TextEdit{range = range_of(ctx, declared.pos.offset, declared.end.offset), newText = text})
	} else {
		append(&edits, ..named_results_edits(ctx, lit, text))
	}
	append(&edits, ..types.edits[:])
	append(ctx.actions, make_code_action(ctx, TITLE, "quickfix", edits[:]))
}

// Returns and or_returns of this procedure, skipping those of nested procedure literals.
proc_exits :: proc(body: ^ast.Stmt) -> []Proc_Exit {
	found := make([dynamic]Proc_Exit, context.temp_allocator)
	visitor := ast.Visitor {
		data = &found,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			found := (^[dynamic]Proc_Exit)(visitor.data)
			#partial switch n in node.derived {
			case ^ast.Proc_Lit:
				return nil
			case ^ast.Return_Stmt:
				append(found, n)
			case ^ast.Or_Return_Expr:
				append(found, n)
			}
			return visitor
		},
	}
	ast.walk(&visitor, body)
	return found[:]
}

// Edits that name every unnamed result and replace the last type with text. A last field shared as
// `a, b: T` splits. Only names, the last type and the split colon change, so comments and line
// breaks of the list stay as written.
named_results_edits :: proc(ctx: ^ActionContext, lit: ^ast.Proc_Lit, text: string) -> []TextEdit {
	src := ctx.document.ast.src
	fields := lit.type.results.list

	taken := signature_names(lit)
	// A new name must not shadow or redeclare a name the body uses.
	append(&taken, ..body_ident_names(lit.body))

	// Names are chosen left to right, as the named-results action does.
	edits := make([dynamic]TextEdit, context.temp_allocator)
	for field, i in fields {
		is_last := i + 1 == len(fields)
		// The parser names an unnamed result in parentheses `_`, starting where its type does.
		if field.names[0].pos.offset == field.type.pos.offset {
			name: string
			if is_last {
				name = take_result_name(&taken, text == "bool" ? "ok" : "err")
			} else {
				name = fresh_result_name(&taken, field.type)
			}
			type_text := is_last ? text : node_text(src, field.type)
			append(
				&edits,
				TextEdit {
					range = range_of(ctx, field.type.pos.offset, field.type.end.offset),
					newText = strings.concatenate({name, ": ", type_text}, context.temp_allocator),
				},
			)
			continue
		}
		for name, j in field.names {
			if existing := final_name(name); existing != "" && existing != "_" {
				continue
			}
			fresh: string
			if is_last && j + 1 == len(field.names) {
				fresh = take_result_name(&taken, text == "bool" ? "ok" : "err")
			} else {
				fresh = fresh_result_name(&taken, field.type)
			}
			append(&edits, TextEdit{range = range_of(ctx, name.pos.offset, name.end.offset), newText = fresh})
		}
		if !is_last {
			continue
		}
		if len(field.names) > 1 {
			previous := field.names[len(field.names) - 2]
			append(
				&edits,
				TextEdit {
					range = range_of(ctx, previous.end.offset, previous.end.offset),
					newText = strings.concatenate({": ", node_text(src, field.type)}, context.temp_allocator),
				},
			)
		}
		append(&edits, TextEdit{range = range_of(ctx, field.type.pos.offset, field.type.end.offset), newText = text})
	}
	return edits[:]
}

// Every identifier in the body, nested procedures included.
@(private = "package")
body_ident_names :: proc(body: ^ast.Stmt) -> []string {
	names := make([dynamic]string, context.temp_allocator)
	visitor := ast.Visitor {
		data = &names,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			if ident, is_ident := node.derived.(^ast.Ident); is_ident {
				append((^[dynamic]string)(visitor.data), ident.name)
			}
			return visitor
		},
	}
	ast.walk(&visitor, body)
	return names[:]
}

// A bare return, nil, an implicit selector and an untyped compound literal take the result's type,
// so they add nothing. With several results only the last value counts, and a return with another
// number of values, already a compile error, adds nothing.
add_return_type :: proc(types: ^Result_Types, ret: ^ast.Return_Stmt) -> bool {
	if len(ret.results) == 0 {
		return true
	}
	count := types.count
	if len(ret.results) != count {
		if count == 1 {
			return false
		}
		if len(ret.results) != 1 {
			return true
		}
		return add_forwarded_type(types, unparen(ret.results[0]))
	}
	value := unparen(ret.results[count - 1])

	#partial switch v in value.derived {
	case ^ast.Ident:
		if v.name == "nil" {
			types.has_nil = true
			return true
		}
	case ^ast.Implicit_Selector_Expr:
		return true
	case ^ast.Array_Type,
	     ^ast.Dynamic_Array_Type,
	     ^ast.Pointer_Type,
	     ^ast.Multi_Pointer_Type,
	     ^ast.Map_Type,
	     ^ast.Struct_Type,
	     ^ast.Union_Type,
	     ^ast.Enum_Type,
	     ^ast.Bit_Set_Type,
	     ^ast.Proc_Type,
	     ^ast.Typeid_Type,
	     ^ast.Distinct_Type,
	     ^ast.Matrix_Type,
	     ^ast.Poly_Type:
		// A type as a value is a typeid.
		return false
	case ^ast.Comp_Lit:
		if v.type == nil {
			return true
		}
	case ^ast.Call_Expr:
		results, decl_pkg := call_result_types(types, v) or_return
		return len(results) == 1 && add_type_node(types, results[0], decl_pkg)
	case ^ast.Or_Return_Expr:
		// The error half is added when proc_exits reaches the or_return itself.
		call, is_call := unparen(v.expr).derived.(^ast.Call_Expr)
		if !is_call {
			return false
		}
		results, decl_pkg := call_result_types(types, call) or_return
		return len(results) == 2 && add_type_node(types, results[0], decl_pkg)
	}

	ctx := types.ctx
	locals_at(types, ret.pos.offset)

	// A declared type prints as written, anonymous or not.
	ident, is_ident := value.derived.(^ast.Ident)
	if is_ident && is_last_result(types, ident) {
		// Never written, it holds the zero value, which the new type takes, like a bare return.
		return true
	}
	if is_ident {
		if type_expr, has_type := declared_type(types, ident); has_type {
			return add_type_node(types, type_expr, ctx.ast_context.document_package)
		}
	}

	symbol := resolve_type_expression(ctx.ast_context, value) or_return
	untyped, is_untyped := symbol.value.(SymbolUntypedValue)
	// A type name resolves to a symbol of its own name, a value to the symbol of its type.
	if !is_untyped && value_name(value) != "" && value_name(value) == symbol.name {
		return false
	}
	// A constant that converts to the declared type keeps it: typing it as its default type
	// would break valid code like `-> f32 { return 1 }`.
	if is_untyped && !is_variable(types, value) {
		constant := constant_of(untyped.type, value)
		append(&types.constants, constant)
		targets := constant_targets(types) or_return
		for target in targets {
			if !constant.known && is_integral_type(target.basic) {
				return false
			}
		}
		// Odin puts the constant in the accepting variant with the best score; a tie is ambiguous.
		best: ^Constant_Target
		best_score, ties := max(int), 0
		for &target in targets {
			score, accepts := constant_score(constant, target.basic)
			if !accepts {
				continue
			}
			if score < best_score {
				best, best_score, ties = &target, score, 1
			} else if score == best_score {
				ties += 1
			}
		}
		if best != nil {
			if ties > 1 || best.pinned {
				return false
			}
			add_type_text(types, best.text, best.nilable, best.basic)
			add_edits(types, best.edits)
			return true
		}
	}
	// Untyped constants print as their default types only when marked mutable.
	symbol.flags += {.Mutable}
	return add_symbol_type(types, symbol, ident.name if is_ident else "")
}

// Whether the body uses the named last result in a way that depends on its old type. Returning
// it as the last value works with any new type, and comparing it with nil with any type that takes
// nil; any other use, a write included, does not.
// Uses in nested procedures and of shadowing locals do not count.
uses_result :: proc(types: ^Result_Types) -> bool {
	if types.last_name == nil {
		return false
	}
	name := final_name(types.last_name)
	outer: for use in collect_ident_uses(types.lit.body) {
		if use.ident.name != name || len(use.parents) == 0 {
			continue
		}
		for parent in use.parents {
			if _, is_lit := parent.derived.(^ast.Proc_Lit); is_lit {
				continue outer
			}
		}
		#partial switch p in use.parents[len(use.parents) - 1].derived {
		case ^ast.Return_Stmt:
			// Only the last value goes to the last result.
			if p.results[len(p.results) - 1] == use.ident {
				continue
			}
		case ^ast.Binary_Expr:
			if p.op.kind == .Cmp_Eq || p.op.kind == .Not_Eq {
				other := p.right if p.left == use.ident else p.left
				if nil_ident, is_ident := other.derived.(^ast.Ident); is_ident && nil_ident.name == "nil" {
					// The new type then has to take nil, as for a returned nil.
					locals_at(types, use.ident.pos.offset)
					types.has_nil ||= is_last_result(types, use.ident)
					continue
				}
			}
		// Field names spelled like the result are not uses of it.
		case ^ast.Selector_Expr:
			if p.field == use.ident {
				continue
			}
		case ^ast.Implicit_Selector_Expr:
			continue
		case ^ast.Field_Value:
			if p.field == use.ident && names_field(types, use) {
				continue
			}
		}
		locals_at(types, use.ident.pos.offset)
		if is_last_result(types, use.ident) {
			return true
		}
	}
	return false
}

// Whether the field of a field value names a struct field or a named argument. A map literal's
// key is a value; a literal of unknown type counts as one.
names_field :: proc(types: ^Result_Types, use: IdentUse) -> bool {
	if len(use.parents) < 2 {
		return false
	}
	lit, is_lit := use.parents[len(use.parents) - 2].derived.(^ast.Comp_Lit)
	if !is_lit {
		return true
	}
	if lit.type == nil {
		return false
	}
	locals_at(types, lit.pos.offset)
	symbol := resolve_type_expression(types.ctx.ast_context, lit.type) or_return
	#partial switch _ in symbol.value {
	case SymbolStructValue, SymbolBitFieldValue:
		return true
	}
	return false
}

// Locals are gathered up to a position, so re-gathers them at offset in the procedure.
locals_at :: proc(types: ^Result_Types, offset: int) {
	ctx := types.ctx
	pc := ctx.position_context^
	pc.function = types.lit
	pc.position = offset
	pc.nested_position = offset
	clear_locals(ctx.ast_context)
	get_locals(ctx.ast_context, &pc)
	ctx.ast_context.use_locals = true
}

// Whether ident resolves to the named last result among the locals gathered.
is_last_result :: proc(types: ^Result_Types, ident: ^ast.Ident) -> bool {
	if types.last_name == nil {
		return false
	}
	local, is_local := get_local(types.ctx.ast_context^, ident^)
	return is_local && local.lhs == types.last_name
}

// The type written in the declaration of a local, parameter, named result or global variable.
declared_type :: proc(types: ^Result_Types, ident: ^ast.Ident) -> (^ast.Expr, bool) {
	ctx := types.ctx
	if local, is_local := get_local(ctx.ast_context^, ident^); is_local {
		if local.type_expr != nil {
			return local.type_expr, true
		}
		if types.lit.type == nil {
			return nil, false
		}
		// Parameters and named results store their name; body locals never match.
		for list in ([]^ast.Field_List{types.lit.type.params, types.lit.type.results}) {
			if list == nil {
				continue
			}
			for field in list.list {
				for name in field.names {
					if name == local.lhs && field.type != nil {
						return field.type, true
					}
				}
			}
		}
		return nil, false
	}
	if global, is_global := ctx.ast_context.globals[ident.name]; is_global && .Variable in global.flags {
		return global.type_expr, global.type_expr != nil
	}
	return nil, false
}

// A variable holding an untyped value has its default type; only constants convert.
is_variable :: proc(types: ^Result_Types, value: ^ast.Expr) -> bool {
	ident, is_ident := value.derived.(^ast.Ident)
	if !is_ident {
		return false
	}
	ctx := types.ctx
	if local, is_local := get_local(ctx.ast_context^, ident^); is_local {
		return .Mutable in local.flags
	}
	global, is_global := ctx.ast_context.globals[ident.name]
	return is_global && .Mutable in global.flags
}

// The declared result type, or the variants of a declared union. Not known when a variant of a
// polymorphic union such as Maybe(T) is still a parameter or does not print.
constant_targets :: proc(types: ^Result_Types) -> ([]Constant_Target, bool) {
	if types.built {
		targets, known := types.targets.?
		return targets, known
	}
	types.built = true
	ctx := types.ctx
	nodes := []^ast.Expr{types.declared}
	pkg := ctx.ast_context.document_package
	poly_names: []string
	pinned := false
	if union_type, is_union := types.declared.derived.(^ast.Union_Type); is_union {
		nodes = union_type.variants
	} else if symbol, resolved := resolve_type_expression(ctx.ast_context, types.declared); resolved {
		if union_value, is_union_value := symbol.value.(SymbolUnionValue); is_union_value {
			// The specialised variants of a polymorphic union are its arguments.
			nodes = union_value.types
			pkg = symbol.pkg
			poly_names = field_list_names(union_value.poly)
			pinned = true
		}
	}

	targets := make([dynamic]Constant_Target, context.temp_allocator)
	for node in nodes {
		ident, is_ident := node.derived.(^ast.Ident)
		if is_ident && slice.contains(poly_names, ident.name) {
			return nil, false
		}
		edits := make([dynamic]TextEdit, context.temp_allocator)
		text, printed := requalified_type_text(ctx, node, pkg, &edits)
		if !printed {
			if poly_names != nil {
				return nil, false
			}
			continue
		}
		target := Constant_Target {
			text    = text,
			basic   = basic_type_name(ctx, node, pkg),
			edits   = edits[:],
			pinned  = pinned,
			nilable = node_nilable(ctx, node, pkg),
		}
		append(&targets, target)
	}
	types.targets = targets[:]
	return targets[:], true
}

// The parameter names of a polymorphic declaration, `$T` as T.
field_list_names :: proc(list: ^ast.Field_List) -> []string {
	if list == nil {
		return nil
	}
	names := make([dynamic]string, context.temp_allocator)
	for field in list.list {
		for name in field.names {
			#partial switch n in name.derived {
			case ^ast.Ident:
				append(&names, n.name)
			case ^ast.Poly_Type:
				if n.type != nil {
					append(&names, n.type.name)
				}
			}
		}
	}
	return names[:]
}

// The builtin type a type node is or aliases, "" for any other type.
basic_type_name :: proc(ctx: ^ActionContext, node: ^ast.Expr, pkg: string) -> string {
	if ident, is_ident := node.derived.(^ast.Ident); is_ident && ident.name in keyword_map {
		return ident.name
	}
	set_ast_package_set_scoped(ctx.ast_context, pkg)
	symbol, resolved := resolve_type_expression(ctx.ast_context, node)
	if !resolved || symbol.pointers > 0 {
		return ""
	}
	basic, is_basic := symbol.value.(SymbolBasicValue)
	if !is_basic || basic.ident == nil || basic.ident.name not_in keyword_map {
		return ""
	}
	return basic.ident.name
}

// The kinds of untyped constant that convert to the builtin type name.
untyped_accepts :: proc(name: string) -> bit_set[SymbolUntypedValueType] {
	switch name {
	case "":
		return {}
	case "bool", "b8", "b16", "b32", "b64":
		return {.Bool}
	case "string", "cstring", "string16", "cstring16":
		return {.String}
	case "rune", "byte":
		return {.Integer, .Rune}
	}
	switch {
	case strings.has_prefix(name, "complex"):
		return {.Integer, .Float, .Complex}
	case strings.has_prefix(name, "quaternion"):
		return {.Integer, .Float, .Complex, .Quaternion}
	case name[0] == 'f':
		return {.Integer, .Float}
	case name[0] == 'i' || name[0] == 'u':
		return {.Integer, .Rune}
	}
	return {}
}

// `return f()` passes on every result of f, `return f() or_return` all but its last. Either gives
// the last result's type when the counts match; any other single value is a count error.
add_forwarded_type :: proc(types: ^Result_Types, value: ^ast.Expr) -> bool {
	value := value
	extra := 0
	if forward, is_forward := value.derived.(^ast.Or_Return_Expr); is_forward {
		value = unparen(forward.expr)
		extra = 1
	}
	call, is_call := value.derived.(^ast.Call_Expr)
	if !is_call {
		return true
	}
	results, decl_pkg := call_result_types(types, call) or_return
	if len(results) != types.count + extra {
		return true
	}
	return add_type_node(types, results[types.count - 1], decl_pkg)
}

// The last result of the called procedure is what or_return passes on.
add_or_return_type :: proc(types: ^Result_Types, expr: ^ast.Or_Return_Expr) -> bool {
	call, is_call := unparen(expr.expr).derived.(^ast.Call_Expr)
	if !is_call {
		return false
	}
	results, decl_pkg := call_result_types(types, call) or_return
	return len(results) > 0 && add_type_node(types, results[len(results) - 1], decl_pkg)
}

// The result type nodes of a call and the package declaring them. A conversion `T(x)` gives T.
// Procedure groups and polymorphic procedures fail, since their results depend on the arguments.
call_result_types :: proc(types: ^Result_Types, call: ^ast.Call_Expr) -> ([]^ast.Expr, string, bool) {
	ctx := types.ctx
	resolved, found := resolve_entire_file(ctx.document)[uintptr(call.expr)]
	if !found || resolved.symbol == nil {
		return nil, "", false
	}
	symbol := resolved.symbol^
	if is_proc_group(ctx, call.expr) {
		return nil, "", false
	}
	#partial switch v in symbol.value {
	case SymbolProcedureValue:
		// A call to a polymorphic procedure resolves to a specialised copy with new result fields.
		specialised := v.generic || len(v.orig_return_types) != len(v.return_types)
		for field, i in v.orig_return_types {
			specialised ||= i < len(v.return_types) && field != v.return_types[i]
		}
		if specialised {
			return nil, "", false
		}
		set_ast_package_set_scoped(ctx.ast_context, symbol.pkg)
		return get_proc_return_types(ctx.ast_context, symbol, call, true), symbol.pkg, true
	case SymbolProcedureGroupValue, SymbolAggregateValue:
		return nil, "", false
	case SymbolStructValue:
		if v.poly != nil {
			return nil, "", false
		}
	case SymbolUnionValue:
		if v.poly != nil {
			return nil, "", false
		}
	}
	if len(call.args) != 1 {
		return nil, "", false
	}
	conversion := make([]^ast.Expr, 1, context.temp_allocator)
	conversion[0] = call.expr
	return conversion, ctx.ast_context.document_package, true
}

// The file map holds the overload a group call picked, so look at the declaration of the name.
is_proc_group :: proc(ctx: ^ActionContext, callee: ^ast.Expr) -> bool {
	name: string
	pkg := ctx.ast_context.document_package
	#partial switch c in callee.derived {
	case ^ast.Ident:
		if global, is_global := ctx.ast_context.globals[c.name]; is_global && global.expr != nil {
			_, is_group := global.expr.derived.(^ast.Proc_Group)
			return is_group
		}
		name = c.name
	case ^ast.Selector_Expr:
		base, is_ident := c.expr.derived.(^ast.Ident)
		if !is_ident || c.field == nil {
			return false
		}
		imported := false
		for imp in ctx.document.imports {
			if imp.base == base.name {
				pkg = imp.name
				imported = true
			}
		}
		if !imported {
			return false
		}
		name = c.field.name
	case:
		return false
	}
	symbol, found := memory_index_lookup(&indexer.index, name, pkg)
	_, is_group := symbol.value.(SymbolProcedureGroupValue)
	return found && is_group
}

add_edits :: proc(types: ^Result_Types, edits: []TextEdit) {
	outer: for edit in edits {
		for existing in types.edits {
			if existing.newText == edit.newText {
				continue outer
			}
		}
		append(&types.edits, edit)
	}
}

add_type_node :: proc(types: ^Result_Types, type: ^ast.Expr, decl_pkg: string) -> bool {
	if type.pos.file == types.ctx.document.fullpath && names_body_decl(types, type) {
		return false
	}
	text := requalified_type_text(types.ctx, type, decl_pkg, &types.edits) or_return
	add_type_text(types, text, node_nilable(types.ctx, type, decl_pkg), basic_type_name(types.ctx, type, decl_pkg))
	return true
}

// A named type or the default type of an untyped value. Anonymous types and procedures fail:
// their symbols carry the name of the value, not of a type.
add_symbol_type :: proc(types: ^Result_Types, symbol: Symbol, name: string) -> bool {
	ctx := types.ctx
	// A builtin type resolved from another package still carries that package.
	if basic, is_basic := symbol.value.(SymbolBasicValue);
	   is_basic && basic.ident != nil && basic.ident.name in keyword_map && symbol.name == basic.ident.name {
		pointers := strings.repeat("^", symbol.pointers, context.temp_allocator)
		add_type_text(
			types,
			strings.concatenate({pointers, symbol.name}, context.temp_allocator),
			symbol_nilable(symbol),
			symbol.pointers == 0 ? symbol.name : "",
		)
		return true
	}

	text := symbol_type_text(ctx.ast_context, symbol, name) or_return
	if _, is_untyped := symbol.value.(SymbolUntypedValue); is_untyped {
		// Default types of constants: bool, numbers, rune, string.
		add_type_text(types, text, false, text)
		return true
	}
	#partial switch _ in symbol.value {
	case SymbolProcedureValue, SymbolProcedureGroupValue, SymbolAggregateValue:
		return false
	}
	info := symbol
	construct_ident_symbol_info(&info, name, ctx.ast_context.document_package)
	if info.type_name == "" || !is_type_decl(ctx, info.type_name, info.type_pkg) {
		return false
	}
	// symbol_type_text names a foreign package by its directory name, so that name has to be the
	// import alias, or the directory name of an import this action adds.
	pkg := info.type_pkg
	if pkg != "" && pkg != "$builtin" && pkg != ctx.ast_context.document_package {
		alias, has_alias := package_alias(ctx, pkg, &types.edits)
		if !has_alias || alias != get_pkg_name(ctx.ast_context, pkg) {
			return false
		}
	}
	add_type_text(types, text, symbol_nilable(symbol), symbol_basic_name(symbol))
	return true
}

// Whether name declares a type in package pkg: a value's symbol can carry the value's own name.
// A value name is accepted when the package also declares a type of exactly that name.
is_type_decl :: proc(ctx: ^ActionContext, name, pkg: string) -> bool {
	pkg := pkg
	if pkg == "" || pkg == ctx.ast_context.document_package {
		if global, is_global := ctx.ast_context.globals[name]; is_global {
			return global.flags & {.Mutable, .Variable} == {}
		}
		pkg = ctx.ast_context.document_package
	}
	// Types other than structs, unions and enums, such as distinct ones, are indexed as unresolved,
	// so rule out the values instead.
	VALUES :: bit_set[SymbolType]{.Function, .Field, .Variable, .Package, .Keyword, .EnumMember, .Constant}
	symbol, found := memory_index_lookup(&indexer.index, name, pkg)
	return found && symbol.type not_in VALUES
}

// Names of the constants, types among them, declared anywhere in the body. The signature cannot
// see them; those of an enclosing procedure stay visible to a nested literal's signature.
body_constant_names :: proc(body: ^ast.Stmt) -> map[string]struct{} {
	names := make(map[string]struct{}, context.temp_allocator)
	visitor := ast.Visitor {
		data = &names,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			if decl, is_decl := node.derived.(^ast.Value_Decl); is_decl && !decl.is_mutable {
				names := (^map[string]struct{})(visitor.data)
				for name in decl.names {
					if ident, is_ident := name.derived.(^ast.Ident); is_ident {
						names[ident.name] = {}
					}
				}
			}
			return visitor
		},
	}
	ast.walk(&visitor, body)
	return names
}

// Whether a type node of the current document uses a name declared in the body. Field names
// count too, which only ever refuses more.
names_body_decl :: proc(types: ^Result_Types, type: ^ast.Expr) -> bool {
	Data :: struct {
		body:  ^map[string]struct{},
		found: bool,
	}
	data := Data {
		body = &types.body,
	}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			data := (^Data)(visitor.data)
			if ident, is_ident := node.derived.(^ast.Ident); is_ident && ident.name in data.body {
				data.found = true
			}
			return visitor
		},
	}
	ast.walk(&visitor, type)
	return data.found
}

// The name an identifier or selector value is written with.
value_name :: proc(value: ^ast.Expr) -> string {
	#partial switch v in value.derived {
	case ^ast.Ident:
		return v.name
	case ^ast.Selector_Expr:
		if v.field != nil {
			return v.field.name
		}
	}
	return ""
}

add_type_text :: proc(types: ^Result_Types, text: string, nilable: bool, basic: string) {
	key := strip_space(text)
	for existing in types.keys {
		if existing == key {
			return
		}
	}
	append(&types.keys, key)
	append(&types.texts, text)
	append(&types.nilable, nilable)
	append(&types.basics, basic)
}

// The builtin type a named type aliases, "" for any other type.
symbol_basic_name :: proc(symbol: Symbol) -> string {
	basic, is_basic := symbol.value.(SymbolBasicValue)
	if symbol.pointers > 0 || !is_basic || basic.ident == nil || basic.ident.name not_in keyword_map {
		return ""
	}
	return basic.ident.name
}

// Whether every returned untyped constant converts to exactly one type of the generated union.
// Odin ranks the accepting variants: the constant's default type, then a type of the same family,
// then any other; a tie at the best rank is ambiguous.
constants_convert :: proc(types: ^Result_Types) -> bool {
	for constant in types.constants {
		best, count := max(int), 0
		for basic in types.basics {
			if !constant.known && is_integral_type(basic) {
				return false
			}
			score, accepts := constant_score(constant, basic)
			if !accepts {
				continue
			}
			if score < best {
				best, count = score, 1
			} else if score == best {
				count += 1
			}
		}
		if count != 1 {
			return false
		}
	}
	return true
}

// A float constant's value decides whether it converts to integers, so only a literal is known.
constant_of :: proc(kind: SymbolUntypedValueType, value: ^ast.Expr) -> Constant {
	if kind != .Float {
		return {kind = kind, known = true}
	}
	// A sign does not change whether the value is integral.
	operand := value
	if unary, is_unary := value.derived.(^ast.Unary_Expr);
	   is_unary && (unary.op.kind == .Sub || unary.op.kind == .Add) {
		operand = unary.expr
	}
	literal, is_literal := operand.derived.(^ast.Basic_Lit)
	if !is_literal {
		return {kind = kind}
	}
	text, _ := strings.remove_all(literal.tok.text, "_", context.temp_allocator)
	number, parsed := strconv.parse_f64(text)
	if !parsed {
		return {kind = kind}
	}
	// Classifying the fractional part tests for an exact zero without comparing floats.
	_, fraction := math.modf(number)
	class := math.classify(fraction)
	return {kind = kind, known = true, integral = !math.is_inf(number) && (class == .Zero || class == .Neg_Zero)}
}

// Integer types and rune, one family for untyped integer and rune constants.
is_integral_type :: proc(basic: string) -> bool {
	family, has_family := basic_family(basic).?
	return has_family && family == .Integer
}

// How Odin ranks a type for an untyped constant: 1 for the default type, 2 for the same family,
// 3 for another family that accepts it. An integral float literal also converts to integers.
constant_score :: proc(constant: Constant, basic: string) -> (int, bool) {
	kind := constant.kind
	if kind not_in untyped_accepts(basic) && !(kind == .Float && constant.integral && is_integral_type(basic)) {
		return 0, false
	}
	defaults := [SymbolUntypedValueType]string {
		.Integer    = "int",
		.Float      = "f64",
		.Complex    = "complex128",
		.Quaternion = "quaternion256",
		.String     = "string",
		.Bool       = "bool",
		.Rune       = "rune",
	}
	if basic == defaults[kind] {
		return 1, true
	}
	kind_family := kind
	if kind == .Rune {
		kind_family = .Integer
	}
	if family, has_family := basic_family(basic).?; has_family && family == kind_family {
		return 2, true
	}
	return 3, true
}

// The constant kind whose default type shares the builtin type's family. Rune counts as an
// integer type.
basic_family :: proc(basic: string) -> Maybe(SymbolUntypedValueType) {
	switch basic {
	case "rune":
		return .Integer
	case "bool", "b8", "b16", "b32", "b64":
		return .Bool
	case "string", "cstring", "string16", "cstring16":
		return .String
	case "byte":
		return .Integer
	}
	switch {
	case strings.has_prefix(basic, "complex"):
		return .Complex
	case strings.has_prefix(basic, "quaternion"):
		return .Quaternion
	case basic != "" && basic[0] == 'f':
		return .Float
	case basic != "" && (basic[0] == 'i' || basic[0] == 'u'):
		return .Integer
	}
	return nil
}

// Whether a type node takes nil. Named types are resolved in package pkg.
node_nilable :: proc(ctx: ^ActionContext, node: ^ast.Expr, pkg: string) -> bool {
	#partial switch n in node.derived {
	case ^ast.Paren_Expr:
		return node_nilable(ctx, n.expr, pkg)
	case ^ast.Pointer_Type, ^ast.Multi_Pointer_Type, ^ast.Dynamic_Array_Type, ^ast.Map_Type, ^ast.Proc_Type:
		return true
	case ^ast.Array_Type:
		return n.len == nil
	case ^ast.Union_Type:
		return n.kind != .no_nil
	case ^ast.Ident:
		if n.name in keyword_map {
			return is_nilable_builtin(n.name)
		}
	case ^ast.Selector_Expr:
	case:
		return false
	}
	set_ast_package_set_scoped(ctx.ast_context, pkg)
	symbol, resolved := resolve_type_expression(ctx.ast_context, node)
	return resolved && symbol_nilable(symbol)
}

symbol_nilable :: proc(symbol: Symbol) -> bool {
	if symbol.pointers > 0 {
		return true
	}
	#partial switch v in symbol.value {
	case SymbolBasicValue:
		return v.ident != nil && is_nilable_builtin(v.ident.name)
	case SymbolUnionValue:
		return v.kind != .no_nil
	case SymbolSliceValue, SymbolMultiPointerValue, SymbolDynamicArrayValue, SymbolMapValue, SymbolProcedureValue:
		return true
	}
	return false
}

is_nilable_builtin :: proc(name: string) -> bool {
	switch name {
	case "rawptr", "cstring", "cstring16", "any", "typeid":
		return true
	}
	return false
}

unparen :: proc(expr: ^ast.Expr) -> ^ast.Expr {
	expr := expr
	for {
		paren, is_paren := expr.derived.(^ast.Paren_Expr)
		if !is_paren {
			return expr
		}
		expr = paren.expr
	}
}
