package server

import "core:fmt"
import "core:odin/ast"
import "core:strings"

import "src:common"

Call_Site :: struct {
	document: ^Document,
	call:     ^ast.Call_Expr,
}

// One declared parameter name with its field; a field declares several names with one type.
Param_Name :: struct {
	field: ^ast.Field,
	name:  ^ast.Ident, // nil for a polymorphic name
}

param_names :: proc(lit: ^ast.Proc_Lit) -> []Param_Name {
	names := make([dynamic]Param_Name, context.temp_allocator)
	if lit.type != nil && lit.type.params != nil {
		for field in lit.type.params.list {
			for name in field.names {
				append(&names, Param_Name{field, name.derived.(^ast.Ident) or_else nil})
			}
		}
	}
	return names[:]
}

// The top-level declaration whose value is lit.
proc_decl_of :: proc(document: ^Document, lit: ^ast.Proc_Lit) -> (^ast.Value_Decl, bool) {
	for decl in top_level_value_decls(document.ast) {
		if len(decl.names) == 1 && len(decl.values) == 1 && decl.values[0] == lit {
			return decl, true
		}
	}
	return nil, false
}

// Why the argument shape of lit may not change, or "" when it may: it needs a body, no polymorphism,
// variadics, defaults or field flags, and no attribute fixing the signature for a linker or a deferred call.
// Only the first cause that applies is named.
signature_problem :: proc(decl: ^ast.Value_Decl, lit: ^ast.Proc_Lit) -> string {
	if lit.body == nil {
		return "the procedure has no body"
	}
	// rols: `generic` misses a poly type nested in a parameter type such as `^Ctx($Msg)`, because core:odin/parser
	// `is_expr_generic` has no Call_Expr case.
	if lit.type == nil || lit.type.generic || len(lit.where_clauses) > 0 || expr_contains_poly(lit.type) {
		return "the procedure is polymorphic or has a where clause"
	}
	if has_fixed_signature_attribute(decl.attributes[:]) {
		return "an attribute of the procedure fixes its signature"
	}
	for param in param_names(lit) {
		if param.name == nil {
			return "a parameter has no name"
		}
		if param.field.flags != {} {
			return "a parameter has flags such as #any_int or using"
		}
		if param.field.default_value != nil {
			return "a parameter has a default value"
		}
		if _, variadic := param.field.type.derived.(^ast.Ellipsis); variadic {
			return "the procedure is variadic"
		}
	}
	return ""
}

// Every call of the procedure decl declares, or of one of its variants, in the open document and the rest
// of the workspace (files stands in for the workspace). Fails when the procedure is referenced other than as a callee,
// since its argument shape then cannot change, or when a call names, spreads or omits arguments.
// reason says why in a sentence for the user.
find_call_sites :: proc(
	document: ^Document,
	decl: ^ast.Value_Decl,
	param_count: int,
	files: []Package_File,
	variants: []Symbol = {},
) -> (
	sites: []Call_Site,
	reason: string,
	ok: bool,
) {
	h := Call_Hierarchy{files, make(map[string]^Document, context.temp_allocator)}
	h.documents[document.uri.uri] = document
	name := final_name(decl.names[0])
	locations := proc_references(document, decl, files, variants)

	found := make([dynamic]Call_Site, context.temp_allocator)
	for location in locations {
		caller := hierarchy_document(&h, location.uri)
		if caller == nil {
			return {}, fmt.tprintf("cannot read %s", common.uri_to_path(location.uri, context.temp_allocator)), false
		}
		where_ := location_text(location, caller)
		call, offset_ok := call_at_reference(caller, location)
		if !offset_ok {
			return {}, fmt.tprintf("cannot locate the reference at %s", where_), false
		}
		if call == nil {
			return {}, fmt.tprintf("%s uses %s other than as a call", where_, name), false
		}
		if call.ellipsis.kind != .Invalid || len(call.args) != param_count {
			return {}, fmt.tprintf("the call at %s spreads or omits arguments", where_), false
		}
		for arg in call.args {
			if _, named := arg.derived.(^ast.Field_Value); named {
				return {}, fmt.tprintf("the call at %s names its arguments", where_), false
			}
		}
		append(&found, Call_Site{caller, call})
	}
	return found[:], "", true
}

