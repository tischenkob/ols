#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:strings"

// A parameter that the action threads: its name, the parameter it adds, and the type name that a parameter of that kind
// has.
Threaded :: struct {
	title, name, param, type_name: string,
}

THREADED := [?]Threaded {
	{"Add allocator parameter", "allocator", "allocator := context.allocator", "Allocator"},
	{"Add caller location", "loc", "loc := #caller_location", "Source_Code_Location"},
}

// On the name of a top-level procedure: "Add allocator parameter" adds `allocator := context.allocator` and passes it to
// each call in the body whose callee takes an allocator and is passed none, and "Add caller location" does the same
// with `loc := #caller_location`. A caller that has a parameter of that kind passes it too. Other callers stay, since
// the new parameter has a default.
@(private = "package")
add_allocator_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_add_allocator {
		return
	}
	decl, found := top_decl_at(ctx.document, ctx.range.start)
	// A variable can take another procedure, and a declared type keeps the old signature.
	if !found || decl.is_mutable || decl.type != nil || len(decl.values) != 1 {
		return
	}
	lit, is_proc := decl.values[0].derived.(^ast.Proc_Lit)
	if !is_proc || lit.body == nil || lit.type == nil || lit.type.params == nil {
		return
	}
	// A foreign or contextless calling convention has no context to take the default from.
	if cc, has_cc := lit.type.calling_convention.(string);
	   lit.type.calling_convention != nil && (!has_cc || cc != "\"odin\"") {
		return
	}
	if has_fixed_signature_attribute(decl.attributes[:]) {
		return
	}
	for name in attribute_names(decl.attributes[:]) {
		if name == "init" || name == "fini" || name == "test" {
			return
		}
	}
	for field in lit.type.params.list {
		if field.type == nil {
			continue
		}
		if _, variadic := field.type.derived.(^ast.Ellipsis); variadic {
			return
		}
	}

	defer restore_locals(ctx)
	calls := body_calls(lit.body)
	references: Caller_Sites
	for kind in THREADED {
		changes, ok := thread_param(ctx, decl, lit, calls, kind, &references)
		if ok {
			append(
				ctx.actions,
				CodeAction{title = kind.title, kind = "refactor.rewrite", edit = workspace_edit(changes)},
			)
		}
	}
}

// The calls of the procedure, found once for both kinds. ok is false when the procedure is referenced other than as a
// callee.
Caller_Sites :: struct {
	sites:    []Caller_Site,
	ok, done: bool,
}

// A call of the procedure and the procedure around it, nil at file scope.
Caller_Site :: struct {
	document: ^Document,
	call:     ^ast.Call_Expr,
	caller:   ^ast.Proc_Lit,
}

thread_param :: proc(
	ctx: ^ActionContext,
	decl: ^ast.Value_Decl,
	lit: ^ast.Proc_Lit,
	calls: []^ast.Call_Expr,
	kind: Threaded,
	references: ^Caller_Sites,
) -> (
	changes: Changes,
	ok: bool,
) {
	// The new parameter would take the place of what the name means now, also in a nested procedure, which cannot
	// see a parameter of the procedure around it.
	for use in collect_ident_uses(lit) {
		if use.ident.name == kind.name && !is_member_name(use) {
			return
		}
	}

	changes = make(Changes, context.temp_allocator)
	threaded := false
	for call in calls {
		if takes_param(ctx, lit, call, kind) {
			pass_param(&changes, ctx.document, call, kind.name)
			threaded = true
		}
	}
	// A parameter that nothing in the body passes on only lengthens the signature.
	if !threaded {
		return
	}

	h := Call_Hierarchy{ctx.files, make(map[string]^Document, context.temp_allocator)}
	if len(top_level_variants(&h, ctx.document, decl)) > 0 {
		return
	}
	if !references.done {
		references.sites, references.ok = caller_sites(ctx, decl)
		references.done = true
	}
	if !references.ok {
		return
	}
	for site in references.sites {
		if site.caller == lit || has_param_kind(site.caller, kind) {
			pass_param(&changes, site.document, site.call, kind.name)
		}
	}

	params := lit.type.params
	src := ctx.document.ast.src
	// The parser leaves Field_List.close unset; with no fields the first `)` after `proc` closes the list.
	close := lit.type.pos.offset + strings.index_byte(src[lit.type.pos.offset:], ')')
	append_list_item(&changes, ctx.document, params.list, close, kind.param)
	return changes, true
}

