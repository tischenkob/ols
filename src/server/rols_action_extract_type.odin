#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:os"
import "core:slice"
import "core:strings"

import "src:common"

// "Extract type" on an inline struct, union, enum, bit_set, procedure type or long array type written as the type of a
// parameter, field or declaration, and "Inline type alias" on the name of a top-level `X :: Y`.
@(private = "package")
add_extract_type_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_extract_type {
		return
	}
	add_inline_alias(ctx)
	add_extract_type(ctx)
}

add_extract_type :: proc(ctx: ^ActionContext) {
	nodes := nodes_at(ctx.document.ast.decls[:], ctx.range.start)
	if len(nodes) == 0 {
		return
	}
	// A type of a foreign block takes its calling convention, and one under a file-scope `when` its names.
	if _, is_top := nodes[0].node.derived.(^ast.Value_Decl); !is_top {
		return
	}
	type: ^ast.Expr
	owner: ^ast.Node
	#reverse for at in nodes {
		if !extractable(ctx.document.ast.src, at.node) || at.parent == nil {
			continue
		}
		#partial switch p in at.parent.derived {
		case ^ast.Field:
			if p.type == at.node {
				type, owner = cast(^ast.Expr)at.node, p
			}
		case ^ast.Value_Decl:
			if p.type == at.node {
				type, owner = cast(^ast.Expr)at.node, p
			}
		}
		if type != nil {
			break
		}
	}
	if type == nil || ctx.range.end > type.end.offset || !names_hold_at_file_scope(ctx, type) {
		return
	}
	src := ctx.document.ast.src
	text := node_text(src, type)
	// Each spelling of an inline struct, union or enum is the same type, and a named one differs from all of them.
	#partial switch _ in type.derived {
	case ^ast.Struct_Type, ^ast.Union_Type, ^ast.Enum_Type:
		if spelled_elsewhere(ctx, text) {
			return
		}
	}

	base := "Type"
	names: []^ast.Expr
	#partial switch o in owner.derived {
	case ^ast.Field:
		names = o.names
	case ^ast.Value_Decl:
		names = o.names
	}
	if len(names) > 0 {
		ada := strings.to_ada_case(node_text(src, names[0]), context.temp_allocator)
		if is_plain_name(ada) && ada != "_" {
			base = ada
		}
	}
	probe: ast.Ident
	probe.pos = type.pos
	probe.name = base
	for i := 2; package_declares(ctx, probe.name) || is_taken(ctx, probe); i += 1 {
		probe.name = fmt.tprintf("%s%d", base, i)
	}
	name := probe.name

	written := reindent(text, get_line_indentation(src, type.pos.offset), "")
	insert, ok := insert_after_decl(ctx, type.pos.offset, fmt.tprintf("%s :: %s", name, written))
	if !ok {
		return
	}
	edits := make([]TextEdit, 2, context.temp_allocator)
	edits[0] = {
		range   = range_of(ctx, type.pos.offset, type.end.offset),
		newText = name,
	}
	edits[1] = insert
	append(ctx.actions, make_code_action(ctx, "Extract type", "refactor.extract", edits))
}

// An inline type worth a name: a struct, union, enum, bit_set or procedure type, or an array type that nests another
// or spans 16 characters or more.
extractable :: proc(src: string, node: ^ast.Node) -> bool {
	#partial switch n in node.derived {
	case ^ast.Struct_Type:
		return n.poly_params == nil
	case ^ast.Union_Type:
		return n.poly_params == nil
	case ^ast.Enum_Type, ^ast.Bit_Set_Type, ^ast.Proc_Type:
		return true
	case ^ast.Array_Type:
		return n.tag == nil && long_array(src, n, n.elem)
	case ^ast.Dynamic_Array_Type:
		return n.tag == nil && long_array(src, n, n.elem)
	}
	return false
}

long_array :: proc(src: string, node: ^ast.Node, elem: ^ast.Expr) -> bool {
	if elem != nil {
		#partial switch _ in elem.derived {
		case ^ast.Array_Type, ^ast.Dynamic_Array_Type, ^ast.Map_Type:
			return true
		}
	}
	return len(strip_space(node_text(src, node))) >= 16
}