// Every reference to the procedure decl declares, or to one of its variants, outside the declarations, in the
// open document and the rest of the workspace (files stands in for the workspace).
proc_references :: proc(
	document: ^Document,
	decl: ^ast.Value_Decl,
	files: []Package_File,
	variants: []Symbol = {},
) -> []common.Location {
	ast_context := make_ast_context(
		document.ast,
		document.imports,
		document.package_name,
		document.uri.uri,
		document.fullpath,
		context.temp_allocator,
	)
	get_globals(document.ast, &ast_context)

	name := final_name(decl.names[0])
	symbol := Symbol {
		uri   = document.uri.uri,
		range = common.get_token_range(decl.names[0], document.ast.src),
		pkg   = document.package_name,
		name  = name,
	}
	locations, _ := find_symbol_references(
		document,
		&ast_context,
		symbol,
		.Identifier,
		include_declaration = false,
		target_name = name,
		files = files,
		variants = variants,
	)
	return locations
}

// The call whose callee is the name at location, or nil when the reference is not a callee. A name
// inside a callee expression, such as `f` in `h(f)()`, is not one. ok is false when the location lies
// outside the document text.
call_at_reference :: proc(caller: ^Document, location: common.Location) -> (call: ^ast.Call_Expr, ok: bool) {
	offset := common.get_absolute_position(location.range.start, caller.text[:caller.used_text]) or_return
	for at in nodes_at(caller.ast.decls[:], offset) {
		c, is_call := at.node.derived.(^ast.Call_Expr)
		if is_call && c.expr.pos.offset <= offset && offset < c.expr.end.offset {
			call = c
		}
	}
	if call == nil {
		return nil, true
	}
	#partial switch c in ast.unparen_expr(call.expr).derived {
	case ^ast.Ident:
		if c.pos.offset == offset do return call, true
	case ^ast.Selector_Expr:
		if c.field != nil && c.field.pos.offset == offset do return call, true
	}
	return nil, true
}

// FILE:LINE:COL of a location in document, 1-based with the column in bytes, as the CLI prints positions.
location_text :: proc(location: common.Location, document: ^Document) -> string {
	start := location.range.start
	column := start.character
	text := document.text[:document.used_text]
	if line_start, ok := common.get_absolute_position({line = start.line}, text); ok {
		column = common.get_character_offset_u16_to_u8(start.character, text[line_start:])
	}
	return fmt.tprintf("%s:%d:%d", document.fullpath, start.line + 1, column + 1)
}

Changes :: map[string][dynamic]TextEdit

append_edit :: proc(changes: ^Changes, document: ^Document, start, end: int, text: string) {
	edits := &changes[document.uri.uri]
	if edits == nil {
		changes[document.uri.uri] = make([dynamic]TextEdit, context.temp_allocator)
		edits = &changes[document.uri.uri]
	}
	bytes := document.text[:document.used_text]
	append(
		edits,
		TextEdit {
			range = {
				common.get_relative_token_position(start, bytes, 0),
				common.get_relative_token_position(end, bytes, 0),
			},
			newText = text,
		},
	)
}

workspace_edit :: proc(changes: Changes) -> WorkspaceEdit {
	edit: WorkspaceEdit
	edit.changes = make(map[string][]TextEdit, len(changes), context.temp_allocator)
	for uri, edits in changes {
		edit.changes[uri] = edits[:]
	}
	return edit
}

// Appends text as a new last item of a comma separated list closed at close.
append_list_item :: proc(changes: ^Changes, document: ^Document, items: []$T, close: int, text: string) {
	if len(items) == 0 {
		append_edit(changes, document, close, close, text)
		return
	}
	last := items[len(items) - 1].end.offset
	append_edit(changes, document, last, last, strings.concatenate({", ", text}, context.temp_allocator))
}

// Deletes item i of a comma separated list together with one adjoining comma.
remove_list_item :: proc(changes: ^Changes, document: ^Document, items: []$T, i: int) {
	start, end := items[i].pos.offset, items[i].end.offset
	if i + 1 < len(items) {
		end = items[i + 1].pos.offset
	} else if i > 0 {
		start = items[i - 1].end.offset
	}
	append_edit(changes, document, start, end, "")
}