// The calls of the procedure, each with the procedure around it. Fails when the procedure is referenced other than as
// a callee, as a value or in a group, whose type the new parameter would change.
caller_sites :: proc(ctx: ^ActionContext, decl: ^ast.Value_Decl) -> ([]Caller_Site, bool) {
	h := Call_Hierarchy{ctx.files, make(map[string]^Document, context.temp_allocator)}
	h.documents[ctx.document.uri.uri] = ctx.document
	sites := make([dynamic]Caller_Site, context.temp_allocator)
	for location in proc_references(ctx.document, decl, ctx.files) {
		document := hierarchy_document(&h, location.uri)
		if document == nil {
			return nil, false
		}
		call, offset_ok := call_at_reference(document, location)
		if !offset_ok || call == nil {
			return nil, false
		}
		caller: ^ast.Proc_Lit
		for at in nodes_at(document.ast.decls[:], call.pos.offset) {
			if function, is_function := at.node.derived.(^ast.Proc_Lit); is_function {
				caller = function
			}
		}
		append(&sites, Caller_Site{document, call, caller})
	}
	return sites[:], true
}

// Whether function declares a parameter of the threaded kind.
has_param_kind :: proc(function: ^ast.Proc_Lit, kind: Threaded) -> bool {
	if function == nil || function.type == nil || function.type.params == nil {
		return false
	}
	for field in function.type.params.list {
		for name in field.names {
			if ident, is_ident := name.derived.(^ast.Ident); is_ident && ident.name == kind.name {
				return is_kind_field(field, kind)
			}
		}
	}
	return false
}

// Whether field has the type of the threaded kind, written or taken from a default such as `context.allocator`,
// `context.temp_allocator` or `#caller_location`.
is_kind_field :: proc(field: ^ast.Field, kind: Threaded) -> bool {
	if field.type != nil {
		return final_name(field.type) == kind.type_name
	}
	#partial switch v in field.default_value.derived {
	case ^ast.Selector_Expr:
		base, is_context := v.expr.derived.(^ast.Implicit)
		return(
			kind.name == "allocator" &&
			is_context &&
			base.tok.kind == .Context &&
			v.field != nil &&
			strings.has_suffix(v.field.name, "allocator") \
		)
	case ^ast.Basic_Directive:
		return kind.name == "loc" && v.name == "caller_location"
	}
	return false
}

// Appends `name = name` to the arguments of call.
pass_param :: proc(changes: ^Changes, document: ^Document, call: ^ast.Call_Expr, name: string) {
	append_list_item(changes, document, call.args, call.close.offset, fmt.tprintf("%s = %s", name, name))
}

// The calls in body, not in a nested procedure, which cannot see the parameters.
body_calls :: proc(body: ^ast.Stmt) -> []^ast.Call_Expr {
	calls := make([dynamic]^ast.Call_Expr, context.temp_allocator)
	visitor := ast.Visitor {
		data = &calls,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			if node == nil {
				return nil
			}
			#partial switch n in node.derived {
			case ^ast.Proc_Lit:
				return nil
			case ^ast.Call_Expr:
				append((^[dynamic]^ast.Call_Expr)(visitor.data), n)
			}
			return visitor
		},
	}
	ast.walk(&visitor, body)
	return calls[:]
}

// Whether call runs a procedure with a parameter named name of the threaded kind, and leaves it to its default. Each
// member that a group call can pick must have it.
takes_param :: proc(ctx: ^ActionContext, lit: ^ast.Proc_Lit, call: ^ast.Call_Expr, kind: Threaded) -> bool {
	name := kind.name
	// A spread fills the parameters it reaches, which the resolved arguments do not show.
	if call.ellipsis.kind != .Invalid {
		return false
	}
	positional := 0
	for arg in call.args {
		if field, named := arg.derived.(^ast.Field_Value); named {
			if ident, is_ident := field.field.derived.(^ast.Ident); is_ident && ident.name == name {
				return false
			}
		} else {
			positional += 1
		}
	}

	gather_locals_in(ctx, lit, call.pos.offset)
	symbol, resolved := resolve_type_expression(ctx.ast_context, call)
	if !resolved {
		return false
	}
	#partial switch v in symbol.value {
	case SymbolProcedureValue:
		return leaves_default(v, positional, kind)
	case SymbolAggregateValue:
		for member in v.symbols {
			value, is_proc := member.value.(SymbolProcedureValue)
			if !is_proc || !leaves_default(value, positional, kind) {
				return false
			}
		}
		return len(v.symbols) > 0
	}
	return false
}

// Whether a call with positional arguments leaves the parameter of the threaded kind of callee to its default. A
// parameter after a variadic one takes only a named argument.
leaves_default :: proc(callee: SymbolProcedureValue, positional: int, kind: Threaded) -> bool {
	index := 0
	after_variadic := false
	for field in callee.arg_types {
		if field.type != nil {
			if _, variadic := field.type.derived.(^ast.Ellipsis); variadic {
				after_variadic = true
			}
		}
		for field_name in field.names {
			ident, is_ident := field_name.derived.(^ast.Ident)
			if is_ident && ident.name == kind.name {
				return(
					field.default_value != nil &&
					is_kind_field(field, kind) &&
					(after_variadic || positional <= index) \
				)
			}
			index += 1
		}
	}
	return false
}
