#+private file

package server

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import path "core:path/slashpath"

import "src:common"

// Offers "Add @(x)" or "Remove @(x)" for a top-level declaration through attr_add and attr_remove. No compile gate
// guards a code action, so each case that `odin check` would reject refuses here.
@(private = "package")
add_attr_action :: proc(ctx: ^ActionContext) {
	if !ctx.config.enable_code_action_attr {
		return
	}
	decl := decl_at_range(ctx)
	if decl == nil {
		return
	}
	lit := proc_lit_of(decl)
	has_require := has_attr(decl, "require_results")
	has_private := has_attr(decl, "private")
	has_test := has_attr(decl, "test")
	takes_results := lit != nil && has_results(lit)
	private_file := parser.parse_file_tags(ctx.document.ast, context.temp_allocator).private != .Public
	// The attribute applies to every name, and the reference search below follows one.
	can_be_private := !private_file && !has_private && !has_test && len(decl.names) == 1

	// Adding either attribute needs the uses of the name, so the two share one workspace search.
	uses: []common.Location
	if (takes_results && !has_require) || can_be_private {
		h := Call_Hierarchy{ctx.files, make(map[string]^Document, context.temp_allocator)}
		variants := variant_symbols(top_level_variants(&h, ctx.document, decl))
		uses = proc_references(ctx.document, decl, ctx.files, variants)
	}

	if takes_results {
		if has_require {
			offer_remove(ctx, decl, "require_results")
		} else if handles_results(ctx, uses) {
			offer_add(ctx, decl, "require_results")
		}
	}
	if lit != nil && is_test_signature(ctx.document, lit) {
		if has_test {
			offer_remove(ctx, decl, "test")
		} else if !has_private {
			offer_add(ctx, decl, "test")
		}
	}
	if !private_file {
		if has_private {
			if !redeclares_in_package(ctx, decl) {
				offer_remove(ctx, decl, "private")
			}
		} else if can_be_private && !used_by_other_package(ctx, uses) {
			offer_add(ctx, decl, "private")
		}
	}
}

offer_add :: proc(ctx: ^ActionContext, decl: ^ast.Value_Decl, key: string) {
	edit, _, _, ok := attr_add(ctx.document, name_position(ctx, decl), key, ctx.config)
	if ok {
		append(ctx.actions, CodeAction{title = fmt.tprintf("Add @(%s)", key), kind = "refactor.rewrite", edit = edit})
	}
}

offer_remove :: proc(ctx: ^ActionContext, decl: ^ast.Value_Decl, key: string) {
	edit, _, _, ok := attr_remove(ctx.document, name_position(ctx, decl), key, ctx.config)
	if ok {
		append(
			ctx.actions,
			CodeAction{title = fmt.tprintf("Remove @(%s)", key), kind = "refactor.rewrite", edit = edit},
		)
	}
}

// The engines take a position in the head of the declaration, which ends before the procedure signature.
name_position :: proc(ctx: ^ActionContext, decl: ^ast.Value_Decl) -> common.Position {
	return common.get_token_range(decl.names[0], ctx.document.ast.src).start
}

// The file-scope declaration whose header holds the range: its attributes, its names and its type, up to the body of a
// procedure or the start of any other value. A foreign-block member is left out, since the block may carry the
// attribute already.
decl_at_range :: proc(ctx: ^ActionContext) -> ^ast.Value_Decl {
	decls := make([dynamic]^ast.Value_Decl, context.temp_allocator)
	for decl in ctx.document.ast.decls {
		collect(decl, &decls)
	}
	for decl in decls {
		start, end := decl.pos.offset, decl.end.offset
		for group in decl.attributes {
			start = min(start, group.pos.offset)
		}
		if len(decl.values) > 0 {
			end = decl.values[0].pos.offset
			if lit := proc_lit_of(decl); lit != nil && lit.body != nil {
				end = lit.body.pos.offset
			}
		}
		if start <= ctx.range.start && ctx.range.end <= end {
			return decl
		}
	}
	return nil

	collect :: proc(stmt: ^ast.Stmt, decls: ^[dynamic]^ast.Value_Decl) {
		if stmt == nil {
			return
		}
		#partial switch s in stmt.derived {
		case ^ast.Value_Decl:
			append(decls, s)
		case ^ast.When_Stmt:
			collect(s.body, decls)
			collect(s.else_stmt, decls)
		case ^ast.Block_Stmt:
			for inner in s.stmts {
				collect(inner, decls)
			}
		}
	}
}