// Reorders the parameters of the procedure declared at position: order lists the new order by old
// index. Fields with several names are split so any order is possible. reason says why a reorder is
// refused.
reorder_params :: proc(
	document: ^Document,
	position: common.Position,
	order: []int,
	files: []Package_File = {},
) -> (
	edit: WorkspaceEdit,
	reason: string,
	ok: bool,
) {
	src := document.ast.src
	offset, offset_ok := common.get_absolute_position(position, document.text[:document.used_text])
	if !offset_ok {
		return {}, "the position is outside the file", false
	}

	decl: ^ast.Value_Decl
	for d in top_level_value_decls(document.ast) {
		if len(d.names) == 1 && d.names[0].pos.offset <= offset && offset <= d.names[0].end.offset {
			decl = d
		}
	}
	if decl == nil || len(decl.values) != 1 {
		return {}, "the position is not on the name of a top-level procedure", false
	}
	lit := decl.values[0].derived.(^ast.Proc_Lit) or_else nil
	if lit == nil {
		return {}, "the position is not on the name of a top-level procedure", false
	}
	if problem := signature_problem(decl, lit); problem != "" {
		return {}, problem, false
	}

	params := param_names(lit)
	if len(params) == 0 || len(order) != len(params) {
		return {}, fmt.tprintf("--order must list %d parameter indices, one per parameter", len(params)), false
	}
	seen := make([]bool, len(params), context.temp_allocator)
	for i in order {
		if i < 0 || i >= len(params) || seen[i] {
			return {}, fmt.tprintf("--order must list each index from 0 to %d exactly once", len(params) - 1), false
		}
		seen[i] = true
	}

	// The platform variants of the procedure take the same reorder, so they must have the same parameters.
	h := Call_Hierarchy{files, make(map[string]^Document, context.temp_allocator)}
	h.documents[document.uri.uri] = document
	symbol := Symbol {
		uri   = document.uri.uri,
		range = common.get_token_range(decl.names[0], src),
		pkg   = document.package_name,
		name  = final_name(decl.names[0]),
	}
	variants := declaration_variants(&h, symbol)
	for variant in variants {
		if problem := variant_problem(variant, params, src); problem != "" {
			where_ := location_text({uri = variant.symbol.uri, range = variant.symbol.range}, variant.document)
			return {}, fmt.tprintf("the variant of `%s` at %s %s", symbol.name, where_, problem), false
		}
	}

	sites, sites_reason, sites_ok := find_call_sites(document, decl, len(params), files, variant_symbols(variants))
	if !sites_ok {
		return {}, sites_reason, false
	}

	changes := make(Changes, context.temp_allocator)

	reorder_param_list(&changes, document, lit, order)
	for variant in variants {
		reorder_param_list(&changes, variant.document, variant.decl.values[0].derived.(^ast.Proc_Lit), order)
	}

	for site in sites {
		args := site.call.args
		for i, k in order {
			append_edit(
				&changes,
				site.document,
				args[k].pos.offset,
				args[k].end.offset,
				node_text(site.document.ast.src, args[i]),
			)
		}
	}
	return workspace_edit(changes), "", true
}

// Rewrites the parameter list of lit in document in the new order.
@(private = "file")
reorder_param_list :: proc(changes: ^Changes, document: ^Document, lit: ^ast.Proc_Lit, order: []int) {
	params := param_names(lit)
	texts := make([]string, len(params), context.temp_allocator)
	for i, k in order {
		texts[k] = strings.concatenate(
			{params[i].name.name, ": ", node_text(document.ast.src, params[i].field.type)},
			context.temp_allocator,
		)
	}
	fields := lit.type.params.list
	append_edit(
		changes,
		document,
		fields[0].pos.offset,
		fields[len(fields) - 1].end.offset,
		strings.join(texts, ", ", context.temp_allocator),
	)
}

// Why the variant cannot take the reorder of a procedure with params, declared in src, or "" when it can:
// it must be a procedure whose signature may change, with the same parameter names and type texts.
@(private = "file")
variant_problem :: proc(variant: Decl_Variant, params: []Param_Name, src: string) -> string {
	decl := variant.decl
	if len(decl.names) != 1 || len(decl.values) != 1 {
		return "is not a single procedure declaration"
	}
	lit, is_proc := decl.values[0].derived.(^ast.Proc_Lit)
	if !is_proc {
		return "is not a procedure"
	}
	if problem := signature_problem(decl, lit); problem != "" {
		return fmt.tprintf("cannot change: %s", problem)
	}
	theirs := param_names(lit)
	if len(theirs) != len(params) {
		return "has different parameters"
	}
	for param, i in params {
		if theirs[i].name.name != param.name.name ||
		   node_text(variant.document.ast.src, theirs[i].field.type) != node_text(src, param.field.type) {
			return "has different parameters"
		}
	}
	return ""
}