// Whether every name that the type reads means the same at file scope: no local, parameter, local type or poly
// parameter, and nothing unresolved. Field and member names are no reads.
names_hold_at_file_scope :: proc(ctx: ^ActionContext, type: ^ast.Expr) -> bool {
	Data :: struct {
		ctx: ^ActionContext,
		ok:  bool,
	}
	data := Data{ctx, true}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil || !data.ok {
				return nil
			}
			#partial switch n in node.derived {
			case ^ast.Field:
				ast.walk(visitor, n.type)
				ast.walk(visitor, n.default_value)
				return nil
			case ^ast.Enum_Type:
				ast.walk(visitor, n.base_type)
				for field in n.fields {
					if value, is_value := field.derived.(^ast.Field_Value); is_value {
						ast.walk(visitor, value.value)
					}
				}
				return nil
			case ^ast.Selector_Expr:
				ast.walk(visitor, n.expr)
				return nil
			case ^ast.Poly_Type, ^ast.Implicit_Selector_Expr, ^ast.Typeid_Type:
				data.ok = false
				return nil
			case ^ast.Ident:
				data.ctx.ast_context.use_locals = true
				symbol, ok := resolve_type_identifier(data.ctx.ast_context, n^)
				data.ok = ok && symbol.flags & {.Local, .Parameter, .PolyType} == {}
				return nil
			}
			return visitor
		},
	}
	reset_ast_context(ctx.ast_context)
	ast.walk(&visitor, type)
	return data.ok
}

// Whether the text of the type, spaces aside, appears more than once in the workspace.
spelled_elsewhere :: proc(ctx: ^ActionContext, text: string) -> bool {
	keyword := strings.fields(text, context.temp_allocator)[0]
	documents, ok := workspace_documents(ctx, keyword)
	if !ok {
		return true
	}
	stripped := strip_space(text)
	count := 0
	for document in documents {
		count += strings.count(strip_space(document.ast.src), stripped)
	}
	return count > 1
}

add_inline_alias :: proc(ctx: ^ActionContext) {
	decl, found := top_decl_at(ctx.document, ctx.range.start)
	if !found || decl.is_mutable || decl.type != nil || len(decl.values) != 1 {
		return
	}
	value := decl.values[0]
	if !is_alias_value(ctx, value) {
		return
	}
	src := ctx.document.ast.src
	name := node_text(src, decl.names[0])
	text := node_text(src, value)
	if strings.contains_any(text, "\r\n") {
		return
	}
	exported := !is_file_private(decl.attributes[:]) && !has_attribute(decl.attributes[:], "private")
	if exported && used_outside_filter(ctx, name) {
		return
	}

	locations := alias_references(ctx, decl)
	h := Call_Hierarchy{ctx.files, make(map[string]^Document, context.temp_allocator)}
	h.documents[ctx.uri] = ctx.document
	words := alias_words(text)
	changes := make(Changes, context.temp_allocator)
	checked := make(map[^Document]bool, context.temp_allocator)
	for location in locations {
		document := hierarchy_document(&h, location.uri)
		if document == nil {
			return
		}
		offset, offset_ok := common.get_absolute_position(location.range.start, document.text[:document.used_text])
		if !offset_ok {
			return
		}
		use, parent, use_ok := use_at(document, offset, name)
		if !use_ok {
			return
		}
		replacement: string
		if document.package_name == ctx.document.package_name && same_dir(document, ctx.document) {
			if _, is_selector := use.derived.(^ast.Selector_Expr); is_selector {
				return
			}
			if !checked[document] {
				if !words_hold(ctx.document, document, words) {
					return
				}
				checked[document] = true
			}
			replacement = text
		} else {
			// Another package reaches the alias through its import, `pkg.X`, so only a plain name moves there.
			selector, is_selector := use.derived.(^ast.Selector_Expr)
			target, is_ident := value.derived.(^ast.Ident)
			if !is_selector || !is_ident {
				return
			}
			reach, reach_ok := reached_from(
				ctx,
				target,
				node_text(document.ast.src, selector.expr),
				document.package_name,
			)
			if !reach_ok {
				return
			}
			replacement = reach
		}
		// `X(v)` converts, and `^T(v)` would dereference the result instead.
		if call, is_call := parent.derived.(^ast.Call_Expr); is_call && call.expr == use {
			#partial switch _ in value.derived {
			case ^ast.Ident, ^ast.Selector_Expr:
			case:
				replacement = fmt.tprintf("(%s)", replacement)
			}
		}
		append_edit(&changes, document, use.pos.offset, use.end.offset, replacement)
	}

	// The alias goes with its comment and attributes.
	first := decl.pos.offset
	if decl.docs != nil do first = min(first, decl.docs.pos.offset)
	for attribute in decl.attributes do first = min(first, attribute.pos.offset)
	if strings.trim_space(src[line_start(src, first):first]) != "" {
		return
	}
	rest := src[decl.end.offset:]
	newline := strings.index_byte(rest, '\n')
	line_rest := rest if newline < 0 else rest[:newline]
	if trimmed := strings.trim_space(line_rest); trimmed != "" && !strings.has_prefix(trimmed, "//") {
		return
	}
	first_line := common.get_relative_token_position(first, ctx.document.text[:ctx.document.used_text], 0).line
	last_line := decl.end.line - 1
	// A blank line after the alias goes too, so that two blank lines do not remain.
	after := decl.end.offset + (len(rest) if newline < 0 else newline + 1)
	next := strings.index_byte(src[after:], '\n')
	if next >= 0 && strings.trim_space(src[after:after + next]) == "" && first_line > 0 {
		last_line += 1
	}
	edits := &changes[ctx.uri]
	if edits == nil {
		changes[ctx.uri] = make([dynamic]TextEdit, context.temp_allocator)
		edits = &changes[ctx.uri]
	}
	append(edits, delete_lines_edit(ctx, first_line, last_line))
	append(
		ctx.actions,
		CodeAction{title = "Inline type alias", kind = "refactor.inline", edit = workspace_edit(changes)},
	)
}

