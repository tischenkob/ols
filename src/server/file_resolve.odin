package server

import "base:runtime"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"

import "src:common"
import "src:spall"

SymbolAndNodeMap :: map[uintptr]SymbolAndNode

ResolveReferenceFlag :: enum {
	None,
	Identifier,
	Base,
	Field,
}

@(private = "file")
reset_position_context :: proc(position_context: ^DocumentPositionContext) {
	position_context.comp_lit = nil
	position_context.parent_comp_lit = nil
	position_context.identifier = nil
	position_context.call = nil
	position_context.binary = nil
	position_context.parent_binary = nil
	position_context.previous_index = nil
	position_context.index = nil
}

ResolveCancelProc :: #type proc() -> bool

// Should only be called for open documents
resolve_entire_file :: proc(document: ^Document) -> (symbols: SymbolAndNodeMap) {
	symbols, _ = resolve_entire_file_internal(document, nil)
	return
}

resolve_entire_file_cancellable :: proc(
	document: ^Document,
	should_cancel: ResolveCancelProc,
) -> (SymbolAndNodeMap, bool) {
	return resolve_entire_file_internal(document, should_cancel)
}

@(private = "file")
resolve_entire_file_internal :: proc(
	document: ^Document,
	should_cancel: ResolveCancelProc,
) -> (symbols: SymbolAndNodeMap, completed: bool) {
	spall.trace(#procedure, document.fullpath)

	assert(document.client_owned, #procedure + " should only be called for open documents")

	allocator, has_allocator := document_allocator(document^)
	assert(has_allocator, "Open document should have an allocator set")

	if should_cancel != nil && should_cancel() {
		return nil, false
	}

	reuse_cached: {
		symbols = document.symbols.? or_break reuse_cached
		return symbols, true
	}

	// rols: cached symbols keep pointers into temp memory (pkg paths, docs, synthesized nodes), so
	// allocate it from the cache arena. Otherwise the cache reads freed memory after the request.
	context.temp_allocator = allocator

	cancelled := false
	ast_context := make_ast_context(
		document.ast,
		document.imports,
		document.package_name,
		document.uri.uri,
		document.fullpath,
		allocator,
	)
	// rols: the whole-file resolve drops group members whose arity cannot fit a call
	ast_context.whole_file_resolve = true

	position_context: DocumentPositionContext
	position_context.functions = make([dynamic]^ast.Proc_Lit, context.temp_allocator)

	get_globals(document.ast, &ast_context)

	ast_context.current_package = ast_context.document_package

	// rols: no preallocation: most files resolve to far fewer nodes
	symbols = make(SymbolAndNodeMap, allocator)
	// rols: the lint call counts read the callee of an argument call from here instead of resolving it again
	arg_callees := make(map[uintptr]Arg_Callee, allocator)

	for decl in document.ast.decls {
		resolve_decl(
			&position_context,
			&ast_context,
			document,
			decl,
			&symbols,
			flag = .None,
			save_unresolved = true,
			target_name = "",
			should_cancel = should_cancel,
			cancelled = &cancelled,
			arg_callees = &arg_callees,
		)
		if cancelled {
			// rols: release the partly filled cache arena
			invalidate_document_symbol_cache(document)
			return nil, false
		}
		clear(&ast_context.locals)
		// rols: a call that fails to resolve in one declaration may resolve in another
		clear(&ast_context.call_expr_recursion_cache)
	}

	document.symbols = symbols
	// rols: cached and cleared together with symbols
	document.arg_callees = arg_callees
	return symbols, true
}

// Should only be called when resolving references
resolve_entire_file_for_references :: proc(
	document:    ^Document,
	allocator:   runtime.Allocator,
	flag:        ResolveReferenceFlag,
	target_name: string,
) -> (symbols: SymbolAndNodeMap) {
	spall.trace(#procedure, document.fullpath)

	ast_context := make_ast_context(
		document.ast,
		document.imports,
		document.package_name,
		document.uri.uri,
		document.fullpath,
		allocator,
	)
	// rols: the whole-file resolve drops group members whose arity cannot fit a call
	ast_context.whole_file_resolve = true

	position_context: DocumentPositionContext
	position_context.functions = make([dynamic]^ast.Proc_Lit, context.temp_allocator)

	get_globals(document.ast, &ast_context)

	ast_context.current_package = ast_context.document_package

	// rols: no preallocation: most files resolve to far fewer nodes
	symbols = make(SymbolAndNodeMap, allocator)

	for decl in document.ast.decls {
		resolve_decl(
			&position_context,
			&ast_context,
			document,
			decl,
			&symbols,
			flag = flag,
			save_unresolved = false,
			target_name = target_name,
		)
		clear(&ast_context.locals)
		// rols: a call that fails to resolve in one declaration may resolve in another
		clear(&ast_context.call_expr_recursion_cache)
	}

	return symbols
}

FileResolveData :: struct {
	ast_context:      ^AstContext,
	symbols:          ^SymbolAndNodeMap,
	id_counter:       int,
	document:         ^Document,
	position_context: ^DocumentPositionContext,
	flag:             ResolveReferenceFlag,
	target_name:      string,
	save_unresolved:  bool,
	should_cancel:    ResolveCancelProc,
	cancelled:        ^bool,
	// rols: the argument callees to record, nil when not wanted, and the procedure literals around the node
	arg_callees:      ^map[uintptr]Arg_Callee,
	proc_lits:        [dynamic]^ast.Proc_Lit,
}

@(private = "file")
resolve_decl :: proc(
	position_context: ^DocumentPositionContext,
	ast_context: ^AstContext,
	document: ^Document,
	decl: ^ast.Node,
	symbols: ^SymbolAndNodeMap,
	flag: ResolveReferenceFlag,
	save_unresolved: bool,
	target_name := "",
	should_cancel: ResolveCancelProc = nil,
	cancelled: ^bool = nil,
	// rols: the whole-file resolve records argument callees here
	arg_callees: ^map[uintptr]Arg_Callee = nil,
) {
	data := FileResolveData {
		position_context = position_context,
		ast_context      = ast_context,
		symbols          = symbols,
		document         = document,
		flag             = flag,
		target_name      = target_name,
		save_unresolved  = save_unresolved,
		should_cancel    = should_cancel,
		cancelled        = cancelled,
		// rols: argument callees
		arg_callees      = arg_callees,
	}
	// rols: the procedure literal stack lives in temp memory, which the whole-file resolve rebinds to the cache arena
	data.proc_lits.allocator = context.temp_allocator

	resolve_node(decl, &data)
}


@(private = "file")
local_scope_deferred :: proc(data: ^FileResolveData, stmt: ^ast.Stmt) {
	pop_local_group(data.ast_context)
}

@(deferred_in = local_scope_deferred)
@(private = "file")
local_scope :: proc(data: ^FileResolveData, stmt: ^ast.Stmt) {
	add_local_group(data.ast_context)

	if stmt == nil {
		return
	}

	data.position_context.position = stmt.end.offset
	data.position_context.nested_position = data.position_context.position

	data.ast_context.non_mutable_only = true

	get_locals_stmt(data.ast_context.file, stmt, data.ast_context, data.position_context)

	data.ast_context.non_mutable_only = false

	get_locals_stmt(data.ast_context.file, stmt, data.ast_context, data.position_context)
}

@(private = "file")
local_scope_poly_deferred :: proc(data: ^FileResolveData, poly_params: ^ast.Field_List) {
	pop_local_group(data.ast_context)
}

@(private = "file")
@(deferred_in = local_scope_poly_deferred)
local_scope_poly :: proc(data: ^FileResolveData, poly_params: ^ast.Field_List) {
	add_local_group(data.ast_context)
	get_locals_poly(data.ast_context.file, poly_params, data.ast_context)
}

@(private = "file")
local_scope_enum_deferred :: proc(data: ^FileResolveData, enum_type: ^ast.Enum_Type) {
	pop_local_group(data.ast_context)
}

@(private = "file")
@(deferred_in = local_scope_enum_deferred)
local_scope_enum :: proc(data: ^FileResolveData, enum_type: ^ast.Enum_Type) {
	add_local_group(data.ast_context)
	get_locals_enum_fields(enum_type, data.ast_context, data.position_context)
}

@(private = "file")
resolve_binary_expr :: proc(binary: ^ast.Binary_Expr, data: ^FileResolveData) {
	// rols: restore the binary fields after this expression, so they never leak to a later node
	old_binary, old_parent_binary := data.position_context.binary, data.position_context.parent_binary
	defer data.position_context.binary, data.position_context.parent_binary = old_binary, old_parent_binary

	if data.position_context.parent_binary == nil {
		data.position_context.parent_binary = binary
	}

	// rols: each operand resolves with its own parent as `binary`, not the last nested binary the walker popped
	Entry :: struct {
		node:   ^ast.Node,
		parent: ^ast.Binary_Expr,
	}
	stack := make([dynamic]Entry, context.temp_allocator)
	append(&stack, Entry{binary, nil})

	for len(stack) > 0 {
		entry := pop(&stack)
		if entry.node == nil {
			continue
		}

		b, ok := entry.node.derived.(^ast.Binary_Expr)
		if !ok {
			data.position_context.binary = entry.parent
			resolve_node(entry.node, data)
			continue
		}

		append(&stack, Entry{b.left, b})
		append(&stack, Entry{b.right, b})
	}
}

// rols: symbols are heap-allocated so the map can hold pointers
@(private = "file")
resolve_node :: proc(node: ^ast.Node, data: ^FileResolveData) {
	if node == nil {
		return
	}
	// Only cancel between nodes. Nested type resolution assumes it can finish the current node.
	if data.should_cancel != nil && data.should_cancel() {
		data.cancelled^ = true
		return
	}

	spall.trace(#procedure)

	reset_ast_context(data.ast_context)

	#partial switch n in node.derived {
	case ^ast.Bad_Expr:
	case ^ast.Ident:
		data.position_context.identifier = node
		if data.flag != .None {
			if data.target_name == "" || n.name == data.target_name {
				if symbol, ok := resolve_location_identifier(data.ast_context, n^); ok {
					data.symbols[cast(uintptr)node] = SymbolAndNode {
						node   = n,
						symbol = new_clone(symbol, data.ast_context.allocator),
					}
				}
			}
		} else {
			if symbol, ok := resolve_type_identifier(data.ast_context, n^); ok {
				data.symbols[cast(uintptr)node] = SymbolAndNode {
					node   = n,
					symbol = new_clone(symbol, data.ast_context.allocator),
				}
			}
		}
	case ^ast.Selector_Call_Expr:
		data.position_context.selector = n.expr
		data.position_context.field = n.call
		data.position_context.selector_expr = node

		// rols: restore the call after the selector call, a stale one leaks to later nodes
		old_position_call := data.position_context.call
		defer data.position_context.call = old_position_call
		if _, ok := n.call.derived.(^ast.Call_Expr); ok {
			data.position_context.call = n.call
		}

		resolve_node(n.expr, data)
		resolve_node(n.call, data)
	case ^ast.Implicit_Selector_Expr:
		data.position_context.implicit = true
		data.position_context.implicit_selector_expr = n
		data.position_context.position = n.pos.offset
		if data.target_name == "" || n.field.name == data.target_name {
			if symbol, ok := resolve_location_implicit_selector(data.ast_context, data.position_context, n); ok {
				data.symbols[cast(uintptr)node] = SymbolAndNode {
					node   = n,
					symbol = new_clone(symbol, data.ast_context.allocator),
				}
			}
		}
	case ^ast.Selector_Expr:
		data.position_context.selector = n.expr
		data.position_context.field = n.field
		data.position_context.selector_expr = node

		if data.flag != .None {
			if data.target_name == "" || (n.field != nil && n.field.name == data.target_name) {
				if symbol, ok := resolve_location_selector(data.ast_context, n); ok {
					if data.flag != .Base {
						data.symbols[cast(uintptr)node] = SymbolAndNode {
							node   = n.field,
							symbol = new_clone(symbol, data.ast_context.allocator),
						}
					} else {
						data.symbols[cast(uintptr)node] = SymbolAndNode {
							node   = n,
							symbol = new_clone(symbol, data.ast_context.allocator),
						}
					}
				}
			}

			#partial switch v in n.expr.derived {
			// TODO: Should there be more here?
			case ^ast.Selector_Expr, ^ast.Index_Expr, ^ast.Ident, ^ast.Paren_Expr, ^ast.Call_Expr:
				resolve_node(n.expr, data)
			}
		} else {
			if symbol, ok := resolve_type_expression(data.ast_context, &n.node); ok {
				data.symbols[cast(uintptr)node] = SymbolAndNode {
					node   = n,
					symbol = new_clone(symbol, data.ast_context.allocator),
				}
			} else if data.save_unresolved {
				//If we failed to resolve the identifier of an selector expression, we check if the base was resolved correctly.
				//This matters for adding unimported imports.
				_, ok := resolve_type_expression(data.ast_context, n.expr)

				data.symbols[cast(uintptr)node] = SymbolAndNode {
					node                              = n,
					symbol                            = new(Symbol, data.ast_context.allocator),
					is_unresolved                     = true,
					is_selector_expression_unresolved = !ok,
				}
			}
			resolve_node(n.expr, data)
			old := data.ast_context.use_imports
			data.ast_context.use_imports = false
			defer data.ast_context.use_imports = old
			resolve_node(n.field, data)
		}


	case ^ast.Field_Value:
		// rols: restore the field value after this node, so it never leaks to a later node
		old_field_value := data.position_context.field_value
		defer data.position_context.field_value = old_field_value
		data.position_context.field_value = n

		if data.flag != .None && data.position_context.comp_lit != nil {
			data.position_context.position = n.pos.offset

			if symbol, ok := resolve_location_comp_lit_field(data.ast_context, data.position_context); ok {
				data.symbols[cast(uintptr)node] = SymbolAndNode {
					node   = n.field,
					symbol = new_clone(symbol, data.ast_context.allocator),
				}
			}

			resolve_node(n.value, data)
		} else if data.flag != .None && data.position_context.call != nil {
			if symbol, ok := resolve_location_proc_param_name(data.ast_context, data.position_context); ok {
				data.symbols[cast(uintptr)node] = SymbolAndNode {
					node   = n.field,
					symbol = new_clone(symbol, data.ast_context.allocator),
				}
			}
			resolve_node(n.value, data)
		} else {
			resolve_node(n.field, data)
			resolve_node(n.value, data)
		}
	case ^ast.Proc_Lit:
		// rols: store the parameters before the body locals, which resolve call values such as `x := make([]int, m)`
		local_scope(data, nil)

		get_locals_proc_param_and_results(data.ast_context.file, n^, data.ast_context, data.position_context)

		local_scope(data, n.body)

		resolve_node(n.type, data)

		for clause in n.where_clauses {
			resolve_node(clause, data)
		}

		data.position_context.function = cast(^ast.Proc_Lit)node

		append(&data.position_context.functions, data.position_context.function)

		// rols: a poly parameter of an enclosing procedure literal turns `T(x)` into a conversion
		append(&data.proc_lits, n)
		defer pop(&data.proc_lits)

		resolve_node(n.body, data)
	case ^ast.Unroll_Range_Stmt:
		local_scope(data, n)
		resolve_node(n.val0, data)
		resolve_node(n.val1, data)
		resolve_node(n.expr, data)
		resolve_node(n.body, data)
	case ^ast.For_Stmt:
		local_scope(data, n)
		add_label(n.label, data)
		resolve_node(n.init, data)
		resolve_node(n.cond, data)
		resolve_node(n.post, data)
		resolve_node(n.body, data)
	case ^ast.Range_Stmt:
		local_scope(data, n)
		add_label(n.label, data)
		resolve_node(n.init, data)
		resolve_nodes(n.vals, data)
		resolve_node(n.expr, data)
		resolve_node(n.body, data)
	case ^ast.Switch_Stmt:
		old_switch := data.position_context.switch_stmt
		defer {
			data.position_context.switch_stmt = old_switch
		}
		local_scope(data, n)
		data.position_context.switch_stmt = n
		add_label(n.label, data)
		resolve_node(n.init, data)
		resolve_node(n.cond, data)
		resolve_node(n.body, data)
	case ^ast.If_Stmt:
		local_scope(data, n)
		add_label(n.label, data)
		resolve_node(n.init, data)
		resolve_node(n.cond, data)
		resolve_node(n.body, data)
		resolve_node(n.else_stmt, data)
	case ^ast.When_Stmt:
		local_scope(data, n)
		resolve_node(n.cond, data)
		resolve_node(n.body, data)
		resolve_node(n.else_stmt, data)
	case ^ast.Block_Stmt:
		local_scope(data, n)
		add_label(n.label, data)
		resolve_nodes(n.stmts, data)
	case ^ast.Implicit:
		if n.tok.text == "context" {
			data.position_context.implicit_context = n
		}
	case ^ast.Undef:
	case ^ast.Basic_Lit:
		data.position_context.basic_lit = cast(^ast.Basic_Lit)node
	case ^ast.Matrix_Index_Expr:
		resolve_node(n.expr, data)
		resolve_node(n.row_index, data)
		resolve_node(n.column_index, data)
	case ^ast.Matrix_Type:
		resolve_node(n.row_count, data)
		resolve_node(n.column_count, data)
		resolve_node(n.elem, data)
	case ^ast.Ellipsis:
		resolve_node(n.expr, data)
	case ^ast.Comp_Lit:
		// We only want to resolve the values, not the types
		resolve_node(n.type, data)

		//only set this for the parent comp literal, since we will need to walk through it to infer types.
		set := false
		if data.position_context.parent_comp_lit == nil {
			set = true
			data.position_context.parent_comp_lit = n
		}
		defer if set {
			data.position_context.parent_comp_lit = nil
		}

		data.position_context.comp_lit = n
		resolve_nodes(n.elems, data)
	case ^ast.Tag_Expr:
		resolve_node(n.expr, data)
	case ^ast.Unary_Expr:
		resolve_node(n.expr, data)
	case ^ast.Binary_Expr:
		resolve_binary_expr(n, data)
	case ^ast.Paren_Expr:
		resolve_node(n.expr, data)
	case ^ast.Call_Expr:
		// rols: each call restores its own previous value, so a nested call keeps the outer call for later arguments
		old_ast_call, old_position_call := data.ast_context.call, data.position_context.call

		data.position_context.call = n
		data.ast_context.call = n

		defer {
			data.position_context.call = old_position_call
		}

		resolve_node(n.expr, data)

		data.ast_context.call = old_ast_call

		// rols: the member of `offset_of(T, member)` resolves only to the field of T
		member, has_member := offset_of_member_arg(data.ast_context, n)
		for arg in n.args {
			if has_member && arg == &member.node {
				resolve_offset_of_member(data, n, member)
				continue
			}
			data.position_context.position = arg.pos.offset
			// rols: an argument takes its type from the parameter, not from an enclosing comp literal
			old_comp_lit, old_parent_comp_lit := data.position_context.comp_lit, data.position_context.parent_comp_lit
			data.position_context.comp_lit, data.position_context.parent_comp_lit = nil, nil
			defer data.position_context.comp_lit, data.position_context.parent_comp_lit = old_comp_lit, old_parent_comp_lit
			resolve_node(arg, data)
			// rols: with the locals of the call in place
			record_arg_callee(data, arg)
		}
	case ^ast.Index_Expr:
		// rols: restore the index fields after this node, a stale index decides a later implicit selector
		old_index, old_previous_index := data.position_context.index, data.position_context.previous_index
		defer data.position_context.index, data.position_context.previous_index = old_index, old_previous_index
		data.position_context.previous_index = data.position_context.index
		data.position_context.index = n
		resolve_node(n.expr, data)
		resolve_node(n.index, data)
	case ^ast.Deref_Expr:
		resolve_node(n.expr, data)
	case ^ast.Slice_Expr:
		resolve_node(n.expr, data)
		resolve_node(n.low, data)
		resolve_node(n.high, data)
	case ^ast.Ternary_If_Expr:
		resolve_node(n.x, data)
		resolve_node(n.cond, data)
		resolve_node(n.y, data)
	case ^ast.Ternary_When_Expr:
		resolve_node(n.x, data)
		resolve_node(n.cond, data)
		resolve_node(n.y, data)
	case ^ast.Type_Assertion:
		resolve_node(n.expr, data)
		resolve_node(n.type, data)
	case ^ast.Type_Cast:
		resolve_node(n.type, data)
		resolve_node(n.expr, data)
	case ^ast.Auto_Cast:
		resolve_node(n.expr, data)
	case ^ast.Bad_Stmt:
	case ^ast.Empty_Stmt:
	case ^ast.Expr_Stmt:
		resolve_node(n.expr, data)
	case ^ast.Tag_Stmt:
		r := cast(^ast.Tag_Stmt)node
		resolve_node(r.stmt, data)
	case ^ast.Return_Stmt:
		data.position_context.returns = n
		defer {
			data.position_context.returns = nil
		}
		resolve_nodes(n.results, data)
	case ^ast.Defer_Stmt:
		resolve_node(n.stmt, data)
	case ^ast.Case_Clause:
		local_scope(data, n)
		resolve_nodes(n.list, data)
		resolve_nodes(n.body, data)
	case ^ast.Type_Switch_Stmt:
		old_switch := data.position_context.switch_type_stmt
		defer {
			data.position_context.switch_type_stmt = old_switch
		}
		data.position_context.switch_type_stmt = n
		add_label(n.label, data)
		local_scope(data, n)
		resolve_node(n.tag, data)
		resolve_node(n.expr, data)
		resolve_node(n.body, data)
	case ^ast.Branch_Stmt:
		add_label(n.label, data)
	case ^ast.Using_Stmt:
		resolve_nodes(n.list, data)
	case ^ast.Bad_Decl:
	case ^ast.Assign_Stmt:
		data.position_context.assign = n
		reset_position_context(data.position_context)
		resolve_nodes(n.lhs, data)
		resolve_nodes(n.rhs, data)
	case ^ast.Value_Decl:
		data.position_context.value_decl = n

		reset_position_context(data.position_context)
		resolve_nodes(n.attributes[:], data)
		resolve_nodes(n.names, data)
		resolve_node(n.type, data)
		resolve_nodes(n.values, data)
	case ^ast.Package_Decl:
	case ^ast.Import_Decl:
		resolve_nodes(n.attributes[:], data)
	case ^ast.Foreign_Block_Decl:
		resolve_nodes(n.attributes[:], data)
		resolve_node(n.foreign_library, data)
		resolve_node(n.body, data)
	case ^ast.Foreign_Import_Decl:
		resolve_nodes(n.attributes[:], data)
		resolve_node(n.name, data)
		// rols: a foreign import path can name a constant of an imported package
		resolve_nodes(n.fullpaths, data)
	case ^ast.Proc_Group:
		resolve_nodes(n.args, data)
	case ^ast.Attribute:
		resolve_nodes(n.elems, data)
	case ^ast.Field:
		resolve_nodes(n.names, data)
		resolve_node(n.type, data)
		resolve_node(n.default_value, data)
	case ^ast.Field_List:
		resolve_nodes(n.list, data)
	case ^ast.Typeid_Type:
		resolve_node(n.specialization, data)
	case ^ast.Helper_Type:
		resolve_node(n.type, data)
	case ^ast.Distinct_Type:
		resolve_node(n.type, data)
	case ^ast.Poly_Type:
		resolve_node(n.type, data)
		resolve_node(n.specialization, data)
	case ^ast.Proc_Type:
		resolve_node(n.params, data)
		resolve_node(n.results, data)
	case ^ast.Pointer_Type:
		resolve_node(n.elem, data)
	case ^ast.Array_Type:
		resolve_node(n.len, data)
		resolve_node(n.elem, data)
	case ^ast.Dynamic_Array_Type:
		resolve_node(n.elem, data)
	case ^ast.Fixed_Capacity_Dynamic_Array_Type:
		resolve_node(n.elem, data)
		resolve_node(n.capacity, data)
	case ^ast.Multi_Pointer_Type:
		resolve_node(n.elem, data)
	case ^ast.Struct_Type:
		data.position_context.struct_type = n
		resolve_node(n.poly_params, data)
		resolve_node(n.align, data)
		for clause in n.where_clauses {
			resolve_node(clause, data)
		}
		local_scope_poly(data, n.poly_params)
		// rols: a field name declares the field, it is no use of a package or global of the same name
		if n.fields != nil {
			for field in n.fields.list {
				resolve_node(field.type, data)
				resolve_node(field.default_value, data)
			}
		}

		if data.flag != .None {
			for field in n.fields.list {
				for name in field.names {
					data.symbols[cast(uintptr)name] = SymbolAndNode {
						node   = name,
						symbol = new_clone(
							Symbol {
								range = common.get_token_range(name, string(data.document.text)),
								uri = strings.clone(
									common.create_uri(field.pos.file, data.ast_context.allocator).uri,
									data.ast_context.allocator,
								),
							},
							data.ast_context.allocator,
						),
					}
				}
			}
		}
	case ^ast.Union_Type:
		data.position_context.union_type = n
		resolve_node(n.poly_params, data)
		resolve_node(n.align, data)
		// rols: walk the where clauses as the Struct_Type case does
		resolve_nodes(n.where_clauses, data)
		local_scope_poly(data, n.poly_params)
		resolve_nodes(n.variants, data)
	case ^ast.Enum_Type:
		data.position_context.enum_type = n
		resolve_node(n.base_type, data)
		local_scope_enum(data, n)
		resolve_nodes(n.fields, data)

		if data.flag != .None {
			for field in n.fields {
				data.symbols[cast(uintptr)field] = SymbolAndNode {
					node   = field,
					symbol = new_clone(
						Symbol {
							range = common.get_token_range(field, string(data.document.text)),
							uri = strings.clone(
								common.create_uri(field.pos.file, data.ast_context.allocator).uri,
								data.ast_context.allocator,
							),
						},
						data.ast_context.allocator,
					),
				}
				// In the case of a Field_Value, we explicitly add them so we can find the LHS correctly for things like renaming
				if field, ok := field.derived.(^ast.Field_Value); ok {
					if ident, ok := field.field.derived.(^ast.Ident); ok {
						data.symbols[cast(uintptr)ident] = SymbolAndNode {
							node   = ident,
							symbol = new_clone(
								Symbol {
									name = ident.name,
									range = common.get_token_range(ident, string(data.document.text)),
									uri = strings.clone(
										common.create_uri(field.pos.file, data.ast_context.allocator).uri,
										data.ast_context.allocator,
									),
								},
								data.ast_context.allocator,
							),
						}
					} else if binary, ok := field.field.derived.(^ast.Binary_Expr); ok {
						data.symbols[cast(uintptr)binary] = SymbolAndNode {
							node   = binary,
							symbol = new_clone(
								Symbol {
									name = "binary",
									range = common.get_token_range(binary, string(data.document.text)),
									uri = strings.clone(
										common.create_uri(field.pos.file, data.ast_context.allocator).uri,
										data.ast_context.allocator,
									),
								},
								data.ast_context.allocator,
							),
						}
					}
				}
			}
		}
	case ^ast.Bit_Set_Type:
		data.position_context.bitset_type = n
		resolve_node(n.elem, data)
		resolve_node(n.underlying, data)
	case ^ast.Map_Type:
		resolve_node(n.key, data)
		resolve_node(n.value, data)
	case ^ast.Or_Else_Expr:
		resolve_node(n.x, data)
		resolve_node(n.y, data)
	case ^ast.Or_Return_Expr:
		resolve_node(n.expr, data)
	case ^ast.Or_Branch_Expr:
		resolve_node(n.expr, data)
		add_label(n.label, data)
	case ^ast.Bit_Field_Type:
		data.position_context.bit_field_type = n
		resolve_node(n.backing_type, data)
		resolve_nodes(n.fields, data)
	case ^ast.Bit_Field_Field:
		// rols: the field name is a declaration, never resolved as an identifier
		resolve_node(n.type, data)
		resolve_node(n.bit_size, data)
		if data.flag != .None {
			data.symbols[cast(uintptr)n.name] = SymbolAndNode {
				node   = n.name,
				symbol = new_clone(
					Symbol {
						range = common.get_token_range(n.name, string(data.document.text)),
						uri = strings.clone(
							common.create_uri(n.pos.file, data.ast_context.allocator).uri,
							data.ast_context.allocator,
						),
					},
					data.ast_context.allocator,
				),
			}
		}
	case:
	}


}

@(private = "file")
resolve_nodes :: proc(array: []$T/^ast.Node, data: ^FileResolveData) {
	for elem in array {
		resolve_node(elem, data)
	}
}

@(private = "file")
add_label :: proc(label: ^ast.Expr, data: ^FileResolveData) {
	if label == nil {
		return
	}

	if ident, ok := label.derived.(^ast.Ident); ok {
		if symbol, ok := resolve_label(data.ast_context, ident.name); ok {
			data.symbols[cast(uintptr)label] = SymbolAndNode {
				node = label,
				symbol = symbol,
			}
		}
	}
}