proc_lit_of :: proc(decl: ^ast.Value_Decl) -> ^ast.Proc_Lit {
	if len(decl.names) != 1 || len(decl.values) != 1 {
		return nil
	}
	return decl.values[0].derived.(^ast.Proc_Lit) or_else nil
}

has_attr :: proc(decl: ^ast.Value_Decl, key: string) -> bool {
	for group in decl.attributes {
		for elem in group.elems {
			if ident, _, is_key := unwrap_attr_elem(elem); is_key && ident.name == key {
				return true
			}
		}
	}
	return false
}

// `-> !` has no results, and `odin check` rejects require_results there.
has_results :: proc(lit: ^ast.Proc_Lit) -> bool {
	return lit.type != nil && lit.type.results != nil && len(lit.type.results.list) > 0
}

// Whether require_results leaves every use compiling. A dropped call, in a `defer` too, is an error. A use other than a
// call may reach a call that the search cannot follow: `p := f; p()` and a procedure group both report the dropped result.
handles_results :: proc(ctx: ^ActionContext, uses: []common.Location) -> bool {
	h := Call_Hierarchy{ctx.files, make(map[string]^Document, context.temp_allocator)}
	h.documents[ctx.document.uri.uri] = ctx.document
	for location in uses {
		caller := hierarchy_document(&h, location.uri)
		if caller == nil {
			return false
		}
		call, ok := call_at_reference(caller, location)
		if !ok || call == nil {
			return false
		}
		for at in nodes_at(caller.ast.decls[:], call.pos.offset) {
			stmt := at.node.derived.(^ast.Expr_Stmt) or_continue
			if dropped, is_call := ast.unparen_expr(stmt.expr).derived.(^ast.Call_Expr); is_call && dropped == call {
				return false
			}
		}
	}
	return true
}

// Whether a file outside the directory of the document uses the declaration, which `private` would break.
used_by_other_package :: proc(ctx: ^ActionContext, uses: []common.Location) -> bool {
	context.allocator = context.temp_allocator
	dir := path.dir(ctx.document.fullpath)
	for location in uses {
		if !same_path(path.dir(common.uri_to_path(location.uri, context.temp_allocator)), dir) {
			return true
		}
	}
	return false
}

// Whether removing `private="file"` moves a name into the package scope where another file already declares it.
redeclares_in_package :: proc(ctx: ^ActionContext, decl: ^ast.Value_Decl) -> bool {
	if !is_file_private(decl.attributes[:]) {
		return false
	}
	h := Call_Hierarchy{ctx.files, make(map[string]^Document, context.temp_allocator)}
	h.documents[ctx.document.uri.uri] = ctx.document
	for name_expr in decl.names {
		name := final_name(name_expr)
		for document in package_documents(&h, ctx.document, name, false) {
			if document == ctx.document {
				continue
			}
			for other in top_level_value_decls(document.ast) {
				for other_name in other.names {
					if final_name(other_name) == name {
						return true
					}
				}
			}
		}
	}
	return false
}

// Whether lit has the signature of a test: `proc(t: ^testing.T)` with a body, where `testing` names `core:testing`.
is_test_signature :: proc(document: ^Document, lit: ^ast.Proc_Lit) -> bool {
	type := lit.type
	if lit.body == nil || type == nil || has_results(lit) || type.diverging || type.calling_convention != nil {
		return false
	}
	if type.params == nil || len(type.params.list) != 1 {
		return false
	}
	field := type.params.list[0]
	if len(field.names) != 1 || field.flags != {} || field.default_value != nil || field.type == nil {
		return false
	}
	pointer := field.type.derived.(^ast.Pointer_Type) or_return
	selector := pointer.elem.derived.(^ast.Selector_Expr) or_return
	prefix := selector.expr.derived.(^ast.Ident) or_return
	if selector.op.kind != .Period || selector.field == nil || selector.field.name != "T" {
		return false
	}
	for imp in document.ast.imports {
		if imp.fullpath != "\"core:testing\"" {
			continue
		}
		name := imp.name.text if imp.name.text != "" else "testing"
		if name == prefix.name {
			return true
		}
	}
	return false
}