line_start :: proc(src: string, offset: int) -> int {
	at := offset
	for at > 0 && src[at - 1] != '\n' {
		at -= 1
	}
	return at
}

same_dir :: proc(a, b: ^Document) -> bool {
	dir_of :: proc(path: string) -> string {
		slash := strings.last_index_byte(path, '/')
		return path[:max(slash, 0)]
	}
	return dir_of(a.fullpath) == dir_of(b.fullpath)
}

// Whether the value of `X :: value` names another type without making a new one: not `distinct`, a struct, union,
// enum or bit_field, which each declare a type, nor a parametric type or its instance.
is_alias_value :: proc(ctx: ^ActionContext, value: ^ast.Expr) -> bool {
	#partial switch v in value.derived {
	case ^ast.Ident, ^ast.Selector_Expr:
		reset_ast_context(ctx.ast_context)
		symbol, resolved := resolve_type_expression(ctx.ast_context, value)
		if !resolved || symbol.pointers > 0 || .Mutable in symbol.flags {
			return false
		}
		#partial switch symbol.type {
		case .Function, .Variable, .Constant, .Package, .EnumMember, .Field, .Unresolved:
			return false
		}
		#partial switch s in symbol.value {
		case SymbolStructValue:
			return s.poly == nil
		case SymbolUnionValue:
			return s.poly == nil
		case SymbolProcedureValue,
		     SymbolProcedureGroupValue,
		     SymbolAggregateValue,
		     SymbolPackageValue,
		     SymbolUntypedValue,
		     SymbolPolyTypeValue,
		     SymbolGenericValue:
			return false
		}
		return true
	case ^ast.Pointer_Type,
	     ^ast.Multi_Pointer_Type,
	     ^ast.Map_Type,
	     ^ast.Bit_Set_Type,
	     ^ast.Proc_Type,
	     ^ast.Matrix_Type:
		return names_hold_at_file_scope(ctx, value)
	case ^ast.Array_Type:
		return v.tag == nil && names_hold_at_file_scope(ctx, value)
	case ^ast.Dynamic_Array_Type:
		return v.tag == nil && names_hold_at_file_scope(ctx, value)
	}
	return false
}

// How another package that imports the alias package as pkg writes the type that target names: `pkg.T` for a type of
// the package that is not private, and the bare name of a builtin type.
reached_from :: proc(ctx: ^ActionContext, target: ^ast.Ident, pkg: string, use_pkg: string) -> (string, bool) {
	if global, is_global := ctx.ast_context.globals[target.name]; is_global {
		return fmt.tprintf("%s.%s", pkg, target.name), global.private == .Public
	}
	if symbol, indexed := lookup(target.name, ctx.document.package_name, ctx.document.fullpath); indexed {
		return fmt.tprintf("%s.%s", pkg, target.name), symbol.flags & {.PrivateFile, .PrivatePackage} == {}
	}
	return target.name, builtin_without_decl(target.name, use_pkg)
}

// The references to the alias outside its declaration, across the workspace.
alias_references :: proc(ctx: ^ActionContext, decl: ^ast.Value_Decl) -> []common.Location {
	document := ctx.document
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
		files = ctx.files,
	)
	return locations
}

// The `X` or `pkg.X` written at offset in document, and the node around it.
use_at :: proc(document: ^Document, offset: int, name: string) -> (use: ^ast.Expr, parent: ^ast.Node, ok: bool) {
	nodes := nodes_at(document.ast.decls[:], offset)
	#reverse for at, i in nodes {
		ident, is_ident := at.node.derived.(^ast.Ident)
		if !is_ident {
			continue
		}
		if ident.name != name || ident.pos.offset != offset {
			return nil, nil, false
		}
		use, parent = ident, at.parent
		if selector, is_selector := at.parent.derived.(^ast.Selector_Expr); is_selector && selector.field == ident {
			use = selector
			parent = nodes[i - 1].parent if i > 0 else nil
		}
		return use, parent, parent != nil
	}
	return nil, nil, false
}

// The names that the alias value reads: the package before a `.` and each plain name.
alias_words :: proc(text: string) -> []string {
	words := make([dynamic]string, context.temp_allocator)
	for word in type_words(text) {
		switch word {
		case "map", "dynamic", "matrix", "bit_set", "proc", "distinct":
			continue
		}
		if '0' <= word[0] && word[0] <= '9' {
			continue
		}
		first, _, _ := strings.partition(word, ".")
		append(&words, first)
	}
	return words[:]
}

// Whether the names of the alias value mean in document what they mean in home: an import alias imports the same
// package, and no procedure of document declares a local, parameter or label of that name.
words_hold :: proc(home, document: ^Document, words: []string) -> bool {
	for word in words {
		home_import, is_import := import_named(home, word)
		other_import, other_is_import := import_named(document, word)
		if is_import != other_is_import || (is_import && home_import != other_import) {
			return false
		}
	}
	Data :: struct {
		words: []string,
		depth: int,
		ok:    bool,
	}
	data := Data{words, 0, true}
	visitor := ast.Visitor {
		data = &data,
		visit = proc(visitor: ^ast.Visitor, node: ^ast.Node) -> ^ast.Visitor {
			data := (^Data)(visitor.data)
			if node == nil || !data.ok {
				return nil
			}
			declared: []^ast.Expr
			#partial switch n in node.derived {
			case ^ast.Proc_Lit:
				data.depth += 1
				ast.walk(visitor, n.type)
				ast.walk(visitor, n.body)
				data.depth -= 1
				return nil
			case ^ast.Value_Decl:
				if data.depth > 0 do declared = n.names
			case ^ast.Field:
				if data.depth > 0 do declared = n.names
			case ^ast.Range_Stmt:
				declared = n.vals
			case ^ast.Ident:
				return nil
			}
			for name in declared {
				if ident, is_ident := name.derived.(^ast.Ident); is_ident && slice.contains(data.words, ident.name) {
					data.ok = false
				}
			}
			return visitor
		},
	}
	for decl in document.ast.decls {
		ast.walk(&visitor, decl)
	}
	return data.ok
}

// The import path that alias names in document.
import_named :: proc(document: ^Document, alias: string) -> (string, bool) {
	for imp in document.imports {
		if imp.base == alias {
			return imp.name, true
		}
	}
	return "", false
}

// Whether a file that the workspace filter leaves out of the search holds name, which may be a use that the alias
// deletion would break.
used_outside_filter :: proc(ctx: ^ActionContext, name: string) -> bool {
	when ODIN_TEST {
		return false
	} else {
		if len(ctx.files) > 0 {
			return false
		}
		searched := make(map[string]bool, context.temp_allocator)
		for file in workspace_odin_files("", nil) {
			searched[file.fullpath] = true
		}
		searched[ctx.document.fullpath] = true
		for workspace in common.config.workspace_folders {
			uri, _ := common.parse_uri(workspace.uri, context.temp_allocator)
			all := make([dynamic]string, context.temp_allocator)
			common.search_for_odin_files(uri.path, "", dir_blacklist, &all, nil)
			for fullpath in all {
				if searched[fullpath] {
					continue
				}
				data, err := os.read_entire_file(fullpath, context.temp_allocator)
				if err != nil || strings.contains(string(data), name) {
					return true
				}
			}
		}
		return false
	}
}
